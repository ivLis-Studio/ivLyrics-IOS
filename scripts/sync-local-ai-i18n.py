#!/usr/bin/env python3
"""Copy the Local AI provider strings from the PC addon's language files into the iOS bundle.

Usage: scripts/sync-local-ai-i18n.py localmodel_i18n.json localmodel_i18n_v2.json

Both inputs map PC language files (LangKo.js, LangZhCN.js, ...) to {"description", "strings"}.
The model file and recommendation strings are PC-only. Three strings change for iOS: a touch
"tap again" confirmation, "GPU" instead of WebGPU, and a privacy note without the engine download
(the engine ships inside the app).
"""

import argparse
import json
import re
from pathlib import Path

LANGUAGES = {
    "LangKo.js": "ko", "LangEn.js": "en", "LangZhCN.js": "zh-CN", "LangZhTW.js": "zh-TW", "LangJa.js": "ja",
    "LangHi.js": "hi", "LangEs.js": "es", "LangFr.js": "fr", "LangAr.js": "ar", "LangFa.js": "fa",
    "LangDe.js": "de", "LangRu.js": "ru", "LangSv.js": "sv", "LangPt.js": "pt", "LangBn.js": "bn",
    "LangCs.js": "cs", "LangIt.js": "it", "LangTh.js": "th", "LangVi.js": "vi", "LangId.js": "id",
    "LangMs.js": "ms", "LangTr.js": "tr",
}

# PC key -> iOS key.
KEYS = {
    "quality": "local_ai.quality",
    "tierLight": "local_ai.tier_light",
    "tierMedium": "local_ai.tier_medium",
    "tierHigh": "local_ai.tier_high",
    "tierHint": "local_ai.tier_hint",
    "tierDownloaded": "local_ai.tier_downloaded",
    "device": "local_ai.device",
    "deviceAuto": "local_ai.device_auto",
    "deviceCpu": "local_ai.device_cpu",
    "idleUnload": "local_ai.idle_unload",
    "idleAfter": "local_ai.idle_after",
    "idleAfterHours": "local_ai.idle_after_hours",
    "idleNever": "local_ai.idle_never",
    "statusNotDownloaded": "local_ai.status_not_downloaded",
    "statusDownloading": "local_ai.status_downloading",
    "statusDownloaded": "local_ai.status_downloaded",
    "statusLoading": "local_ai.status_loading",
    "statusReady": "local_ai.status_ready",
    "statusError": "local_ai.status_error",
    "download": "local_ai.download",
    "cancel": "local_ai.cancel",
    "unload": "local_ai.unload",
    "remove": "local_ai.remove",
    "confirmRemove": "local_ai.confirm_remove",
    "test": "local_ai.test",
    "privacy": "local_ai.privacy",
    "notReady": "local_ai.not_ready",
    "unsupportedLanguage": "local_ai.unsupported_language",
    "downloadBusy": "local_ai.download_busy",
}
PC_ONLY = {"modelFile", "recommended"}

# "Click again to delete" becomes the platform's tap wording where the PC text says "click".
TAP_AGAIN = {
    "en": ("Click again to delete", "Tap again to delete"),
    "ja": ("もう一度クリックすると削除します", "もう一度タップすると削除します"),
    "hi": ("हटाने के लिए फिर से क्लिक करें", "हटाने के लिए फिर से टैप करें"),
    "es": ("Haz clic de nuevo para eliminar", "Toca de nuevo para eliminar"),
    "fr": ("Cliquez à nouveau pour supprimer", "Touchez à nouveau pour supprimer"),
    "ar": ("انقر مرة أخرى للحذف", "اضغط مرة أخرى للحذف"),
    "fa": ("برای حذف، دوباره کلیک کنید", "برای حذف، دوباره ضربه بزنید"),
    "de": ("Zum Löschen erneut klicken", "Zum Löschen erneut tippen"),
    "sv": ("Klicka igen för att ta bort", "Tryck igen för att ta bort"),
    "pt": ("Clique novamente para excluir", "Toque novamente para excluir"),
    "bn": ("মুছতে আবার ক্লিক করুন", "মুছতে আবার ট্যাপ করুন"),
    "cs": ("Klikněte znovu pro smazání", "Klepněte znovu pro smazání"),
    "it": ("Fai clic di nuovo per eliminare", "Tocca di nuovo per eliminare"),
    "th": ("คลิกอีกครั้งเพื่อลบ", "แตะอีกครั้งเพื่อลบ"),
    "vi": ("Nhấp lại để xóa", "Chạm lại để xóa"),
    "id": ("Klik lagi untuk menghapus", "Ketuk lagi untuk menghapus"),
    "ms": ("Klik sekali lagi untuk memadam", "Ketik sekali lagi untuk memadam"),
    "tr": ("Silmek için tekrar tıklayın", "Silmek için tekrar dokunun"),
}

