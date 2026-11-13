#!/usr/bin/env python3
"""Capture App Store screenshot sources from the simulator with the DEBUG store fixture.

Usage: capture.py <device-udid> <iphone|ipad|duo> <en|ko> [shot ...]
Raw PNGs land in store/captures/<device>-<locale>-<shot>.png (duo: -outer / -inner).
Duo: unfold it in Device Hub (Open) for the inner display, and set IVLYRICS_STORE_DUO_SCREEN=inner|outer
so the folded-away display (black) does not overwrite an earlier capture.
"""
import json, os, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DEV = os.environ.get("DEVELOPER_DIR", "/Volumes/Payrouser/DevStorage/Xcode/x271/Xcode.app/Contents/Developer")
APP = os.environ.get("IVLYRICS_STORE_APP", "/tmp/ivl-duo-dd/Build/Products/Debug-iphonesimulator/ivLyrics-IOS.app")
BUNDLE = "kr.ivlis.ivlyrics.ios"
SONGS = {
    "en": dict(song="store-ko", title="Starlit Night", artist="Lumen Avenue", art="covers/starlit-night.png"),
    "ko": dict(song="store-ja", title="夜明けのメロディー", artist="Mira Signal", art="covers/yoake-melody.png"),
}


def line_start(index):
    cursor = 1500
    for i in range(index):
        cursor += 3200 + (i % 3) * 200 + (1200 if i == 5 else 300)
    return cursor, 3200 + (index % 3) * 200


def at(index, fraction):
    start, duration = line_start(index)
    return start + int(duration * fraction)


SHOTS = {
    "lyrics": dict(env={"IVLYRICS_DEBUG_SHOW_LYRICS": "1"}, ms=at(6, 0.55)),
    "pronfirst": dict(env={"IVLYRICS_DEBUG_SHOW_LYRICS": "1"}, ms=at(6, 0.55),
                      defaults={"pronunciation_first_enabled": True}),
    "player": dict(env={}, ms=at(2, 0.5)),
    "vinyl": dict(env={"IVLYRICS_DEBUG_SHOW_VINYL": "1"}, ms=at(4, 0.5), defaults={
        # LP mode's own size settings (Settings > LP mode); the 100% / 70% defaults leave the
        # record and its lyric line small on the wider iPad and Duo screens.
        "preview_items": 1 | 4,
    }),
    "menu": dict(env={"IVLYRICS_DEBUG_SHOW_META_MENU": "1", "IVLYRICS_DEBUG_META_TAB": "language"}, ms=at(6, 0.4)),
    "pip": dict(env={"IVLYRICS_DEBUG_PIP_LAYOUT": "1", "IVLYRICS_DEBUG_PIP_CURRENT": "1"}, ms=at(6, 0.55)),
}

# Record and sleeve scale for the LP shot, as large as each screen holds without crowding.
VINYL_SCALE = {"iphone": 118, "ipad": 140, "duo": 140}

# Text sizes (Settings > Typography, 70-160%). Phone defaults read small on a 13-inch iPad.
TYPOGRAPHY = {
    "iphone": {"vinyl_original": 108, "vinyl_translation": 92},
    "duo": {"vinyl_original": 108, "vinyl_translation": 92},
    "ipad": {
        "main_title": 130, "main_artist": 125,
        "lyrics_original": 150, "lyrics_pronunciation": 140, "lyrics_translation": 140,
        "main_preview_original": 140, "main_preview_pronunciation": 135, "main_preview_translation": 135,
        "vinyl_original": 150, "vinyl_translation": 130,
    },
}


def typography(kind):
    styles = {slot: {"size": size} for slot, size in TYPOGRAPHY[kind].items()}
    styles["vinyl_original"]["weight"] = "bold"
    return json.dumps(styles)


