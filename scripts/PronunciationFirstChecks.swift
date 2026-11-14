private var assertions = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !condition() { fatalError(message) }
}
private func unit(_ text: String, _ start: Int64, _ end: Int64) -> LyricsLine.Syllable {
    LyricsLine.Syllable(text: text, startTimeMs: start, endTimeMs: end)
}
private func karaokeUnits() -> [LyricsLine.Syllable] {
    [unit("許", 1000, 1400), unit("さ", 1400, 1600), unit("れ", 1600, 1800), unit("る", 1800, 2200)]
}

@main struct PronunciationFirstChecks {
    static func main() async {
        // Proportional split keeps every sound, in order, on the singing units.
        let spread = PronunciationFirst.distribute(["許", "さ", "れ", "る"], "유루사레루")
        check(spread.count == 4 && spread.joined() == "유루사레루" && !spread.contains(""), "proportional split: \(spread)")
        check(PronunciationFirst.distribute(["I ", "love ", "you"], "아이 러브 유").joined() == "아이 러브 유", "spaces stay")
        check(PronunciationFirst.distribute([" ", "!"], "아") == ["", "아"], "unplaceable reading goes to the first visible unit")
        check(PronunciationFirst.normalizeParts(["a ", " b", "c "], length: 3) == ["a ", "b", "c"], "boundary spaces")

        // Line-synced rows only swap values, and stay the same SwiftUI row.
        let synced = LyricsLine(startTimeMs: 1000, endTimeMs: 2000, text: "空", pronunciationText: "sora", translationText: "하늘")
        let swapped = PronunciationFirst.swapLine(synced, lineIndex: 0, timed: nil)
        check(swapped.text == "sora" && swapped.pronunciationText == "空" && swapped.translationText == "하늘", "line swap")
        check(swapped.id == synced.id && swapped.startTimeMs == 1000, "identity and timing stay")
        let bare = LyricsLine(startTimeMs: 0, endTimeMs: 1000, text: "(intro)")
        check(PronunciationFirst.swapLine(bare, lineIndex: 0, timed: nil) == bare, "rows without pronunciation are untouched")

        // Karaoke rows keep unit timing and use an AI split only when it fits.
        let line = LyricsLine(startTimeMs: 1000, endTimeMs: 2200, text: "許される", syllables: karaokeUnits(),
                              pronunciationText: "유루사레루", translationText: "용서받다")
        let karaoke = LyricsResult(lines: [line], providerLabel: "fixture", detail: "", karaoke: true)
        let proportional = PronunciationFirst.apply(karaoke, timed: nil).lines[0]
        check(proportional.text == "유루사레루" && proportional.pronunciationText == "許される", "karaoke swap")
        check(proportional.syllables.map(\.startTimeMs) == [1000, 1400, 1600, 1800], "unit timing stays")
        let aligned = PronunciationFirst.apply(karaoke, timed: ["0:line": ["유루", "사", "레", "루"]]).lines[0]
        check(aligned.syllables.map(\.text) == ["유루", "사", "레", "루"], "AI split is used")
        let mismatched = PronunciationFirst.apply(karaoke, timed: ["0:line": ["유루사레루"]]).lines[0]
        check(mismatched.syllables.map(\.text) == proportional.syllables.map(\.text), "wrong slot count falls back")

        // AI splits keep the pronunciation's own spaces and never its changed letters.
        check(PronunciationFirst.alignParts(["와라우", "요오", "니 나", "쿠"], "와라우 요오니 나쿠") == ["와라우 ", "요오", "니 나", "쿠"], "dropped space returns")
        check(PronunciationFirst.alignParts(["", "와스 ", "레테"], "와스레테") == ["", "와스", "레테"], "moved space follows the pronunciation")
        check(PronunciationFirst.alignParts(["지분", "라시", "사나", "은테"], "지분라시사난테") == nil, "changed letters are rejected")
        let spaced = LyricsLine(startTimeMs: 0, endTimeMs: 1600, text: "笑うように泣く",
                                syllables: [unit("笑う", 0, 400), unit("よう", 400, 800), unit("に泣", 800, 1200), unit("く", 1200, 1600)],
                                pronunciationText: "와라우 요오니 나쿠")
        let spacedResult = LyricsResult(lines: [spaced], providerLabel: "fixture", detail: "", karaoke: true)
        let droppedSpaces = ["0:line": ["와라우", "요오", "니 나", "쿠"]]
        check(PronunciationFirst.apply(spacedResult, timed: droppedSpaces).lines[0].syllables.map(\.text).joined() == "와라우 요오니 나쿠",
              "pronunciation-first shows the pronunciation's spacing")

        // A single timed voice part carries the line reading.
        let lead = LyricsLine.VocalPart(id: "lead", role: "lead", speaker: "", kind: "vocal", text: "許される", syllables: karaokeUnits())
        let parted = LyricsLine(startTimeMs: 1000, endTimeMs: 2200, text: "許される", vocalParts: [lead], pronunciationText: "유루사레루")
        let groups = PronunciationFirst.unitGroups(parted)
        check(groups.count == 1 && groups[0].key == "part:0" && groups[0].pronunciation == "유루사레루", "single voice uses the line reading")
        let partSwapped = PronunciationFirst.swapLine(parted, lineIndex: 0, timed: nil)
        check(partSwapped.vocalParts[0].text == "유루사레루" && partSwapped.pronunciationText.isEmpty
              && partSwapped.vocalParts[0].id == "lead", "voice part shows the reading")

        // AI items, prompt and response parsing.
        let items = PronunciationFirst.timingItems(karaoke)
        check(items.count == 1 && items[0].key == "0:line" && items[0].units.count == 4, "one timing item")
        let prompt = PronunciationFirst.prompt(items, lyricsText: PronunciationFirst.lyricsText(karaoke), sourceLang: "ja")
        check(prompt.contains("\"n\":4") && prompt.contains("\"r\":\"유루사레루\"") && prompt.contains("許される")
              && prompt.contains("p must contain exactly n strings"), "prompt")
        let parsed = PronunciationFirst.parse("```json\n{\"l\":[{\"i\":0,\"p\":[\"유루\",\"사\",\"레\",\"루\"]}]}\n```", items: items)
        check(parsed["0:line"] == ["유루", "사", "레", "루"], "fenced response")
        check(PronunciationFirst.parse("{\"l\":[{\"i\":0,\"p\":[\"유루사레루\"]}]}", items: items).isEmpty, "slot mismatch dropped")
        check(PronunciationFirst.parse("{\"l\":[{\"i\":0,\"p\":[\"유루\",\"사\",\"레\",\"루루\"]}]}", items: items).isEmpty, "changed letters dropped")
        check(PronunciationFirst.parse("not json", items: items).isEmpty, "malformed response")
        let many = (0..<30).map { PronunciationFirst.Item(key: "\($0):line", pronunciation: "a", units: items[0].units) }
        check(PronunciationFirst.chunks(many).count == 2 && PronunciationFirst.chunks(many, maxUnits: 8, maxItems: 99).count == 15, "chunks")

        // Pronunciation fill: timed units for the pronunciation rows, keyed by the shown rows.
        let fill = PronunciationFirst.fill(spacedResult, timed: droppedSpaces)
        let fillUnits = fill.lineFill(spaced).line
        check(fillUnits?.map(\.text) == ["와라우 ", "요오", "니 나", "쿠"] && fillUnits?[2].startTimeMs == 800, "line fill units")
        check(PronunciationFirst.Fill.matching(fillUnits, pronunciation: "와라우 요오니 나쿠") != nil, "matching units")
        check(PronunciationFirst.Fill.matching(fillUnits, pronunciation: "와라우 요오니 나쿠다") == nil, "other text is not filled")
        check(PronunciationFirst.fill(LyricsResult(lines: [spaced], providerLabel: "", detail: "", karaoke: false), timed: nil).isEmpty,
              "line-timed lyrics have no fill")
        check(PronunciationFirst.fill(spacedResult, timed: nil).lineFill(spaced).line?.map(\.text).joined() == "와라우 요오니 나쿠",
              "proportional fill until AI timing arrives")
        let solo = PronunciationFirst.fill(LyricsResult(lines: [parted], providerLabel: "", detail: "", karaoke: true), timed: nil)
        check(solo.lineFill(parted).line != nil && solo.lineFill(parted).parts.isEmpty, "a voice without its own reading fills the line row")
        let backing = LyricsLine.VocalPart(id: "bg", role: "background", speaker: "", kind: "vocal", text: "あ",
                                           syllables: [unit("あ", 2300, 2600)], pronunciationText: "아")
        let leadOwn = LyricsLine.VocalPart(id: "lead", role: "lead", speaker: "", kind: "vocal", text: "許される",
                                           syllables: karaokeUnits(), pronunciationText: "유루사레루")
        let duet = LyricsLine(startTimeMs: 1000, endTimeMs: 2600, text: "許される (あ)", vocalParts: [leadOwn, backing])
        let duetFill = PronunciationFirst.fill(LyricsResult(lines: [duet], providerLabel: "", detail: "", karaoke: true), timed: nil).lineFill(duet)
        check(duetFill.line == nil && duetFill.part(backing)?.map(\.text) == ["아"] && duetFill.part(leadOwn) != nil,
              "each voice with its own reading fills its own row")

        // lrc.red late word timing: the reading carries over, the signature changes, a stale split is not used.
        let lineTimedLine = LyricsLine(startTimeMs: 1000, endTimeMs: 2200, text: "許される", pronunciationText: "유루사레루", translationText: "용서받다")
        let lineTimed = LyricsResult(lines: [lineTimedLine], providerLabel: "lrc.red", detail: "", karaoke: false)
        check(PronunciationFirst.timingItems(lineTimed).isEmpty && PronunciationFirst.fill(lineTimed, timed: nil).isEmpty, "line timing asks for nothing")
        let wordTimed = LyricsResult(lines: [LyricsLine(startTimeMs: 1000, endTimeMs: 2200, text: "許される", syllables: karaokeUnits())],
                                     providerLabel: "lrc.red karaoke", detail: "", karaoke: true)
        let upgraded = LyricsTimingUpgrade.retime(lineTimed, with: wordTimed)
        check(upgraded.karaoke && upgraded.lines[0].pronunciationText == "유루사레루" && upgraded.lines[0].id == lineTimedLine.id,
              "upgrade keeps the reading and the row")
        let upgradedItems = PronunciationFirst.timingItems(upgraded)
        check(upgradedItems.count == 1, "upgraded lyrics ask AI for unit timing")
        let signature = PronunciationFirst.signature(upgradedItems, targetLang: "ko", sourceLang: "ja")
        let retimedAgain = LyricsResult(lines: [LyricsLine(startTimeMs: 1000, endTimeMs: 2200, text: "許される",
            syllables: [unit("許さ", 1000, 1600), unit("れる", 1600, 2200)], pronunciationText: "유루사레루")],
            providerLabel: "lrc.red karaoke", detail: "", karaoke: true)
        check(signature != PronunciationFirst.signature(PronunciationFirst.timingItems(retimedAgain), targetLang: "ko", sourceLang: "ja"),
              "different unit timing gives a different signature")
        check(PronunciationFirst.fill(upgraded, timed: nil).lineFill(upgraded.lines[0]).line?[3].startTimeMs == 1800,
              "late word timing gives the pronunciation row units")
        let stale = PronunciationFirst.apply(retimedAgain, timed: ["0:line": ["유루", "사", "레", "루"]]).lines[0]
        check(stale.syllables.count == 2 && stale.syllables.map(\.text).joined() == "유루사레루", "a split for other units is not applied")

        // Pronunciation by sung unit (the same split as the desktop app's PronunciationSlots.js).
        let unitTexts = { (text: String) in PronunciationSlots.splitUnits(text).map { ($0.gapBefore ? "_" : "") + $0.text } }
        check(unitTexts("5000マイル走って 息を") == ["5000", "マ", "イ", "ル", "走", "っ", "て", "_息", "を"], "CJK characters, digit words")
        check(unitTexts("Let's go 開けて？") == ["Let's", "_go", "_開", "け", "て？"], "words, apostrophes, punctuation")
        check(unitTexts("사랑해 너를") == ["사", "랑", "해", "_너", "를"], "Hangul syllables keep word gaps")
        check(unitTexts("「惑星」") == ["「惑", "星」"] && unitTexts("a ! b") == ["a", "_!", "_b"], "punctuation joins or stands alone")
        check(PronunciationSlots.join(PronunciationSlots.splitUnits("夢ならば どれほど"), ["yume ", "na", "ra", "ba", "do", "re", "ho", "do"])
              == "yume naraba dorehodo", "joined slots")
        check(PronunciationSlots.join(PronunciationSlots.splitUnits("사랑해 너를"), ["sa", "rang", "hae", "neo", "reul"]) == "saranghae neoreul",
              "original spaces return")
        let derivedParts = PronunciationSlots.deriveSyllableParts(["夢", "なら", "ば ", "どれ", "ほど"],
            ["yume ", "na", "ra", "ba", "do", "re", "ho", "do"], distribute: PronunciationFirst.distribute)
        check(derivedParts == ["yume ", "nara", "ba ", "dore", "hodo"], "syllables take their units' slots: \(derivedParts ?? [])")
        check(PronunciationSlots.deriveSyllableParts(["hel", "lo ", "world"], ["헬로", "월드"], distribute: PronunciationFirst.distribute)
              == ["헬", "로 ", "월드"], "a word sung over two syllables is spread over them")
        check(PronunciationSlots.deriveSyllableParts(["other"], ["a", "b"], distribute: PronunciationFirst.distribute) == nil, "other text")
        let slotItems = PronunciationSlots.items(["夢ならば", "♪", "今日も"])
        check(slotItems.map(\.index) == [0, 2] && slotItems[1].units == ["今", "日", "も"], "lines with sound are sent")
        let slotPrompt = PronunciationSlots.prompt(slotItems, lang: "ko", sourceLang: "ja", notation: "translation",
            scriptInstruction: "Use Korean Hangul syllables only.", outputScript: "Korean Hangul", audience: "Korean speakers")
        check(slotPrompt.contains("{\"i\":2,\"n\":3,\"u\":[\"今\",\"日\",\"も\"]}") && slotPrompt.contains("p must contain exactly n strings")
              && slotPrompt.contains("유메"), "slot prompt")
        let slotParsed = PronunciationSlots.parse(
            "{\"l\":[{\"i\":0,\"p\":[\"yume\",\"na\",\"ra\",\"ba\"]},{\"i\":2,\"p\":[\"kyou\"]},{\"i\":7,\"p\":[\"x\"]}]}",
            items: slotItems, notation: "latin")
        check(slotParsed.keys.sorted() == [0] && slotParsed[0] == ["yume", "na", "ra", "ba"], "exact slots only")
        check(PronunciationSlots.parse("{\"l\":[{\"i\":0,\"p\":[\"유메\",\"나\",\"라\",\"바\"]}]}", items: slotItems, notation: "latin").isEmpty,
              "wrong writing system for Latin notation")
        check(!PronunciationSlots.parse("{\"l\":[{\"i\":0,\"p\":[\"유메\",\"나\",\"라\",\"바\"]}]}", items: slotItems, notation: "translation").isEmpty,
              "target-language notation is not script-checked")
        check(PronunciationSlots.parse("{\"l\":[{\"i\":0,\"p\":[\"유메\",\"나\",\"라\",\"ㄴ\"]}]}", items: slotItems, notation: "translation").isEmpty,
              "a lone Hangul letter is asked again")
        check(PronunciationSlots.chunks(Array(repeating: slotItems[0], count: 17)).count == 9, "small chunks of two lines")
        let ramped = PronunciationRequests.batches(Array(repeating: slotItems[0], count: 7)) { PronunciationSlots.chunks($0) }
        check(ramped.map(\.count) == [1, 2, 2, 2], "the opening line goes out alone: \(ramped.map(\.count))")
        let stored = PronunciationSlots.stored(texts: ["夢ならば", "♪", " 今日も "], slots: [0: ["yume", "na", "ra", "ba"], 2: ["kyou ", "", "mo"]])
        check(stored.v == PronunciationSlots.version && stored.lines["今日も"] == ["kyou ", "", "mo"] && stored.lines.count == 2, "stored by line text")

        await checkRequests()
        print("PRONUNCIATION_FIRST_PASSED assertions=\(assertions)")
    }
}

