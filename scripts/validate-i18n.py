#!/usr/bin/env python3
import json
import re
from pathlib import Path


source = Path(__file__).resolve().parents[1] / "ivLyrics-IOS/Resources/AppI18nStrings.json"
locales = json.loads(source.read_text(encoding="utf-8"))
reference_keys = set(locales["ko"])
errors: list[str] = []

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

if errors:
    raise SystemExit("\n".join(errors))

print(f"Validated {len(locales)} locales and {len(reference_keys)} keys")
