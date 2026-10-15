#!/usr/bin/env python3
"""Explicit onboarding/prompt translations; merge without changing unrelated strings."""
import json
from pathlib import Path

KEYS = [
    "onboarding.display.title", "onboarding.display.desc",
    "onboarding.connection.title", "onboarding.connection.desc",
    "onboarding.connection.standard", "onboarding.connection.web_api",
    "onboarding.credentials.title", "onboarding.credentials.desc", "onboarding.retry",
    "first_language.title_format", "first_language.hint", "first_language.not_now", "first_language.apply",
    "first_language.translation_provider_required", "first_language.pronunciation_ai_provider_hint",
]
TRANSLATIONS = {
    "ko": [
        "나에게 맞게 설정", "앱 언어와 화면을 먼저 골라주세요. 나중에 설정에서 바꿀 수 있어요.",
        "Spotify 재생 연결", "Spotify에서 재생 중인 곡에 맞춰 가사를 표시해요. 다음 단계에서 Client ID를 입력합니다.",
        "Spotify 앱에 연결해 현재 곡을 따라가요.", "선택 사항이에요. 다음 곡을 미리 준비하고 웹 재생 정보를 보조로 사용해요. Spotify 웹 로그인이 필요합니다.",
        "연결하고 시작하기", "Client ID는 필수예요. 저장 후 Spotify에서 연결을 승인해 주세요.", "다시 시도",
        "%@ 가사 표시", "이 언어의 곡에 적용해요. 곡 제목을 길게 눌러 바꿀 수 있어요.", "나중에", "적용",
        "번역을 생성하려면 설정에서 번역 제공자를 켜주세요.", "발음을 생성하려면 설정에서 AI 제공자를 준비해 주세요.",
    ],
    "en": [
        "Make it yours", "Choose the app language and appearance. You can change them later in Settings.",
        "Connect playback", "Lyrics follow the song playing in Spotify. Add your Client ID in the next step.",
        "Connect through the Spotify app to follow the current song.", "Optional: prepare the next song and use web playback as a fallback. Requires Spotify web sign-in.",
        "Connect and start", "A Client ID is required. After saving, approve the connection in Spotify.", "Try again",
        "%@ lyrics", "Your choice applies to this language. Long-press the song title to change it.", "Not now", "Apply",
        "Enable a translation provider in Settings to generate translations.", "Set up an AI provider in Settings to generate pronunciation.",
    ],
    "zh-CN": [
        "按你的喜好设置", "先选择应用语言和外观，之后可随时在设置中更改。",
        "连接播放", "歌词会跟随 Spotify 当前播放的歌曲。下一步请输入 Client ID。",
        "通过 Spotify 应用连接，跟随当前歌曲。", "可选：提前准备下一首歌曲，并将网页播放信息用作备用。需要登录 Spotify 网页版。",
        "连接并开始", "必须填写 Client ID。保存后，请在 Spotify 中批准连接。", "重试",
        "%@歌词", "此选择适用于该语言的歌曲。长按歌曲标题即可更改。", "暂不设置", "应用",
        "请在设置中启用翻译提供商以生成翻译。", "请在设置中配置 AI 提供商以生成发音。",
    ],
    "zh-TW": [
        "依你的喜好設定", "先選擇 App 語言和外觀，之後可隨時在設定中更改。",
        "連接播放", "歌詞會跟隨 Spotify 目前播放的歌曲。下一步請輸入 Client ID。",
        "透過 Spotify App 連線，跟隨目前歌曲。", "選用：預先準備下一首歌曲，並將網頁播放資訊作為備援。需要登入 Spotify 網頁版。",
        "連接並開始", "必須填寫 Client ID。儲存後，請在 Spotify 中允許連線。", "再試一次",
        "%@歌詞", "此選擇適用於該語言的歌曲。長按歌曲標題即可更改。", "稍後再說", "套用",
        "請在設定中啟用翻譯供應商以產生翻譯。", "請在設定中配置 AI 供應商以產生發音。",
    ],
    "ja": [
        "自分に合った設定に", "アプリの言語と外観を選びましょう。あとで設定から変更できます。",
        "再生を接続", "Spotify で再生中の曲に合わせて歌詞を表示します。次の手順で Client ID を入力します。",
        "Spotify アプリに接続して、再生中の曲を取得します。", "任意：次の曲を事前に準備し、Web の再生情報を補助に使います。Spotify の Web ログインが必要です。",
        "接続して始める", "Client ID は必須です。保存後、Spotify で接続を許可してください。", "再試行",
        "%@の歌詞", "この言語の曲に適用します。曲名を長押しすると変更できます。", "あとで", "適用",
        "翻訳を生成するには、設定で翻訳プロバイダーを有効にしてください。", "発音を生成するには、設定で AI プロバイダーを準備してください。",
    ],
    "hi": [
        "अपनी पसंद से सेट करें", "ऐप की भाषा और रूप चुनें। इन्हें बाद में सेटिंग्स में बदल सकते हैं।",
        "प्लेबैक कनेक्ट करें", "गीत के बोल Spotify में चल रहे गाने के साथ दिखेंगे। अगले चरण में अपना Client ID डालें।",
        "मौजूदा गाने की जानकारी पाने के लिए Spotify ऐप से कनेक्ट करें।", "वैकल्पिक: अगले गाने की तैयारी करें और वेब प्लेबैक को वैकल्पिक स्रोत बनाएँ। Spotify वेब साइन-इन ज़रूरी है।",
        "कनेक्ट करें और शुरू करें", "Client ID ज़रूरी है। सहेजने के बाद Spotify में कनेक्शन की अनुमति दें।", "फिर कोशिश करें",
        "%@ के बोल", "आपका चुनाव इस भाषा पर लागू होगा। बदलने के लिए गाने का शीर्षक देर तक दबाएँ।", "अभी नहीं", "लागू करें",
        "अनुवाद बनाने के लिए सेटिंग्स में अनुवाद प्रदाता चालू करें।", "उच्चारण बनाने के लिए सेटिंग्स में AI प्रदाता तैयार करें।",
    ],
    "es": [
        "A tu gusto", "Elige el idioma y la apariencia. Puedes cambiarlos después en Ajustes.",
        "Conecta la reproducción", "Las letras siguen la canción que suena en Spotify. Introduce tu Client ID en el siguiente paso.",
        "Conecta la app de Spotify para seguir la canción actual.", "Opcional: prepara la siguiente canción y usa la reproducción web como alternativa. Requiere iniciar sesión en Spotify web.",
        "Conecta y empieza", "El Client ID es obligatorio. Tras guardar, autoriza la conexión en Spotify.", "Reintentar",
        "Letras en %@", "Tu elección se aplica a este idioma. Mantén pulsado el título de la canción para cambiarla.", "Ahora no", "Aplicar",
        "Activa un proveedor de traducción en Ajustes para generar traducciones.", "Configura un proveedor de IA en Ajustes para generar la pronunciación.",
    ],
    "fr": [
        "À votre image", "Choisissez la langue et l’apparence de l’app. Vous pourrez les modifier dans les réglages.",
        "Connecter la lecture", "Les paroles suivent le titre en cours sur Spotify. Saisissez votre Client ID à l’étape suivante.",
        "Connectez l’app Spotify pour suivre le titre en cours.", "Facultatif : prépare le titre suivant et utilise la lecture web en secours. Nécessite une connexion à Spotify sur le web.",
        "Connecter et démarrer", "Le Client ID est requis. Après l’enregistrement, autorisez la connexion dans Spotify.", "Réessayer",
        "Paroles en %@", "Votre choix s’applique à cette langue. Un appui long sur le titre permet de le modifier.", "Plus tard", "Appliquer",
        "Activez un fournisseur de traduction dans les réglages pour générer des traductions.", "Configurez un fournisseur d’IA dans les réglages pour générer la prononciation.",
    ],
    "ar": [
        "إعداد يناسبك", "اختر لغة التطبيق ومظهره. يمكنك تغييرهما لاحقًا في الإعدادات.",
        "توصيل التشغيل", "تتبع الكلمات الأغنية التي تعمل في Spotify. أدخل Client ID في الخطوة التالية.",
        "اتصل عبر تطبيق Spotify لمتابعة الأغنية الحالية.", "اختياري: جهّز الأغنية التالية واستخدم تشغيل الويب كمسار بديل. يتطلب تسجيل الدخول إلى Spotify عبر الويب.",
        "اتصل وابدأ", "Client ID مطلوب. بعد الحفظ، وافق على الاتصال في Spotify.", "إعادة المحاولة",
        "كلمات باللغة %@", "يُطبّق اختيارك على هذه اللغة. اضغط مطولًا على عنوان الأغنية لتغييره.", "ليس الآن", "تطبيق",
        "فعّل مزوّد ترجمة في الإعدادات لإنشاء الترجمات.", "أعدّ مزوّد ذكاء اصطناعي في الإعدادات لإنشاء النطق.",
    ],
    "fa": [
        "مطابق سلیقهٔ شما", "زبان و ظاهر برنامه را انتخاب کنید. بعداً می‌توانید آن‌ها را در تنظیمات تغییر دهید.",
        "اتصال پخش", "متن ترانه با آهنگ در حال پخش در Spotify همراه می‌شود. در مرحلهٔ بعد Client ID را وارد کنید.",
        "از طریق برنامهٔ Spotify متصل شوید تا آهنگ فعلی دنبال شود.", "اختیاری: آهنگ بعدی را آماده کنید و از پخش وب به‌عنوان مسیر جایگزین استفاده کنید. ورود به Spotify در وب لازم است.",
        "اتصال و شروع", "Client ID الزامی است. پس از ذخیره، اتصال را در Spotify تأیید کنید.", "تلاش دوباره",
        "متن ترانه به %@", "انتخاب شما برای این زبان اعمال می‌شود. برای تغییر، عنوان آهنگ را نگه دارید.", "فعلاً نه", "اعمال",
        "برای تولید ترجمه، یک ارائه‌دهندهٔ ترجمه را در تنظیمات فعال کنید.", "برای تولید تلفظ، یک ارائه‌دهندهٔ هوش مصنوعی را در تنظیمات آماده کنید.",
    ],
    "de": [
        "Nach deinem Geschmack", "Wähle Sprache und Design der App. Beides lässt sich später in den Einstellungen ändern.",
        "Wiedergabe verbinden", "Die Liedtexte folgen dem aktuellen Spotify-Song. Gib im nächsten Schritt deine Client ID ein.",
        "Verbinde die Spotify-App, um dem aktuellen Song zu folgen.", "Optional: Bereite den nächsten Song vor und nutze die Web-Wiedergabe als Ersatz. Erfordert eine Spotify-Anmeldung im Web.",
        "Verbinden und starten", "Eine Client ID ist erforderlich. Bestätige nach dem Speichern die Verbindung in Spotify.", "Erneut versuchen",
        "Liedtexte auf %@", "Deine Auswahl gilt für diese Sprache. Halte den Songtitel gedrückt, um sie zu ändern.", "Später", "Anwenden",
        "Aktiviere in den Einstellungen einen Übersetzungsanbieter, um Übersetzungen zu erzeugen.", "Richte in den Einstellungen einen KI-Anbieter ein, um die Aussprache zu erzeugen.",
    ],
    "ru": [
        "Настройте под себя", "Выберите язык и оформление приложения. Позже их можно изменить в настройках.",
        "Подключение воспроизведения", "Текст следует за песней, играющей в Spotify. На следующем шаге введите Client ID.",
        "Подключите приложение Spotify, чтобы получать текущую песню.", "Необязательно: заранее готовить следующую песню и использовать веб-воспроизведение как резерв. Нужен вход в Spotify через браузер.",
        "Подключить и начать", "Client ID обязателен. После сохранения разрешите подключение в Spotify.", "Повторить",
        "Текст на языке: %@", "Выбор применяется к этому языку. Чтобы изменить его, удерживайте название песни.", "Не сейчас", "Применить",
        "Включите поставщика перевода в настройках для создания переводов.", "Настройте поставщика ИИ для создания произношения.",
    ],
    "sv": [
        "Gör den till din", "Välj appens språk och utseende. Du kan ändra dem senare i inställningarna.",
        "Anslut uppspelningen", "Låttexten följer låten som spelas i Spotify. Ange ditt Client ID i nästa steg.",
        "Anslut via Spotify-appen för att följa den aktuella låten.", "Valfritt: förbered nästa låt och använd webbuppspelning som reserv. Kräver inloggning på Spotify på webben.",
        "Anslut och börja", "Ett Client ID krävs. Godkänn anslutningen i Spotify när du har sparat.", "Försök igen",
        "Låttext på %@", "Ditt val gäller det här språket. Håll låttiteln intryckt för att ändra det.", "Inte nu", "Använd",
        "Aktivera en översättningsleverantör i inställningarna för att skapa översättningar.", "Konfigurera en AI-leverantör i inställningarna för att skapa uttal.",
    ],
    "pt": [
        "Ao seu gosto", "Escolha o idioma e a aparência do app. Você pode alterá-los depois nas configurações.",
        "Conectar a reprodução", "As letras acompanham a música tocando no Spotify. Insira seu Client ID na próxima etapa.",
        "Conecte pelo app Spotify para acompanhar a música atual.", "Opcional: prepare a próxima música e use a reprodução web como alternativa. Requer login no Spotify pela web.",
        "Conectar e começar", "O Client ID é obrigatório. Após salvar, autorize a conexão no Spotify.", "Tentar novamente",
        "Letras em %@", "Sua escolha vale para este idioma. Mantenha o título da música pressionado para alterar.", "Agora não", "Aplicar",
        "Ative um provedor de tradução nas configurações para gerar traduções.", "Configure um provedor de IA nas configurações para gerar a pronúncia.",
    ],
    "bn": [
        "নিজের মতো সাজান", "অ্যাপের ভাষা ও চেহারা বেছে নিন। পরে সেটিংসে এগুলো বদলাতে পারবেন।",
        "প্লেব্যাক সংযুক্ত করুন", "Spotify-তে চলা গানের সঙ্গে গানের কথা দেখাবে। পরের ধাপে আপনার Client ID লিখুন।",
        "বর্তমান গান অনুসরণ করতে Spotify অ্যাপের মাধ্যমে সংযুক্ত করুন।", "ঐচ্ছিক: পরের গান প্রস্তুত করুন এবং বিকল্প হিসেবে ওয়েব প্লেব্যাক ব্যবহার করুন। Spotify ওয়েবে সাইন-ইন করতে হবে।",
        "সংযুক্ত করে শুরু করুন", "Client ID আবশ্যক। সেভ করার পরে Spotify-তে সংযোগের অনুমতি দিন।", "আবার চেষ্টা করুন",
        "%@ ভাষার গানের কথা", "আপনার পছন্দ এই ভাষার জন্য প্রযোজ্য হবে। বদলাতে গানের শিরোনাম চেপে ধরে রাখুন।", "এখন নয়", "প্রয়োগ করুন",
        "অনুবাদ তৈরি করতে সেটিংসে অনুবাদ প্রদানকারী চালু করুন।", "উচ্চারণ তৈরি করতে সেটিংসে AI প্রদানকারী প্রস্তুত করুন।",
    ],
    "cs": [
        "Podle vašich představ", "Vyberte jazyk a vzhled aplikace. Později je můžete změnit v nastavení.",
        "Připojit přehrávání", "Text sleduje skladbu přehrávanou ve Spotify. V dalším kroku zadejte Client ID.",
        "Připojte aplikaci Spotify a sledujte aktuální skladbu.", "Volitelné: připraví další skladbu a použije webové přehrávání jako zálohu. Vyžaduje přihlášení ke Spotify na webu.",
        "Připojit a začít", "Client ID je povinné. Po uložení povolte připojení ve Spotify.", "Zkusit znovu",
        "Text v jazyce %@", "Volba platí pro tento jazyk. Změníte ji podržením názvu skladby.", "Teď ne", "Použít",
        "Pro vytváření překladů zapněte v nastavení poskytovatele překladu.", "Pro vytváření výslovnosti nastavte poskytovatele AI.",
    ],
    "it": [
        "Come piace a te", "Scegli la lingua e l’aspetto dell’app. Potrai cambiarli nelle impostazioni.",
        "Collega la riproduzione", "I testi seguono il brano in riproduzione su Spotify. Inserisci il Client ID nel passaggio successivo.",
        "Collegati tramite l’app Spotify per seguire il brano attuale.", "Facoltativo: prepara il brano successivo e usa la riproduzione web come alternativa. Richiede l’accesso a Spotify sul web.",
        "Collega e inizia", "Il Client ID è obbligatorio. Dopo il salvataggio, autorizza il collegamento in Spotify.", "Riprova",
        "Testi in %@", "La scelta vale per questa lingua. Tieni premuto il titolo del brano per cambiarla.", "Non ora", "Applica",
        "Attiva un fornitore di traduzione nelle impostazioni per generare traduzioni.", "Configura un fornitore IA nelle impostazioni per generare la pronuncia.",
    ],
    "th": [
        "ตั้งค่าในแบบของคุณ", "เลือกภาษาและรูปลักษณ์ของแอป คุณเปลี่ยนได้ภายหลังในการตั้งค่า",
        "เชื่อมต่อการเล่น", "เนื้อเพลงจะตามเพลงที่กำลังเล่นใน Spotify กรอก Client ID ในขั้นตอนถัดไป",
        "เชื่อมต่อผ่านแอป Spotify เพื่อติดตามเพลงปัจจุบัน", "ไม่บังคับ: เตรียมเพลงถัดไปและใช้ข้อมูลการเล่นบนเว็บเป็นทางสำรอง ต้องลงชื่อเข้าใช้ Spotify บนเว็บ",
        "เชื่อมต่อและเริ่มต้น", "จำเป็นต้องมี Client ID หลังบันทึก ให้อนุญาตการเชื่อมต่อใน Spotify", "ลองอีกครั้ง",
        "เนื้อเพลงภาษา%@", "ตัวเลือกนี้ใช้กับเพลงภาษานี้ กดชื่อเพลงค้างไว้เพื่อเปลี่ยน", "ไว้ทีหลัง", "ใช้",
        "เปิดใช้ผู้ให้บริการแปลในการตั้งค่าเพื่อสร้างคำแปล", "ตั้งค่าผู้ให้บริการ AI ในการตั้งค่าเพื่อสร้างคำอ่าน",
    ],
    "vi": [
        "Thiết lập theo ý bạn", "Chọn ngôn ngữ và giao diện ứng dụng. Bạn có thể đổi sau trong Cài đặt.",
        "Kết nối phát nhạc", "Lời bài hát theo bài đang phát trên Spotify. Nhập Client ID ở bước tiếp theo.",
        "Kết nối qua ứng dụng Spotify để theo dõi bài hát hiện tại.", "Không bắt buộc: chuẩn bị bài tiếp theo và dùng phát nhạc web làm dự phòng. Cần đăng nhập Spotify trên web.",
        "Kết nối và bắt đầu", "Bắt buộc có Client ID. Sau khi lưu, hãy cho phép kết nối trong Spotify.", "Thử lại",
        "Lời bài hát bằng %@", "Lựa chọn áp dụng cho ngôn ngữ này. Nhấn giữ tên bài hát để thay đổi.", "Để sau", "Áp dụng",
        "Bật nhà cung cấp dịch trong Cài đặt để tạo bản dịch.", "Thiết lập nhà cung cấp AI trong Cài đặt để tạo phiên âm.",
    ],
    "id": [
        "Atur sesuai selera", "Pilih bahasa dan tampilan aplikasi. Anda bisa mengubahnya nanti di Pengaturan.",
        "Hubungkan pemutaran", "Lirik mengikuti lagu yang diputar di Spotify. Masukkan Client ID pada langkah berikutnya.",
        "Hubungkan melalui aplikasi Spotify untuk mengikuti lagu saat ini.", "Opsional: siapkan lagu berikutnya dan gunakan pemutaran web sebagai cadangan. Memerlukan login Spotify di web.",
        "Hubungkan dan mulai", "Client ID wajib diisi. Setelah menyimpan, izinkan koneksi di Spotify.", "Coba lagi",
        "Lirik bahasa %@", "Pilihan berlaku untuk bahasa ini. Tekan lama judul lagu untuk mengubahnya.", "Nanti saja", "Terapkan",
        "Aktifkan penyedia terjemahan di Pengaturan untuk membuat terjemahan.", "Siapkan penyedia AI di Pengaturan untuk membuat pelafalan.",
    ],
    "ms": [
        "Tetapkan mengikut cita rasa", "Pilih bahasa dan rupa aplikasi. Anda boleh mengubahnya kemudian dalam Tetapan.",
        "Sambungkan main balik", "Lirik mengikuti lagu yang dimainkan dalam Spotify. Masukkan Client ID pada langkah seterusnya.",
        "Sambung melalui aplikasi Spotify untuk mengikuti lagu semasa.", "Pilihan: sediakan lagu seterusnya dan gunakan main balik web sebagai sandaran. Memerlukan log masuk Spotify di web.",
        "Sambung dan mula", "Client ID diperlukan. Selepas menyimpan, benarkan sambungan dalam Spotify.", "Cuba lagi",
        "Lirik bahasa %@", "Pilihan ini terpakai untuk bahasa ini. Tekan lama tajuk lagu untuk mengubahnya.", "Bukan sekarang", "Gunakan",
        "Aktifkan penyedia terjemahan dalam Tetapan untuk menjana terjemahan.", "Sediakan penyedia AI dalam Tetapan untuk menjana sebutan.",
    ],
    "tr": [
        "Kendinize göre ayarlayın", "Uygulama dilini ve görünümünü seçin. Bunları daha sonra Ayarlar’dan değiştirebilirsiniz.",
        "Çalmayı bağlayın", "Şarkı sözleri Spotify’da çalan şarkıyı izler. Sonraki adımda Client ID’nizi girin.",
        "Geçerli şarkıyı izlemek için Spotify uygulaması üzerinden bağlanın.", "İsteğe bağlı: sonraki şarkıyı hazırlar ve web oynatmayı yedek olarak kullanır. Spotify web oturumu açmanız gerekir.",
        "Bağlanın ve başlayın", "Client ID gereklidir. Kaydettikten sonra Spotify’da bağlantıya izin verin.", "Yeniden dene",
        "%@ şarkı sözleri", "Seçiminiz bu dil için geçerlidir. Değiştirmek için şarkı adına basılı tutun.", "Şimdi değil", "Uygula",
        "Çeviri oluşturmak için Ayarlar’da bir çeviri sağlayıcısını etkinleştirin.", "Telaffuz oluşturmak için Ayarlar’da bir yapay zekâ sağlayıcısı kurun.",
    ],
}

