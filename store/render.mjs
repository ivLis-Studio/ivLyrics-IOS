// Composes App Store screenshots from simulator captures (see capture.py).
// node render.mjs [device ...]   -> out/<locale>/<device>-<nn>-<slide>.png
import { chromium } from 'playwright-core';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, unlinkSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { COPY, SONGS, SLIDES } from './slides.mjs';

const ROOT = dirname(fileURLToPath(import.meta.url));
const dataUrl = (path) => 'data:image/png;base64,' + readFileSync(join(ROOT, path)).toString('base64');

// Canvas sizes are App Store Connect's accepted sizes for each slot.
const DEVICES = {
  iphone: { w: 1206, h: 2622, pad: 92, top: 186, kicker: 34, h1: 110, sub: 44, screenW: 930, screenTop: 750, radius: 128 },
  // iPad in landscape: portrait leaves the lyric column in a third of the screen.
  ipad: { w: 2752, h: 2064, pad: 160, top: 124, kicker: 40, h1: 112, sub: 48, screenW: 1960, screenTop: 488, radius: 54, center: true, pipW: 64, pipTop: 20 },
  // iPhone Duo unfolded: the inner display in landscape, as people hold it open.
  duo: { w: 2853, h: 2007, pad: 160, top: 118, kicker: 38, h1: 108, sub: 46, screenW: 2040, screenTop: 468, radius: 86, center: true, screen: 'inner', pipW: 60, pipTop: 21 },
};

const grain = 'data:image/svg+xml;utf8,' + encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="320"><filter id="n"><feTurbulence type="fractalNoise" baseFrequency=".9" numOctaves="3" stitchTiles="stitch"/><feColorMatrix values="0 0 0 0 .5 0 0 0 0 .5 0 0 0 0 .5 0 0 0 1 0"/></filter><rect width="100%" height="100%" filter="url(#n)"/></svg>');

function capturePath(device, locale, shot) {
  const screen = DEVICES[device].screen;
  if (shot === 'home') return 'captures/' + device + '-home' + (screen ? '-' + screen : '') + '.png';
  return 'captures/' + device + '-' + locale + '-' + shot + (screen ? '-' + screen : '') + '.png';
}

function headline(text, song) {
  // [word] marks the accent; {word} is sung halfway, like the app's karaoke fill.
  return text
    .replace(/\[(.+?)\]/g, '<em>$1</em>')
    .replace(/\{(.+?)\}/g, '<span class="singing">$1</span>');
}

