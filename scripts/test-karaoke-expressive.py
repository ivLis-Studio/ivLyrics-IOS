#!/usr/bin/env python3
"""Compare native expressive karaoke motion with values captured from the desktop renderer.

The fixture comes from scripts/capture-expressive-fixture.mjs run against the desktop Pages.js.
This checks the motion math and unit classification; it does not render on a device.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "scripts/fixtures/karaoke-expressive-desktop.json"
checks = r'''
import Foundation
var assertions = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !value() { fatalError(message) }
}
let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let fixture = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
var worstScale = 0.0, worstOffset = 0.0, worstGlow = 0.0
for trajectory in fixture["trajectories"] as! [[String: Any]] {
    let duration = (trajectory["duration"] as! NSNumber).doubleValue
    let emphasis = trajectory["emphasis"] as! Bool
    let unit = KaraokeExpressiveMotion.Unit(startMs: 5000, endMs: 5000 + duration, emphasis: emphasis)
    for sample in trajectory["samples"] as! [[NSNumber]] {
        let elapsed = sample[0].doubleValue
        let values = KaraokeExpressiveMotion.values(unit, positionMs: 5000 + elapsed, pendingPose: 0)
        if sample[4].intValue == 0 {
            check(values == .idle, "settled unit \(duration) \(emphasis) at \(elapsed) is idle")
            continue
        }
        // Desktop rounds scale to 0.001, offset to 0.0005 em and glow to 0.01.
        worstScale = max(worstScale, abs(values.scale - sample[1].doubleValue))
        worstOffset = max(worstOffset, abs(values.offsetEm - sample[2].doubleValue))
        worstGlow = max(worstGlow, abs(values.glow - sample[3].doubleValue))
        check(abs(values.scale - sample[1].doubleValue) <= 0.0011, "scale \(duration) \(emphasis) at \(elapsed): \(values.scale) vs \(sample[1])")
        check(abs(values.offsetEm - sample[2].doubleValue) <= 0.0006, "offset \(duration) \(emphasis) at \(elapsed): \(values.offsetEm) vs \(sample[2])")
        check(abs(values.glow - sample[3].doubleValue) <= 0.0101, "glow \(duration) \(emphasis) at \(elapsed): \(values.glow) vs \(sample[3])")
    }
}
var classified = 0
for line in fixture["classifications"] as! [[String: Any]] {
    let name = line["name"] as! String
    let chars = line["chars"] as! [[Any]]
    let segments = chars.map {
        KaraokeExpressiveMotion.Segment(text: $0[0] as! String, startMs: ($0[1] as! NSNumber).doubleValue,
                                        endMs: ($0[2] as! NSNumber).doubleValue)
    }
    let units = KaraokeExpressiveMotion.units(for: segments, wordGranularity: false)
    let windows = line["windows"] as! [Any]
    for (index, expected) in windows.enumerated() {
        guard let window = expected as? [NSNumber] else {
            check(units[index] == nil, "\(name)[\(index)] does not move")
            continue
        }
        guard let unit = units[index] else { fatalError("\(name)[\(index)] moves") }
        check(abs(unit.startMs - window[0].doubleValue) < 0.001 && abs(unit.endMs - window[1].doubleValue) < 0.001,
              "\(name)[\(index)] window \(unit) vs \(window)")
        check(unit.emphasis == (window[2].intValue == 1), "\(name)[\(index)] emphasis")
        classified += 1
    }
}

// Rows displayed per word move per word, never letter by letter.
let words = KaraokeExpressiveMotion.units(for: [
    .init(text: "wonderfully", startMs: 0, endMs: 2000), .init(text: " ", startMs: 2000, endMs: 2100),
    .init(text: "bright", startMs: 2100, endMs: 2400),
], wordGranularity: true)
check(words[0] == .init(startMs: 0, endMs: 2000, emphasis: false) && words[1] == nil && words[2]?.startMs == 2100,
      "word granularity keeps each word as one unit")

// Only the line being sung shows the pending pose, eased in before it starts.
let unit = KaraokeExpressiveMotion.Unit(startMs: 1000, endMs: 1400, emphasis: false)
check(KaraokeExpressiveMotion.values(unit, positionMs: 500, pendingPose: 0) == .idle, "units of other lines rest idle")
let pending = KaraokeExpressiveMotion.values(unit, positionMs: 500, pendingPose: 1)
check(abs(pending.scale - 0.95) < 1e-9 && abs(pending.offsetEm - 0.012) < 1e-9 && pending.glow == 0, "pending pose")
check(KaraokeExpressiveMotion.pendingPose(active: false, positionMs: 1000, lineStartMs: 1000, lineEndMs: 3000) == 0, "inactive line")
check(KaraokeExpressiveMotion.pendingPose(active: true, positionMs: 760, lineStartMs: 1000, lineEndMs: 3000) == 0, "pose before the ease")
check(KaraokeExpressiveMotion.pendingPose(active: true, positionMs: 880, lineStartMs: 1000, lineEndMs: 3000) == 0.5, "pose halfway in")
check(KaraokeExpressiveMotion.pendingPose(active: true, positionMs: 1000, lineStartMs: 1000, lineEndMs: 3000) == 1, "full pose at the start")
check(KaraokeExpressiveMotion.pendingPose(active: true, positionMs: 3000, lineStartMs: 1000, lineEndMs: 3000) == 0, "completed line")
let first = KaraokeExpressiveMotion.values(unit, positionMs: 1000, pendingPose: 1)
check(abs(first.scale - 0.95) < 1e-6 && abs(first.offsetEm - 0.012) < 1e-6, "motion starts from the pending pose")
check(KaraokeExpressiveMotion.values(unit, positionMs: .nan, pendingPose: 1) == .idle, "unknown position stays idle")
print("KARAOKE_EXPRESSIVE_PASSED assertions=\(assertions) units=\(classified) worstScale=\(worstScale) worstOffset=\(worstOffset) worstGlow=\(worstGlow)")
'''
with tempfile.TemporaryDirectory(prefix="ivlyrics-ios-expressive-") as path:
    work = Path(path)
    (work / "main.swift").write_text(checks)
    subprocess.run(["xcrun", "swiftc", "-O", str(ROOT / "ivLyrics-IOS/KaraokeExpressiveMotion.swift"),
                    str(work / "main.swift"), "-o", str(work / "regression")], check=True)
    subprocess.run([str(work / "regression"), str(FIXTURE)], check=True)