def simctl(*args, env=None, check=True):
    return subprocess.run(["xcrun", "simctl", *args], check=check, env={**os.environ, "DEVELOPER_DIR": DEV, **(env or {})},
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout


def displays(udid):
    out = simctl("io", udid, "enumerate")
    ids, current = [], {}
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("UUID:"):
            current = {"uuid": line.split(":", 1)[1].strip()}
        elif line.startswith("Display class: 0"):
            current["integrated"] = True
        elif line.startswith("Default width:"):
            current["w"] = int(line.split(":")[1])
        elif line.startswith("Default height:"):
            current["h"] = int(line.split(":")[1])
            if current.get("integrated"):
                ids.append(dict(current))
    return ids


def main():
    udid, kind, locale, *wanted = sys.argv[1:]
    song = SONGS[locale]
    only = os.environ.get("IVLYRICS_STORE_DUO_SCREEN")
    # The iPad status bar shows the date in the simulator's language; match the screenshot locale.
    if os.environ.get("IVLYRICS_STORE_SET_LOCALE") == "1":
        lang, region = ("en", "en_US") if locale == "en" else ("ko", "ko_KR")
        simctl("boot", udid, check=False)
        simctl("bootstatus", udid, "-b")
        simctl("spawn", udid, "defaults", "write", "-g", "AppleLanguages", "-array", lang)
        simctl("spawn", udid, "defaults", "write", "-g", "AppleLocale", "-string", region)
        simctl("shutdown", udid, check=False)
    simctl("boot", udid, check=False)
    simctl("bootstatus", udid, "-b")
    simctl("status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100",
           "--cellularMode", "active", "--cellularBars", "4", "--wifiBars", "3", "--dataNetwork", "5g", check=False)
    simctl("install", udid, APP)
    simctl("spawn", udid, "defaults", "write", BUNDLE, "lyrics_meta_menu_tip_shown", "-bool", "YES")
    (ROOT / "captures").mkdir(exist_ok=True)
    for name in wanted or list(SHOTS):
        if name == "home":
            # Backdrop for the PiP composite: the home screen with ivLyrics closed.
            simctl("terminate", udid, BUNDLE, check=False)
            time.sleep(2.5)
            if kind == "duo" and only:
                path = ROOT / "captures" / f"{kind}-home-{only}.png"
                simctl("io", udid, "screenshot", "--display=" + ("LCD-1" if only == "inner" else "LCD"), str(path))
            else:
                path = ROOT / "captures" / f"{kind}-home.png"
                simctl("io", udid, "screenshot", str(path))
            print(path)
            continue
        shot = SHOTS[name]
        # A brighter artwork backdrop than the default 30 so the screens carry the cover's color.
        defaults = {"lyrics_meta_menu_tip_shown": True, "background_brightness": 46, **shot.get("defaults", {})}
        # The PiP frame is a fixed 640x360 canvas on every device, so it keeps the phone sizes.
        defaults["typography_settings_v1"] = typography("iphone" if name == "pip" else kind)
        if name == "vinyl":
            defaults["vinyl_record_size_percent"] = VINYL_SCALE[kind]
            defaults["vinyl_album_size_percent"] = VINYL_SCALE[kind]
        env = {
            "IVLYRICS_UI_SURFACE": "player",
            "IVLYRICS_UI_LANGUAGE": locale,
            "IVLYRICS_UI_CONFIGURED_LANGUAGE": "1",
            "IVLYRICS_UI_DEFAULTS_JSON": json.dumps(defaults),
            "IVLYRICS_DEBUG_FIXTURE": "1",
            "IVLYRICS_DEBUG_FIXTURE_SONG": song["song"],
            "IVLYRICS_DEBUG_FIXTURE_TITLE": song["title"],
            "IVLYRICS_DEBUG_FIXTURE_ARTIST": song["artist"],
            "IVLYRICS_DEBUG_FIXTURE_ARTWORK": str(ROOT / song["art"]),
            "IVLYRICS_DEBUG_FIXTURE_START_MS": str(shot["ms"]),
            **shot["env"],
        }
        if not shot.get("live"):
            env["IVLYRICS_DEBUG_FIXTURE_FROZEN"] = "1"
        wait = float(os.environ.get("IVLYRICS_STORE_WAIT", "7"))
        child = {"SIMCTL_CHILD_" + key: value for key, value in env.items()}
        simctl("launch", "--terminate-running-process", udid, BUNDLE, "--ivlyrics-ui-test", env=child)
        time.sleep(2.6 if shot.get("live") else wait)
        screens = displays(udid)
        if kind == "duo":
            for screen in screens:
                label = "outer" if screen["w"] < 1500 else "inner"
                if only and label != only:
                    continue
                path = ROOT / "captures" / f"{kind}-{locale}-{name}-{label}.png"
                simctl("io", udid, "screenshot", f"--display={screen['uuid']}", str(path))
                print(path)
        else:
            path = ROOT / "captures" / f"{kind}-{locale}-{name}.png"
            simctl("io", udid, "screenshot", str(path))
            print(path)


if __name__ == "__main__":
    main()

