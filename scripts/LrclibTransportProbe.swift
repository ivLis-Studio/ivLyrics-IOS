// Compile as an isolated iOS Simulator app with the production endpoint and HTTP
// files. The target is supplied only at launch; no user's address is built in.
import UIKit

@main
final class LrclibTransportProbe: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        Task { @MainActor in
            guard let supplied = ProcessInfo.processInfo.environment["IVLYRICS_LRCLIB_PROBE_URL"],
                  let base = LrclibEndpoint.normalized(supplied), !base.isEmpty else {
                print("LRCLIB_TRANSPORT_INVALID_URL")
                exit(1)
            }
            do {
                let path = ProcessInfo.processInfo.environment["IVLYRICS_LRCLIB_PROBE_PATH"] ?? "search"
                let params = path == "search" ? ["q": "ivLyrics transport probe"] : [:]
                let body = try await LrclibHTTPClient().get(base: base, path: path, params: params, timeout: 5)
                let payload = try? JSONSerialization.jsonObject(with: Data(body.utf8))
                if let object = payload as? [String: Any] {
                    let idMatches = (object["id"] as? NSNumber)?.int64Value == Int64(path.dropFirst(4))
                    let hasPlain = (object["plainLyrics"] as? String)?.isEmpty == false
                    let hasSynced = (object["syncedLyrics"] as? String)?.isEmpty == false
                    print("LRCLIB_TRANSPORT_OK bytes=\(body.utf8.count) json=true idMatches=\(idMatches) plain=\(hasPlain) synced=\(hasSynced)")
                } else {
                    print("LRCLIB_TRANSPORT_OK bytes=\(body.utf8.count) jsonArray=\(payload is [Any])")
                }
                exit(0)
            } catch let error as HTTPStatusError {
                // A server status also proves ATS allowed the native connection.
                print("LRCLIB_TRANSPORT_HTTP_STATUS=\(error.statusCode)")
                exit(0)
            } catch {
                print("LRCLIB_TRANSPORT_ERROR code=\((error as NSError).code) domain=\((error as NSError).domain)")
                exit(1)
            }
        }
        return true
    }
}