function html(device, locale, slide) {
  const d = DEVICES[device];
  const song = SONGS[locale];
  const copy = COPY[locale][slide.id];
  const screen = dataUrl(capturePath(device, locale, slide.shot));
  const pip = slide.pip ? dataUrl('captures/' + device + '-' + locale + '-pip-frame.png') : '';
  const screenH = Math.round(d.screenW * d.h / d.w);
  // zoom: show part of the capture, centred on (x, y) and magnified by scale, edges clamped.
  const zoom = slide.zoom;
  const zoomPos = (centre) => Math.min(0, Math.max(100 - zoom.scale * 100, 50 - centre * zoom.scale * 100));
  const zoomStyle = zoom
    ? '.screen img.base{position:absolute;width:' + zoom.scale * 100 + '%;height:' + zoom.scale * 100 + '%;left:' + zoomPos(zoom.x) + '%;top:' + zoomPos(zoom.y) + '%;}'
    : '';
  return '<!doctype html><html><head><meta charset="utf-8"><style>' +
    'html,body{margin:0;width:' + d.w + 'px;height:' + d.h + 'px;overflow:hidden;background:' + song.base + ';}' +
    '*{box-sizing:border-box}' +
    '.bg{position:absolute;inset:-12%;background:url(' + dataUrl(song.art) + ') ' + song.focus + '/cover;filter:blur(' + Math.round(d.w * 0.07) + 'px) saturate(1.25) brightness(' + song.brightness + ');}' +
    '.tint{position:absolute;inset:0;background:' + song.tint + ';}' +
    '.vignette{position:absolute;inset:0;background:radial-gradient(130% 80% at 50% 8%,rgba(0,0,0,0) 30%,rgba(0,0,0,.42) 100%),linear-gradient(180deg,rgba(0,0,0,.28) 0%,rgba(0,0,0,0) 38%,rgba(0,0,0,.5) 100%);}' +
    '.grain{position:absolute;inset:0;opacity:.09;mix-blend-mode:overlay;background:url("' + grain + '");}' +
    '.copy{position:absolute;left:' + d.pad + 'px;right:' + d.pad + 'px;top:' + d.top + 'px;font-family:Pretendard,"Pretendard JP",sans-serif;color:#fff;word-break:keep-all;}' +
    (d.center ? '.copy{text-align:center}.copy .kicker{justify-content:center}.copy .sub{margin-left:auto;margin-right:auto}' : '') +
    '.kicker{display:flex;align-items:center;gap:' + Math.round(d.kicker * 0.6) + 'px;font-weight:700;font-size:' + d.kicker + 'px;line-height:1;letter-spacing:.16em;color:' + song.accent + ';text-transform:uppercase;}' +
    '.kicker i{display:block;width:' + Math.round(d.kicker * 1.4) + 'px;height:' + Math.max(3, Math.round(d.kicker / 11)) + 'px;border-radius:9px;background:' + song.accent + ';}' +
    'h1{margin:' + Math.round(d.kicker * 0.95) + 'px 0 0;font-weight:800;font-size:' + d.h1 + 'px;line-height:1.06;letter-spacing:' + (locale === 'ko' ? '-.035em' : '-.03em') + ';}' +
    'h1 em{font-style:normal;color:' + song.accent + ';}' +
    'h1 .singing{background:linear-gradient(90deg,#fff 0%,#fff 22%,rgba(255,255,255,.4) 78%,rgba(255,255,255,.4) 100%);-webkit-background-clip:text;background-clip:text;color:transparent;}' +
    '.sub{margin-top:' + Math.round(d.sub * 0.72) + 'px;font-weight:500;font-size:' + d.sub + 'px;line-height:1.4;letter-spacing:-.01em;color:rgba(255,255,255,.7);max-width:' + Math.round(d.w * 0.82) + 'px;}' +
    '.screen{position:absolute;left:50%;top:' + d.screenTop + 'px;width:' + d.screenW + 'px;height:' + screenH + 'px;margin-left:-' + (d.screenW / 2) + 'px;border-radius:' + d.radius + 'px;overflow:hidden;' +
      'box-shadow:0 0 0 2px rgba(255,255,255,.12),0 ' + Math.round(d.w * 0.04) + 'px ' + Math.round(d.w * 0.11) + 'px rgba(0,0,0,.55),0 ' + Math.round(d.w * 0.01) + 'px ' + Math.round(d.w * 0.025) + 'px rgba(0,0,0,.35);}' +
    '.screen img.base{display:block;width:100%;height:100%;}' +
    '.screen.behind img.base{filter:blur(' + Math.round(d.screenW * 0.018) + 'px) brightness(.5) saturate(.7);transform:scale(1.04);}' +
    '.screen .pip{position:absolute;left:' + (100 - (d.pipW || 90)) / 2 + '%;width:' + (d.pipW || 90) + '%;top:' + (d.pipTop || slide.pipTop || 13) + '%;border-radius:' + Math.round(d.screenW * (d.pipW || 90) / 90 * 0.035) + 'px;overflow:hidden;box-shadow:0 ' + Math.round(d.w * 0.02) + 'px ' + Math.round(d.w * 0.06) + 'px rgba(0,0,0,.55),0 0 0 1px rgba(255,255,255,.14);}' +
    '.screen .pip img{display:block;width:100%;}' +
    zoomStyle +
    '</style></head><body>' +
    '<div class="bg"></div><div class="tint"></div><div class="vignette"></div><div class="grain"></div>' +
    '<div class="copy"><div class="kicker"><i></i>' + copy.kicker + '</div><h1>' + headline(copy.title, song) + '</h1><div class="sub">' + copy.sub + '</div></div>' +
    '<div class="screen' + (pip ? ' behind' : '') + '"><img class="base" src="' + screen + '">' + (pip ? '<div class="pip"><img src="' + pip + '"></div>' : '') + '</div>' +
    '</body></html>';
}

const devices = process.argv.slice(2).length ? process.argv.slice(2) : Object.keys(DEVICES);
// Installed Google Chrome; set PLAYWRIGHT_CHANNEL= to use a Playwright-managed browser instead.
const channel = process.env.PLAYWRIGHT_CHANNEL ?? 'chrome';
const browser = await chromium.launch(channel ? { channel } : {});
try {
  for (const device of devices) {
    const d = DEVICES[device];
    const page = await browser.newPage({ viewport: { width: d.w, height: d.h }, deviceScaleFactor: 1 });
    for (const locale of Object.keys(SONGS)) {
      // Drop this device's earlier renders so a reordered set leaves no stale slides behind.
      const outDir = join(ROOT, 'out', locale);
      if (existsSync(outDir)) {
        for (const name of readdirSync(outDir)) {
          if (name.startsWith(device + '-')) unlinkSync(join(outDir, name));
        }
      }
      const slides = SLIDES[device];
      for (const [index, slide] of slides.entries()) {
        const needed = [capturePath(device, locale, slide.shot)];
        if (!needed.every((path) => existsSync(join(ROOT, path)))) {
          console.warn('skip (missing capture)', device, locale, slide.id);
          continue;
        }
        await page.setContent(html(device, locale, slide), { waitUntil: 'load' });
        await page.evaluate(() => document.fonts.ready);
        const out = join(ROOT, 'out', locale, device + '-' + String(index + 1).padStart(2, '0') + '-' + slide.id + '.png');
        mkdirSync(dirname(out), { recursive: true });
        await page.screenshot({ path: out, type: 'png' });
        // App Store Connect rejects alpha channels; flatten to RGB.
        execFileSync('sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '95', out, '--out', out.replace(/\.png$/, '.jpg')], { stdio: 'ignore' });
        console.log(out.replace(/\.png$/, '.jpg'));
      }
    }
    await page.close();
  }
} finally {
  await browser.close();
}