private actor Gauge {
    var active = 0
    var peak = 0
    var peakAfterLimit = 0
    var limited = false
    var attempts: [Int: Int] = [:]
    func enter(_ job: Int) -> Int {
        active += 1
        peak = max(peak, active)
        if limited { peakAfterLimit = max(peakAfterLimit, active) }
        attempts[job, default: 0] += 1
        return attempts[job]!
    }
    func leave(limiting: Bool = false) {
        active -= 1
        if limiting { limited = true }
    }
}

private struct RateLimited: LocalizedError {
    var errorDescription: String? { "HTTP 429 — rate limited" }
}

/// PronunciationRequests: twelve at a time, follow-ups at once, rate limits halve and retry.
private func checkRequests() async {
    let gauge = Gauge()
    var handled: [Int] = []
    var errors = await PronunciationRequests.run(Array(0..<30), pause: { _ in }, perform: { job in
        _ = await gauge.enter(job)
        try? await Task.sleep(nanoseconds: 2_000_000)
        await gauge.leave()
        return job
    }) { job, answer in
        handled.append(answer)
        return job == 3 ? [100] : []
    }
    let peak = await gauge.peak
    check(errors.isEmpty && peak == 12, "twelve requests at a time (\(peak))")
    check(Set(handled) == Set(Array(0..<30) + [100]), "every job and its follow-up are handled")
    let follow = handled.firstIndex(of: 100) ?? .max
    check(follow < handled.count - 3, "the follow-up goes out before the queue is done (\(follow))")

    let limited = Gauge()
    errors = await PronunciationRequests.run(Array(0..<12), pause: { _ in }, perform: { job in
        let attempt = await limited.enter(job)
        try? await Task.sleep(nanoseconds: 2_000_000)
        if job < 4 && attempt == 1 {
            await limited.leave(limiting: true)
            throw RateLimited()
        }
        await limited.leave()
        return job
    }) { _, _ in [] }
    let after = await limited.peakAfterLimit
    let tries = await limited.attempts
    check(errors.isEmpty && tries.values.reduce(0, +) == 16, "rate-limited jobs are sent again: \(tries)")
    check(after <= 6, "half the requests after a rate limit (\(after))")

    let stuck = Gauge()
    errors = await PronunciationRequests.run([0], pause: { _ in }, perform: { job -> Int in
        _ = await stuck.enter(job)
        await stuck.leave()
        throw RateLimited()
    }) { _, _ in [] }
    let stuckTries = await stuck.attempts[0]
    check(errors.count == 1 && PronunciationRequests.isRateLimited(errors[0]) && stuckTries == 4,
          "a job that stays rate limited fails after three retries (\(stuckTries ?? 0))")
    check(PronunciationRequests.isRateLimited(NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Too Many Requests"])), "message")
}
