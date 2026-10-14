#!/usr/bin/env python3
"""Host check for Local AI: run the app's engine wrapper and translation path on this Mac.

Compiles ivLyrics-IOS/LocalAI.swift, LocalAIService.swift and LocalAIEngine.swift against the macOS
slice of the pinned llama.cpp b11364 xcframework, then translates Japanese lyric lines into Korean
through LocalAIService.translate, as the app does. Needs a downloaded model file, e.g.:

    scripts/local-ai-host-check.py --models /path/to/folder-with-Hy-MT2-1.8B-Q4_K_M.gguf

Not part of CI: the model is about 1.1 GB.
"""
import argparse
import hashlib
import json
import subprocess
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "ivLyrics-IOS"
XCFRAMEWORK_URL = "https://github.com/ggml-org/llama.cpp/releases/download/b11364/llama-b11364-xcframework.zip"
XCFRAMEWORK_SHA256 = "307aa390240aadf904282cb40b2dc0bee5091b24b035af39d661052691035c53"

LINES = [
    "君の声が遠くで聞こえる",
    "夜明けまでそばにいて",
    "[Chorus]",
    "星の降る街で / 君を待ってる",
    "",
    "君の声が遠くで聞こえる",
    "明日もきっと晴れるから",
    "忘れないで この約束を",
    "遠い空に手を伸ばして",
    "季節がめぐっても",
    "変わらない想いがある",
    "ひとりじゃないと信じて",
    "静かな夜に歌おう",
    "君と見た夕焼けを",
]

DRIVER = r'''
import Foundation
#if canImport(llama)
import llama
#endif

func now() -> Double { ProcessInfo.processInfo.systemUptime }
func peakMegabytes() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss) / 1_048_576
}
func ms(_ seconds: Double) -> String { String(format: "%.0f ms", seconds * 1000) }

@main
struct HostCheck {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let models = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let tier = LocalAI.Tier.stored(arguments[2])
        let processor = LocalAI.Processor.stored(arguments[3])
        let lines = try JSONDecoder().decode([String].self, from: Data(arguments[4].utf8))
        let messages = LocalAI.Messages(notReady: "not ready", downloadBusy: "busy",
                                        unsupportedLanguage: "cannot translate into {language}", uiLanguage: "en")
        let configuration = LocalAI.Configuration(tier: tier, processor: processor, idleMinutes: 10)
        let service = LocalAIService(directory: models, loader: LlamaInferenceEngine.loader)
        print("model: \(tier.rawValue) (\(LocalAI.formatGigabytes(tier.byteCount))) · processor setting: \(processor.rawValue) · threads: \(LlamaInferenceEngine.threadCount)")

        var started = now()
        let test = try await service.testTranslation(targetLanguage: "ko", configuration: configuration, messages: messages)
        let state = await service.currentState()
        print("Test translation (loads the model): ✓ \(test.sample) → \(test.line) (\(String(format: "%.1f", test.seconds))s) · Ready · \(state.device ?? "?")")
        print("llama.cpp b11364: \(String(cString: llama_print_system_info()).prefix(90))…")

        for run in 1...2 {
            started = now()
            let arrivals = ArrivalLog()
            let result = try await service.translate(lines: lines, targetLanguage: "ko", configuration: configuration,
                                                     priority: .interactive, messages: messages) { index, _ in
                arrivals.add(index, now())
            }
            let total = now() - started
            print("\nLyrics run \(run): \(lines.count) lines in \(ms(total)) (first line after \(ms((arrivals.first ?? now()) - started)))")
            for (index, line) in lines.enumerated() {
                let at = arrivals.time(index).map { ms($0 - started) } ?? "-"
                print("  [\(at)] \(line.isEmpty ? "(blank)" : line) → \(result[index].isEmpty ? "(blank)" : result[index])")
            }
        }

        started = now()
        do {
            _ = try await service.translate(lines: ["君の声"], targetLanguage: "sv", configuration: configuration, priority: .interactive, messages: messages)
            print("unsupported language: no error")
        } catch {
            print("\nUnsupported language (sv): \(error.localizedDescription) after \(ms(now() - started))")
        }
        let missing = LocalAI.Tier.allCases.first { !service.isDownloaded($0) }
        if let missing {
            started = now()
            do {
                _ = try await service.translate(lines: ["君の声"], targetLanguage: "ko", configuration: .init(tier: missing, processor: processor),
                                                priority: .interactive, messages: messages)
                print("not downloaded: no error")
            } catch {
                print("Not downloaded (\(missing.rawValue)): \(error.localizedDescription) after \(ms(now() - started))")
            }
        }
        await service.releaseEngine()
        print("Peak resident memory while translating: \(peakMegabytes()) MB")

        let engine = try LlamaInferenceEngine.load(modelURL: service.modelURL(for: tier), processor: processor)
        let prompt = LocalAI.linePrompt(lines[0], language: "Korean")
        let rendered = try engine.render(prompt)
        print("Prompt layout matches the model's Jinja template: \(rendered == "<｜hy_begin▁of▁sentence｜><｜hy_User｜>" + prompt + "<｜hy_Assistant｜>")")
    }
}

final class ArrivalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Int: Double] = [:]
    func add(_ index: Int, _ time: Double) { lock.lock(); times[index] = time; lock.unlock() }
    func time(_ index: Int) -> Double? { lock.lock(); defer { lock.unlock() }; return times[index] }
    var first: Double? { lock.lock(); defer { lock.unlock() }; return times.values.min() }
}
'''


def xcframework(work: Path, given: Path | None) -> Path:
    if given:
        return given
    archive = work / "llama-b11364-xcframework.zip"
    with urllib.request.urlopen(XCFRAMEWORK_URL) as response:
        archive.write_bytes(response.read())
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != XCFRAMEWORK_SHA256:
        raise SystemExit(f"xcframework checksum mismatch: {digest}")
    with zipfile.ZipFile(archive) as bundle:
        bundle.extractall(work)
    return work / "build-apple" / "llama.xcframework"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", type=Path, default=Path("/tmp/ivl-models"), help="folder with the tier's .gguf file")
    parser.add_argument("--tier", default="light", choices=["light", "medium", "high"])
    parser.add_argument("--processor", default="auto", choices=["auto", "cpu"])
    parser.add_argument("--xcframework", type=Path, help="an extracted llama.xcframework (downloads the pinned zip otherwise)")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="ivlyrics-local-ai-host-") as directory:
        work = Path(directory)
        slice_dir = xcframework(work, args.xcframework) / "macos-arm64_x86_64"
        (work / "main.swift").write_text(DRIVER, encoding="utf-8")
        executable = work / "host-check"
        subprocess.run(["swiftc", "-O", "-parse-as-library", "-F", str(slice_dir), "-framework", "llama",
                        "-Xlinker", "-rpath", "-Xlinker", str(slice_dir),
                        str(SRC / "LocalAI.swift"), str(SRC / "LocalAIService.swift"), str(SRC / "LocalAIEngine.swift"),
                        str(work / "main.swift"), "-o", str(executable)], check=True)
        subprocess.run([str(executable), str(args.models), args.tier, args.processor, json.dumps(LINES, ensure_ascii=False)], check=True)


if __name__ == "__main__":
    main()