MESSAGES = {
    "ko": "이 언어의 곡에 표시할 내용을 골라주세요.",
    "en": "Choose what to show for songs in this language.",
    "zh-CN": "选择要为这种语言的歌曲显示的内容。",
    "zh-TW": "選擇要為這種語言的歌曲顯示的內容。",
    "ja": "この言語の曲に表示する内容を選んでください。",
    "hi": "इस भाषा के गानों के लिए क्या दिखाना है, चुनें।",
    "es": "Elige qué mostrar para las canciones en este idioma.",
    "fr": "Choisissez quoi afficher pour les titres dans cette langue.",
    "ar": "اختر ما تريد عرضه لأغاني هذه اللغة.",
    "fa": "انتخاب کنید برای آهنگ‌های این زبان چه چیزی نمایش داده شود.",
    "de": "Wähle, was bei Songs in dieser Sprache angezeigt wird.",
    "ru": "Выберите, что показывать для песен на этом языке.",
    "sv": "Välj vad som ska visas för låtar på det här språket.",
    "pt": "Escolha o que mostrar nas músicas deste idioma.",
    "bn": "এই ভাষার গানের জন্য কী দেখাবেন তা বেছে নিন।",
    "cs": "Vyberte, co zobrazit u skladeb v tomto jazyce.",
    "it": "Scegli cosa mostrare per i brani in questa lingua.",
    "th": "เลือกสิ่งที่จะแสดงสำหรับเพลงภาษานี้",
    "vi": "Chọn nội dung hiển thị cho các bài hát bằng ngôn ngữ này.",
    "id": "Pilih yang ingin ditampilkan untuk lagu dalam bahasa ini.",
    "ms": "Pilih perkara yang hendak dipaparkan untuk lagu dalam bahasa ini.",
    "tr": "Bu dildeki şarkılar için ne gösterileceğini seçin.",
}

