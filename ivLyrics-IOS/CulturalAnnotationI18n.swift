import Foundation

enum CulturalAnnotationI18n {
    private static let keys = [
        "setting.cultural_annotations",
        "setting.cultural_annotations_desc",
        "setting.cultural_font_family",
        "setting.cultural_font_size",
        "setting.cultural_font_weight",
        "setting.cultural_opacity",
        "loading.cultural_annotations",
        "font.pretendard",
        "font.system",
        "font.serif",
        "font.monospace",
        "button.regenerate_cultural_annotations"
    ]

    private static let values: [String: [String]] = [
        "ko": [
            "문화적 배경 설명",
            "번역만으로 이해하기 어려운 문화적 배경이 있는 가사 줄 아래에만 AI 설명을 표시합니다. 번역 대상 언어를 사용합니다. 일반 가사 페이지, 일반 전체화면, LP 모드에서 표시되며 Now Playing과 PIP에는 표시되지 않습니다.",
            "설명 글꼴", "설명 글자 크기", "설명 글자 굵기", "설명 불투명도", "문화적 설명",
            "Pretendard", "시스템", "명조체", "고정폭", "문화적 설명 재생성"
        ],
        "en": [
            "Cultural context explanations",
            "Show AI explanations only under lyric lines whose cultural background would otherwise be lost in translation. Uses the translation target language. Shown on the normal lyrics page, fullscreen, and LP mode, but not in Now Playing or PIP.",
            "Explanation font", "Explanation font size", "Explanation font weight", "Explanation opacity", "Cultural context explanations",
            "Pretendard", "System", "Serif", "Monospace", "Regenerate cultural explanations"
        ],
        "zh-CN": [
            "文化背景说明",
            "仅在翻译难以传达文化背景的歌词行下方显示 AI 生成的说明。使用翻译目标语言。显示在普通歌词页面、普通全屏和 LP 模式中，不会显示在正在播放或画中画中。",
            "说明字体", "说明字号", "说明字重", "说明不透明度", "文化背景说明",
            "Pretendard", "系统", "衬线", "等宽", "重新生成文化背景说明"
        ],
        "zh-TW": [
            "文化背景說明",
            "僅在翻譯難以傳達文化背景的歌詞行下方顯示 AI 產生的說明。使用翻譯目標語言。顯示於一般歌詞頁面、一般全螢幕與 LP 模式，不會顯示於正在播放或子母畫面。",
            "說明字型", "說明字型大小", "說明字重", "說明不透明度", "文化背景說明",
            "Pretendard", "系統", "襯線", "等寬", "重新產生文化背景說明"
        ],
        "ja": [
            "文化的背景の解説",
            "翻訳だけでは伝わりにくい文化的背景がある歌詞の行にのみ、AIによる解説を表示します。翻訳先の言語を使用します。通常の歌詞ページ、全画面表示、LPモードに表示され、再生中画面とPIPには表示されません。",
            "解説のフォント", "解説の文字サイズ", "解説の文字の太さ", "解説の不透明度", "文化的背景の解説",
            "Pretendard", "システム", "セリフ", "等幅", "文化的背景の解説を再生成"
        ],
        "hi": [
            "सांस्कृतिक संदर्भ की व्याख्या",
            "केवल उन गीत पंक्तियों के नीचे AI व्याख्या दिखाता है जिनकी सांस्कृतिक पृष्ठभूमि अनुवाद में खो सकती है। अनुवाद की लक्षित भाषा का उपयोग करता है। यह सामान्य लिरिक्स पेज, फ़ुलस्क्रीन और LP मोड में दिखता है, लेकिन Now Playing या PIP में नहीं।",
            "व्याख्या का फ़ॉन्ट", "व्याख्या का फ़ॉन्ट आकार", "व्याख्या का फ़ॉन्ट वज़न", "व्याख्या की अपारदर्शिता", "सांस्कृतिक संदर्भ की व्याख्या",
            "Pretendard", "सिस्टम", "सेरिफ़", "मोनोस्पेस", "सांस्कृतिक व्याख्या फिर बनाएँ"
        ],
        "es": [
            "Explicaciones del contexto cultural",
            "Muestra explicaciones de IA solo bajo los versos cuyo trasfondo cultural se perdería al traducirlos. Usa el idioma de destino. Aparece en la página normal, en pantalla completa y en el modo LP, pero no en En reproducción ni PIP.",
            "Fuente de las explicaciones", "Tamaño de las explicaciones", "Grosor de las explicaciones", "Opacidad de las explicaciones", "Explicaciones del contexto cultural",
            "Pretendard", "Sistema", "Serif", "Monoespaciada", "Regenerar explicaciones culturales"
        ],
        "fr": [
            "Explications du contexte culturel",
            "Affiche des explications IA uniquement sous les lignes dont le contexte culturel serait perdu à la traduction. Utilise la langue cible. Visible sur la page normale, en plein écran et en mode LP, mais pas dans Lecture en cours ni PIP.",
            "Police des explications", "Taille des explications", "Graisse des explications", "Opacité des explications", "Explications du contexte culturel",
            "Pretendard", "Système", "Avec empattements", "Chasse fixe", "Régénérer les explications culturelles"
        ],
        "ar": [
            "شرح السياق الثقافي",
            "يعرض شرحاً بالذكاء الاصطناعي فقط تحت الأسطر التي قد تضيع خلفيتها الثقافية في الترجمة. يستخدم لغة الترجمة المستهدفة. يظهر في صفحة الكلمات العادية والشاشة الكاملة ووضع LP، وليس في التشغيل الحالي أو PIP.",
            "خط الشرح", "حجم خط الشرح", "سماكة خط الشرح", "شفافية الشرح", "شرح السياق الثقافي",
            "Pretendard", "النظام", "مذيل", "أحادي المسافة", "إعادة إنشاء الشرح الثقافي"
        ],
        "fa": [
            "توضیح زمینه فرهنگی",
            "فقط زیر سطرهایی که زمینه فرهنگی آن‌ها در ترجمه از بین می‌رود، توضیح هوش مصنوعی نمایش می‌دهد. از زبان مقصد استفاده می‌کند. در صفحه عادی، تمام‌صفحه و حالت LP دیده می‌شود، نه در پخش فعلی یا PIP.",
            "قلم توضیح", "اندازه قلم توضیح", "ضخامت قلم توضیح", "شفافیت توضیح", "توضیح زمینه فرهنگی",
            "Pretendard", "سیستم", "سریف", "تک‌فاصله", "تولید دوباره توضیح فرهنگی"
        ],
        "de": [
            "Kulturellen Kontext erklären",
            "Zeigt KI-Erklärungen nur unter Zeilen, deren kultureller Hintergrund bei der Übersetzung verloren ginge. Verwendet die Zielsprache. Auf der normalen Textseite, im Vollbild und im LP-Modus sichtbar, nicht in Aktueller Titel oder PIP.",
            "Schriftart der Erklärung", "Schriftgröße der Erklärung", "Schriftstärke der Erklärung", "Deckkraft der Erklärung", "Kulturellen Kontext erklären",
            "Pretendard", "System", "Serif", "Dicktengleich", "Kulturelle Erklärungen neu erstellen"
        ],
        "ru": [
            "Пояснения культурного контекста",
            "Показывает пояснения ИИ только под строками, культурный фон которых теряется при переводе. Использует язык перевода. Видно на обычной странице, в полноэкранном режиме и режиме LP, но не в Сейчас играет или PIP.",
            "Шрифт пояснений", "Размер шрифта пояснений", "Толщина шрифта пояснений", "Непрозрачность пояснений", "Пояснения культурного контекста",
            "Pretendard", "Системный", "С засечками", "Моноширинный", "Создать культурные пояснения заново"
        ],
        "sv": [
            "Förklaringar av kulturell kontext",
            "Visar AI-förklaringar endast under rader vars kulturella bakgrund annars förloras i översättningen. Använder målspråket. Visas på den vanliga textsidan, i helskärm och i LP-läge, men inte i Nu spelas eller PIP.",
            "Förklaringens typsnitt", "Förklaringens textstorlek", "Förklaringens teckenvikt", "Förklaringens opacitet", "Förklaringar av kulturell kontext",
            "Pretendard", "System", "Serif", "Fast bredd", "Skapa kulturförklaringar på nytt"
        ],
        "pt": [
            "Explicações de contexto cultural",
            "Mostra explicações de IA apenas sob os versos cujo contexto cultural se perderia na tradução. Usa o idioma de destino. Aparece na página normal, em tela cheia e no modo LP, mas não em Reproduzindo agora ou PIP.",
            "Fonte das explicações", "Tamanho das explicações", "Peso das explicações", "Opacidade das explicações", "Explicações de contexto cultural",
            "Pretendard", "Sistema", "Serif", "Monoespaçada", "Gerar explicações culturais novamente"
        ],
        "bn": [
            "সাংস্কৃতিক প্রেক্ষাপটের ব্যাখ্যা",
            "অনুবাদে সাংস্কৃতিক পটভূমি হারিয়ে গেলে শুধু সেই লাইনের নিচে AI ব্যাখ্যা দেখায়। অনুবাদের লক্ষ্য ভাষা ব্যবহার করে। এটি সাধারণ লিরিক্স পৃষ্ঠা, পূর্ণস্ক্রিন ও LP মোডে দেখা যায়; Now Playing বা PIP-তে নয়।",
            "ব্যাখ্যার ফন্ট", "ব্যাখ্যার ফন্টের আকার", "ব্যাখ্যার ফন্টের ওজন", "ব্যাখ্যার অস্বচ্ছতা", "সাংস্কৃতিক প্রেক্ষাপটের ব্যাখ্যা",
            "Pretendard", "সিস্টেম", "সেরিফ", "মনোস্পেস", "সাংস্কৃতিক ব্যাখ্যা আবার তৈরি করুন"
        ],
        "cs": [
            "Vysvětlení kulturního kontextu",
            "Zobrazí vysvětlení AI pouze pod řádky, u nichž by se kulturní kontext v překladu ztratil. Použije cílový jazyk. Zobrazuje se na běžné stránce, na celé obrazovce a v režimu LP, ne v Právě hraje ani PIP.",
            "Písmo vysvětlení", "Velikost písma vysvětlení", "Tloušťka písma vysvětlení", "Krytí vysvětlení", "Vysvětlení kulturního kontextu",
            "Pretendard", "Systém", "Patkové", "Neproporcionální", "Znovu vytvořit kulturní vysvětlení"
        ],
        "it": [
            "Spiegazioni del contesto culturale",
            "Mostra spiegazioni IA solo sotto i versi il cui contesto culturale andrebbe perso nella traduzione. Usa la lingua di destinazione. Visibile nella pagina normale, a schermo intero e in modalità LP, non in In riproduzione o PIP.",
            "Font delle spiegazioni", "Dimensione delle spiegazioni", "Spessore delle spiegazioni", "Opacità delle spiegazioni", "Spiegazioni del contesto culturale",
            "Pretendard", "Sistema", "Serif", "Monospazio", "Rigenera le spiegazioni culturali"
        ],
        "th": [
            "คำอธิบายบริบททางวัฒนธรรม",
            "แสดงคำอธิบาย AI เฉพาะใต้บรรทัดที่บริบททางวัฒนธรรมอาจสูญหายในการแปล ใช้ภาษาเป้าหมาย แสดงในหน้าปกติ เต็มจอ และโหมด LP แต่ไม่แสดงในกำลังเล่นหรือ PIP",
            "แบบอักษรคำอธิบาย", "ขนาดตัวอักษรคำอธิบาย", "น้ำหนักตัวอักษรคำอธิบาย", "ความทึบของคำอธิบาย", "คำอธิบายบริบททางวัฒนธรรม",
            "Pretendard", "ระบบ", "มีเชิง", "ความกว้างคงที่", "สร้างคำอธิบายวัฒนธรรมใหม่"
        ],
        "vi": [
            "Giải thích bối cảnh văn hóa",
            "Chỉ hiển thị giải thích AI dưới những câu có bối cảnh văn hóa dễ bị mất khi dịch. Dùng ngôn ngữ đích. Hiển thị ở trang lời thường, toàn màn hình và chế độ LP, nhưng không hiển thị trong Đang phát hoặc PIP.",
            "Phông chữ giải thích", "Cỡ chữ giải thích", "Độ đậm chữ giải thích", "Độ mờ giải thích", "Giải thích bối cảnh văn hóa",
            "Pretendard", "Hệ thống", "Có chân", "Đơn cách", "Tạo lại giải thích văn hóa"
        ],
        "id": [
            "Penjelasan konteks budaya",
            "Menampilkan penjelasan AI hanya di bawah baris yang konteks budayanya akan hilang dalam terjemahan. Menggunakan bahasa target. Tampil di halaman biasa, layar penuh, dan mode LP, tetapi bukan di Sedang Diputar atau PIP.",
            "Font penjelasan", "Ukuran font penjelasan", "Ketebalan font penjelasan", "Opasitas penjelasan", "Penjelasan konteks budaya",
            "Pretendard", "Sistem", "Serif", "Monospace", "Buat ulang penjelasan budaya"
        ],
        "ms": [
            "Penjelasan konteks budaya",
            "Memaparkan penjelasan AI hanya di bawah baris yang konteks budayanya akan hilang dalam terjemahan. Menggunakan bahasa sasaran. Dipaparkan pada halaman biasa, skrin penuh dan mod LP, tetapi bukan dalam Sedang Dimainkan atau PIP.",
            "Fon penjelasan", "Saiz fon penjelasan", "Ketebalan fon penjelasan", "Kelegapan penjelasan", "Penjelasan konteks budaya",
            "Pretendard", "Sistem", "Serif", "Monospace", "Jana semula penjelasan budaya"
        ],
        "tr": [
            "Kültürel bağlam açıklamaları",
            "Yalnızca kültürel arka planı çeviride kaybolabilecek satırların altında yapay zekâ açıklamaları gösterir. Hedef dili kullanır. Normal sayfa, tam ekran ve LP modunda gösterilir; Şu An Çalıyor veya PIP'te gösterilmez.",
            "Açıklama yazı tipi", "Açıklama yazı boyutu", "Açıklama yazı kalınlığı", "Açıklama opaklığı", "Kültürel bağlam açıklamaları",
            "Pretendard", "Sistem", "Serif", "Eş aralıklı", "Kültürel açıklamaları yeniden oluştur"
        ]
    ]

    static func value(language: String, key: String) -> String? {
        guard let keyIndex = keys.firstIndex(of: key) else { return nil }
        let languageValues = values[language] ?? values["en"]
        guard let languageValues, languageValues.indices.contains(keyIndex) else { return nil }
        return languageValues[keyIndex]
    }
}
