#!/usr/bin/env python3
"""Exercise the production Gemini body builder without credentials or an iPhone."""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'ivLyrics-IOS/AiLyricsRepository.swift').read_text()
start = source.index('    private func geminiBody(')
methods = source[start:source.index('    private func callClaude(', start)].replace('private func', 'func')
fixture = r'''
import Foundation
enum AppSettings {
    struct Snapshot { var model: String; var maxTokens = 32768; var temperature = 0.3 }
}
struct Builder {
// PRODUCTION
}
@main struct Regression {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) }; checks += 1 }
    static func main() {
        let builder = Builder()
        for model in ["gemini-3.1-flash-lite", "models/gemini-3.5-flash-lite", "gemini-3.5-flash-lite-preview",
                      "gemini-3-pro-preview", "gemini-3.7-flash", "gemini-2.5-flash", "gemini-2.5-flash-lite",
                      "gemini-2.5-pro", "gemini-2.0-flash", "gemma-3-27b-it"] {
            let settings = AppSettings.Snapshot(model: model)
            let body = builder.geminiBody(prompt: "fixture", settings: settings)
            let config = body["generationConfig"] as! [String: Any]
            let thinking = config["thinkingConfig"] as? [String: Any]
            if model.contains("gemini-3") {
                check(thinking?["thinkingBudget"] == nil, "No zero budget for \(model)")
                check(thinking?["thinkingLevel"] as? String == (model.contains("flash-lite") ? "minimal" : "low"), "Level for \(model)")
            } else if model.hasPrefix("gemini-2.5-flash") {
                check(thinking?["thinkingBudget"] as? Int == 0, "Flash budget")
            } else { check(thinking == nil, "Use API default for \(model)") }
            check(config["maxOutputTokens"] as? Int == 32768 && config["temperature"] as? Double == 0.3, "Preserve settings")
            let research = builder.geminiBody(prompt: "research", settings: settings, maxTokens: 65536)["generationConfig"] as! [String: Any]
            check(research["maxOutputTokens"] as? Int == 65536, "Preserve research override")
            let contents = body["contents"] as! [[String: Any]]
            check((contents[0]["parts"] as! [[String: String]])[0]["text"] == "fixture", "Preserve prompt")
        }
        print("Gemini regression: \(checks) checks passed across 10 model variants")
    }
}
'''.replace('// PRODUCTION', methods)
with tempfile.TemporaryDirectory(prefix='ivlyrics-gemini-') as directory:
    directory = Path(directory)
    path = directory / 'Regression.swift'
    path.write_text(fixture)
    binary = directory / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
