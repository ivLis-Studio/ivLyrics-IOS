#!/usr/bin/env python3
import json
import re
from pathlib import Path


source = Path(__file__).resolve().parents[1] / "ivLyrics-IOS/Resources/AppI18nStrings.json"
locales = json.loads(source.read_text(encoding="utf-8"))
reference_keys = set(locales["ko"])
errors: list[str] = []
placeholders = re.compile(r"\{\w+\}|%(?:\d+\$)?[sd@]")

# iOS-only strings used to live in Korean/English fallbacks, outside this bundle.
fallback_source = (source.parents[1] / "AppI18n.swift").read_text(encoding="utf-8")
fallback_block = fallback_source.split('"ko": [', 1)[1].split('"en": [', 1)[0]
fallback_keys = set(re.findall(r'^\s*"([^"]+)": "', fallback_block, flags=re.MULTILINE))
for key in sorted(fallback_keys - reference_keys):
    errors.append(f"iOS fallback key missing from localized bundle: {key}")

for locale, strings in locales.items():
    keys = set(strings)
    missing = sorted(reference_keys - keys)
    extra = sorted(keys - reference_keys)
    if missing:
        errors.append(f"{locale}: missing keys: {', '.join(missing)}")
    if extra:
        errors.append(f"{locale}: unexpected keys: {', '.join(extra)}")
    for key, value in strings.items():
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{locale}.{key}: empty translation")
        elif re.search(r"[^\W\d_]\d{3}$", value, flags=re.UNICODE):
            errors.append(f"{locale}.{key}: suspicious numeric suffix: {value!r}")
        elif key in locales["ko"] and sorted(placeholders.findall(value)) != sorted(placeholders.findall(locales["ko"][key])):
            errors.append(f"{locale}.{key}: translation placeholders do not match Korean")

if errors:
    raise SystemExit("\n".join(errors))

print(f"Validated {len(locales)} locales and {len(reference_keys)} keys")
