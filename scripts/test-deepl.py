#!/usr/bin/env python3
"""Test the native DeepL transport and production capability gates without accounts."""
from pathlib import Path
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
SRC=ROOT/'ivLyrics-IOS'
settings=(SRC/'AppSettings.swift').read_text()
def section(start,end):
    return settings[settings.index(start):settings.index(end,settings.index(start))]
helpers='''import Foundation
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
struct HTTPStatusError: Error { let statusCode: Int; let message: String }
enum PaxsenixAIProvider { static let baseURL="https://fixture.test", dashboardURL="https://fixture.test" }
enum KeylessTranslationProviders { static let bingId="bing-translate", googleId="google-translate" }
enum AppSettings {
// PROVIDERS
// PROVIDER
static func aiProviderById(_ id: String) -> Provider? { providers.first { $0.id == id } }
static func normalizedAIProviderOrder(_ ids: [String]) -> [String] { ids }
struct Snapshot {
    var apiKeys="", model=""
    var aiProviderEnabled: [String:Bool]=[:]
    var aiProviderOrder: [String]=[]
    var profiles: [String: (String,String)]=[:]
    var hasApiKey: Bool { !apiKeys.isEmpty }
    var hasModel: Bool { !model.isEmpty }
    func selectingAIProvider(_ id: String) -> Snapshot? {
        guard let (key, model) = profiles[id] else { return nil }
        var copy=self; copy.apiKeys=key; copy.model=model; return copy
    }
// GATES
}
}
'''.replace('// PROVIDERS',section('    static let providers:', '    static let allAIProviders:'))
helpers=helpers.replace('// PROVIDER',section('    struct Provider:', '    struct AIProviderProfile:'))
helpers=helpers.replace('// GATES',section('        var hasKeylessTranslationProvider:', '        func selectingAIProvider('))
checks=r'''
import Foundation
final class FixtureProtocol: URLProtocol {
    static var handler: ((URLRequest, Data) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while true { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; body.append(contentsOf: bytes.prefix(n)) }
            }
            let (status, data) = try Self.handler(request, body)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@main struct Regression {
    static var count=0
    static func check(_ value: Bool, _ message: String) { guard value else { fatalError(message) }; count += 1 }
    static func main() async throws {
        let config=URLSessionConfiguration.ephemeral; config.protocolClasses=[FixtureProtocol.self]
        let session=URLSession(configuration: config); defer { session.invalidateAndCancel() }
        var requests: [URLRequest]=[], bodies: [[String:Any]]=[]
        let echo: (URLRequest,Data) throws -> (Int,Data) = { request,data in
            requests.append(request)
            check(data.count <= 128 * 1024, "UTF-8 body limit")
            let body=try JSONSerialization.jsonObject(with: data) as! [String:Any]; bodies.append(body)
            let texts=body["text"] as! [String]
            return (200, try JSONSerialization.data(withJSONObject:["translations":texts.map{["text":"T:"+$0]}]))
        }
        FixtureProtocol.handler=echo
        func translate(_ texts: [String], key: String="free:fx", lyrics: Bool=true) async throws -> [String] {
            try await DeepLTranslationProvider.translate(texts:texts,targetLanguage:"zh-TW",apiKey:key,preserveLyricsStructure:lyrics,session:session)
        }
        var result=try await translate(["", "one / two", "[Instrumental]", "♪", "(Intro)", "three", ""],key:" free:fx ")
        check(result == ["", "T:one / T:two", "[Instrumental]", "♪", "(Intro)", "T:three", ""], "rows, markers, vocal parts")
        check(requests[0].url!.absoluteString == "https://api-free.deepl.com/v2/translate", "direct Free endpoint")
        check(requests[0].httpMethod == "POST" && requests[0].value(forHTTPHeaderField:"Authorization") == "DeepL-Auth-Key free:fx", "POST with header authentication")
        check(bodies[0]["target_lang"] as? String == "ZH-HANT" && bodies[0]["preserve_formatting"] as? Bool == true, "language and formatting")
        check(DeepLTranslationProvider.targetLanguage("zh_CN") == "ZH-HANS", "simplified Chinese")
        check(DeepLTranslationProvider.targetLanguage("en") == "EN-US" && DeepLTranslationProvider.targetLanguage("pt") == "PT-PT", "regional targets")
        result=try await translate(["[Title]","Singer / Guest"],key:"pro",lyrics:false)
        check(result == ["T:[Title]", "T:Singer / Guest"], "metadata not treated as lyrics")
        check(requests.last!.url!.absoluteString == "https://api.deepl.com/v2/translate", "direct Pro endpoint")
        bodies=[]
        result=try await translate((0..<104).map(String.init))
        check(bodies.map { ($0["text"] as! [String]).count } == [50,50,4] && result.last == "T:103", "50-text batching preserves order")
        bodies=[]
        _=try await translate([String(repeating:"한",count:25000),String(repeating:"글",count:25000)])
        check(bodies.count == 2, "UTF-8 size batching")
        do { _=try await translate([String(repeating:"한",count:45000)]); fatalError("Oversize accepted") } catch { count += 1 }
        do { _=try await translate(["a"],key:" "); fatalError("Empty key accepted") } catch { count += 1 }
        for raw in ["{}", #"{"translations":[]}"#, #"{"translations":[{"text":7}]}"#, #"{"translations":[{"text":" "}]}"#] {
            FixtureProtocol.handler={_,_ in (200,Data(raw.utf8))}
            do { _=try await translate(["a"]); fatalError("Malformed response accepted") } catch { count += 1 }
        }
        for status in [403,429,456] {
            FixtureProtocol.handler={_,_ in (status,Data("{}".utf8))}
            do { _=try await translate(["a"]); fatalError("HTTP error accepted") }
            catch let error as HTTPStatusError { check(error.statusCode==status,"HTTP status preserved") }
        }
        FixtureProtocol.handler={_,_ in fatalError("Protected-only lyrics made a request")}
        _=try await translate(["", "[Break]"])
        check(AppSettings.providers.first?.id == "gemini", "default provider unchanged")
        let provider=AppSettings.aiProviderById("deepl")!
        check(provider.translationOnly && !provider.isKeyless && !provider.defaultEnabled && provider.defaultModel.isEmpty,"translation-only keyed provider")
        var settings=AppSettings.Snapshot()
        settings.aiProviderOrder=["deepl"]; settings.aiProviderEnabled=["deepl":true]; settings.profiles=["deepl":("fixture", "")]
        check(settings.hasAnyTranslationProvider && !settings.hasReadyAIProvider && !settings.hasEnabledAIProvider, "DeepL alone translates without enabling AI")
        settings.profiles["deepl"]=("fixture", "legacy-model")
        check(settings.readyAIProviderSnapshots.isEmpty, "saved model does not enable AI")
        settings.profiles["deepl"]=("", "")
        check(!settings.hasAnyTranslationProvider, "key required")
        settings.profiles["deepl"]=("fixture", ""); settings.aiProviderEnabled["deepl"]=false
        check(!settings.hasAnyTranslationProvider, "disabled DeepL not ready")
        settings.aiProviderEnabled[KeylessTranslationProviders.googleId]=true
        check(settings.hasAnyTranslationProvider, "existing keyless readiness")
        print("DeepL regression: \(count) checks passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='ivlyrics-deepl-') as directory:
    directory=Path(directory)
    (directory/'Helpers.swift').write_text(helpers)
    (directory/'Regression.swift').write_text(checks)
    binary=directory/'regression'
    subprocess.run(['swiftc',str(directory/'Helpers.swift'),str(SRC/'DeepLTranslationProvider.swift'),str(directory/'Regression.swift'),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
