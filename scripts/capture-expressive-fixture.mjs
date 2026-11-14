#!/usr/bin/env node
// Capture expressive karaoke motion from the actual desktop renderer (Pages.js).
// Usage: node scripts/capture-expressive-fixture.mjs /path/to/ivLyrics/Pages.js > karaoke-expressive-desktop.json
import fs from 'node:fs';
import crypto from 'node:crypto';
import vm from 'node:vm';

const source = fs.readFileSync(process.argv[2], 'utf8');
const section = (start, end) => {
  const begin = source.indexOf(start);
  const finish = source.indexOf(end, begin);
  if (begin < 0 || finish < 0) throw new Error('Missing desktop boundary: ' + start);
  return source.slice(begin, finish);
};
const code = section('const KARAOKE_EXPRESSIVE_MOTION_STYLE =', 'const prepareKaraokeGlyphUpdates =');
const sandbox = {
  CONFIG: { visual: { 'karaoke-motion-style': 'expressive', 'karaoke-bounce': true, 'karaoke-text-effects': true } },
  prefersReducedLyricsMotion: () => false,
  KARAOKE_BOUNCE_IDLE: Object.freeze({ offsetY: 0, scale: 1, glow: 0, active: false }),
  performance: { now: () => 0 },
};
vm.createContext(sandbox);
vm.runInContext(code + '\nthis.api = { getKaraokeExpressiveMotion, classifyKaraokeExpressiveUnits, getKaraokeExpressiveWordWindow, KARAOKE_EXPRESSIVE_SETTLE_MS };', sandbox);
const api = sandbox.api;

// Springs step once per display frame. Step position and frame time together, 4 ms apart.
const trajectories = [];
for (const duration of [0, 120, 300, 650, 1000, 1800, 3200]) {
  for (const emphasis of [false, true]) {
    const key = {};
    const start = 5000;
    const samples = [];
    for (let elapsed = 0; elapsed <= duration + api.KARAOKE_EXPRESSIVE_SETTLE_MS + 40; elapsed += 4) {
      const motion = api.getKaraokeExpressiveMotion(key, start + elapsed, start, start + duration, emphasis, elapsed);
      if (elapsed % 20 === 0) samples.push([elapsed, motion.scale, motion.offsetY, motion.glow, motion.active ? 1 : 0]);
    }
    trajectories.push({ duration, emphasis, samples });
  }
}

const glyphs = (pieces) => {
  const chars = [];
  for (const [text, start, end] of pieces) {
    const letters = [...text];
    letters.forEach((char, index) => {
      const step = (end - start) / letters.length;
      chars.push({ char, startTime: start + step * index, endTime: start + step * (index + 1),
        karaokeFillStartTime: start + step * index, karaokeFillEndTime: start + step * (index + 1) });
    });
  }
  return chars;
};
const lines = [
  ['short English words', [['I ', 0, 300], ['love ', 300, 700], ['you', 700, 1000]]],
  ['held word', [['oh ', 0, 1600], ['yeah', 1600, 1900]]],
  ['long word', [['wonderfully ', 0, 900], ['bright', 900, 1200]]],
  ['fast long word', [['wonderfully', 0, 300]]],
  ['Korean syllables', [['사', 0, 200], ['랑', 200, 1500], ['해', 1500, 1700]]],
  ['Japanese and Latin', [['夢', 0, 400], ['の', 400, 600], [' GO', 600, 900], ['!', 900, 950]]],
  ['hyphenated and periods', [['well-known ', 0, 800], ['U.S.A.', 800, 2000]]],
  ['apostrophe and separators', [["don't ", 0, 500], ['--', 500, 520], ['stop', 520, 900]]],
  ['twenty-five letters', [['abcdefghijklmnopqrstuvwxy', 0, 3000]]],
];
const classifications = lines.map(([name, pieces]) => {
  const chars = glyphs(pieces);
  const { charModes, wordStarts, wordRanges } = api.classifyKaraokeExpressiveUnits(chars, true);
  const windows = chars.map((char, index) => {
    const mode = charModes[index];
    if (!mode) return null;
    if (mode === 'word') {
      let startIndex = index;
      while (!wordStarts.has(startIndex)) startIndex--;
      const range = wordRanges.get(startIndex);
      const window = api.getKaraokeExpressiveWordWindow(chars, range.startIndex, range.charCount);
      return [window.startTime, window.endTime, 0];
    }
    const emphasis = mode === 'emphasis' || char.karaokeFillEndTime - char.karaokeFillStartTime >= 1000;
    return [char.karaokeFillStartTime, char.karaokeFillEndTime, emphasis ? 1 : 0];
  });
  return { name, chars: chars.map((char) => [char.char, char.karaokeFillStartTime, char.karaokeFillEndTime]), modes: charModes, windows };
});

process.stdout.write(JSON.stringify({
  source: 'ivLyrics Pages.js expressive motion',
  sourceSha256: crypto.createHash('sha256').update(code).digest('hex'),
  stepMs: 4,
  trajectories,
  classifications,
}, null, 1) + '\n');
