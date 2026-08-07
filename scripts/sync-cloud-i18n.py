#!/usr/bin/env python3
"""Copy the shared OpenCloudSave UI strings from Android into the iOS bundle."""

import argparse
import json
import re
from pathlib import Path


CANCEL = {
    "ko": "취소", "en": "Cancel", "zh-CN": "取消", "zh-TW": "取消", "ja": "キャンセル",
    "hi": "रद्द करें", "es": "Cancelar", "fr": "Annuler", "ar": "إلغاء", "fa": "لغو",
    "de": "Abbrechen", "ru": "Отмена", "sv": "Avbryt", "pt": "Cancelar", "bn": "বাতিল",
    "cs": "Zrušit", "it": "Annulla", "th": "ยกเลิก", "vi": "Hủy", "id": "Batal",
    "ms": "Batal", "tr": "İptal",
}


def java_strings(block: str) -> list[str]:
    return [json.loads('"' + value + '"') for value in re.findall(r'"((?:\\.|[^"\\])*)"', block)]


def ios_cloud_string(value: str) -> str:
    return value.replace("Android", "iOS")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("android_source", type=Path)
    parser.add_argument(
        "--ios-json",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "ivLyrics-IOS/Resources/AppI18nStrings.json",
    )
    args = parser.parse_args()

    source = args.android_source.read_text(encoding="utf-8")
    add_start = source.index("private static void addCloudSyncStrings")
    values_start = source.index("private static String[] cloudSyncStrings", add_start)
    next_method = source.index("private static String[] creatorPrivacyStrings", values_start)
    keys = [value for value in java_strings(source[add_start:values_start]) if value.startswith("cloud_sync.")]
    method = source[values_start:next_method]
    translations: dict[str, list[str]] = {}
    for language, block in re.findall(r'case "([^"]+)": return new String\[\] \{(.*?)\n\s*\};', method, re.S):
        translations[language] = java_strings(block)
    default_match = re.search(r'default: return new String\[\] \{(.*?)\n\s*\};', method, re.S)
    if default_match:
        translations["en"] = java_strings(default_match.group(1))

    bundle = json.loads(args.ios_json.read_text(encoding="utf-8"))
    if set(bundle) != set(translations) or set(bundle) != set(CANCEL):
        raise SystemExit("Android and iOS locale sets do not match")
    for language, table in bundle.items():
        values = translations[language]
        if len(values) != len(keys):
            raise SystemExit(f"{language}: expected {len(keys)} strings, found {len(values)}")
        table.update({key: ios_cloud_string(value) for key, value in zip(keys, values)})
        table["button.cancel"] = CANCEL[language]

    args.ios_json.write_text(json.dumps(bundle, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