# The engine is part of the app on iOS; only the model is downloaded.
MODEL_ONLY_DOWNLOAD = {
    "ko": ("실행 엔진(jsDelivr)과 모델(Hugging Face)은 처음 한 번만 내려받습니다.", "모델(Hugging Face)은 처음 한 번만 내려받습니다."),
    "en": ("The engine (jsDelivr) and the model (Hugging Face) are downloaded only once.", "The model (Hugging Face) is downloaded only once."),
    "zh-CN": ("运行引擎 (jsDelivr) 和模型 (Hugging Face) 只需下载一次。", "模型 (Hugging Face) 只需下载一次。"),
    "zh-TW": ("執行引擎 (jsDelivr) 與模型 (Hugging Face) 只需下載一次。", "模型 (Hugging Face) 只需下載一次。"),
    "ja": ("実行エンジン (jsDelivr) とモデル (Hugging Face) のダウンロードは最初の一度だけです。", "モデル (Hugging Face) のダウンロードは最初の一度だけです。"),
    "hi": ("इंजन (jsDelivr) और मॉडल (Hugging Face) सिर्फ़ एक बार डाउनलोड होते हैं।", "मॉडल (Hugging Face) सिर्फ़ एक बार डाउनलोड होता है।"),
    "es": ("El motor (jsDelivr) y el modelo (Hugging Face) se descargan una sola vez.", "El modelo (Hugging Face) se descarga una sola vez."),
    "fr": ("Le moteur (jsDelivr) et le modèle (Hugging Face) ne sont téléchargés qu'une seule fois.", "Le modèle (Hugging Face) n'est téléchargé qu'une seule fois."),
    "ar": ("يتم تنزيل المحرك (jsDelivr) والنموذج (Hugging Face) مرة واحدة فقط.", "يتم تنزيل النموذج (Hugging Face) مرة واحدة فقط."),
    "fa": ("موتور اجرا (jsDelivr) و مدل (Hugging Face) فقط یک بار دانلود می‌شوند.", "مدل (Hugging Face) فقط یک بار دانلود می‌شود."),
    "de": ("Engine (jsDelivr) und Modell (Hugging Face) werden nur einmal heruntergeladen.", "Das Modell (Hugging Face) wird nur einmal heruntergeladen."),
    "ru": ("Движок (jsDelivr) и модель (Hugging Face) скачиваются только один раз.", "Модель (Hugging Face) скачивается только один раз."),
    "sv": ("Motorn (jsDelivr) och modellen (Hugging Face) laddas bara ner en gång.", "Modellen (Hugging Face) laddas bara ner en gång."),
    "pt": ("O mecanismo (jsDelivr) e o modelo (Hugging Face) são baixados apenas uma vez.", "O modelo (Hugging Face) é baixado apenas uma vez."),
    "bn": ("ইঞ্জিন (jsDelivr) ও মডেল (Hugging Face) শুধু একবারই ডাউনলোড হয়।", "মডেল (Hugging Face) শুধু একবারই ডাউনলোড হয়।"),
    "cs": ("Engine (jsDelivr) a model (Hugging Face) se stahují jen jednou.", "Model (Hugging Face) se stahuje jen jednou."),
    "it": ("Il motore (jsDelivr) e il modello (Hugging Face) vengono scaricati una sola volta.", "Il modello (Hugging Face) viene scaricato una sola volta."),
    "th": ("เอนจิน (jsDelivr) และโมเดล (Hugging Face) จะดาวน์โหลดเพียงครั้งเดียว", "โมเดล (Hugging Face) จะดาวน์โหลดเพียงครั้งเดียว"),
    "vi": ("Công cụ thực thi (jsDelivr) và mô hình (Hugging Face) chỉ cần tải xuống một lần.", "Mô hình (Hugging Face) chỉ cần tải xuống một lần."),
    "id": ("Mesin (jsDelivr) dan model (Hugging Face) hanya diunduh sekali.", "Model (Hugging Face) hanya diunduh sekali."),
    "ms": ("Enjin (jsDelivr) dan model (Hugging Face) hanya dimuat turun sekali.", "Model (Hugging Face) hanya dimuat turun sekali."),
    "tr": ("Motor (jsDelivr) ve model (Hugging Face) yalnızca bir kez indirilir.", "Model (Hugging Face) yalnızca bir kez indirilir."),
}