METADATA_TITLES = {
    "ko": "메타데이터 보강 (선택)", "en": "Metadata enrichment (optional)",
    "zh-CN": "元数据增强（可选）", "zh-TW": "中繼資料增強（選用）", "ja": "メタデータの補完（任意）",
    "hi": "मेटाडेटा संवर्धन (वैकल्पिक)", "es": "Ampliar metadatos (opcional)",
    "fr": "Enrichir les métadonnées (facultatif)", "ar": "إثراء البيانات الوصفية (اختياري)",
    "fa": "تکمیل فراداده (اختیاری)", "de": "Metadaten ergänzen (optional)",
    "ru": "Дополнение метаданных (необязательно)", "sv": "Utöka metadata (valfritt)",
    "pt": "Enriquecer metadados (opcional)", "bn": "মেটাডেটা সমৃদ্ধি (ঐচ্ছিক)",
    "cs": "Doplnit metadata (volitelné)", "it": "Arricchire i metadati (facoltativo)",
    "th": "เพิ่มข้อมูลเมตา (ไม่บังคับ)", "vi": "Bổ sung siêu dữ liệu (không bắt buộc)",
    "id": "Pelengkapan metadata (opsional)", "ms": "Pengayaan metadata (pilihan)",
    "tr": "Meta veri zenginleştirme (isteğe bağlı)",
}

if __name__ == "__main__":
    path = Path(__file__).resolve().parents[1] / "ivLyrics-IOS/Resources/AppI18nStrings.json"
    bundle = json.loads(path.read_text())
    assert set(bundle) == set(TRANSLATIONS) == set(MESSAGES) == set(METADATA_TITLES), "Every supported locale must be explicitly translated"
    for locale, values in TRANSLATIONS.items():
        assert len(values) == len(KEYS), locale
        bundle[locale].update(zip(KEYS, values))
        bundle[locale]["first_language.message"] = MESSAGES[locale]
        bundle[locale]["onboarding.metadata_optional"] = METADATA_TITLES[locale]
    path.write_text(json.dumps(bundle, ensure_ascii=False, indent=2) + "\n")
    print(f"Updated {len(KEYS) + 2} setup strings in {len(bundle)} locales")