FORBIDDEN = re.compile(r"Hy-MT|Q4_K|Q6_K|Q8_0|GGUF|Tencent|wllama|jsDelivr|WebGPU", re.IGNORECASE)


def replace_exact(value: str, old: str, new: str, where: str) -> str:
    if old not in value:
        raise SystemExit(f"{where}: expected PC text {old!r} in {value!r}")
    return value.replace(old, new)


def ios_strings(language: str, v1: dict, v2: dict) -> dict:
    source = dict(v1["strings"])
    source.update(v2["strings"])
    unknown = set(source) - set(KEYS) - PC_ONLY
    missing = set(KEYS) - set(source)
    if unknown or missing:
        raise SystemExit(f"{language}: unexpected keys {sorted(unknown)}, missing keys {sorted(missing)}")
    strings = {"local_ai.description": v2["description"]}
    for pc_key, ios_key in KEYS.items():
        strings[ios_key] = source[pc_key]
    strings["local_ai.device_auto"] = replace_exact(strings["local_ai.device_auto"], "WebGPU", "GPU", f"{language}.deviceAuto")
    if language in TAP_AGAIN:
        old, new = TAP_AGAIN[language]
        strings["local_ai.confirm_remove"] = replace_exact(strings["local_ai.confirm_remove"], old, new, f"{language}.confirmRemove")
    old, new = MODEL_ONLY_DOWNLOAD[language]
    strings["local_ai.privacy"] = replace_exact(strings["local_ai.privacy"], old, new, f"{language}.privacy")
    for key, value in strings.items():
        if FORBIDDEN.search(value):
            raise SystemExit(f"{language}.{key}: shows a model, file or engine name: {value!r}")
    return strings


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("v1", type=Path, help="localmodel_i18n.json")
    parser.add_argument("v2", type=Path, help="localmodel_i18n_v2.json")
    parser.add_argument(
        "--ios-json",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "ivLyrics-IOS/Resources/AppI18nStrings.json",
    )
    args = parser.parse_args()

    v1 = json.loads(args.v1.read_text(encoding="utf-8"))
    v2 = json.loads(args.v2.read_text(encoding="utf-8"))
    bundle = json.loads(args.ios_json.read_text(encoding="utf-8"))
    if set(LANGUAGES) != set(v1) or set(LANGUAGES) != set(v2) or set(LANGUAGES.values()) != set(bundle):
        raise SystemExit("PC and iOS language sets do not match")
    for pc_file, language in LANGUAGES.items():
        bundle[language].update(ios_strings(language, v1[pc_file], v2[pc_file]))

    args.ios_json.write_text(json.dumps(bundle, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()

