// Copy and per-device slide order for the App Store screenshots.
export const SONGS = {
  en: {
    art: 'covers/starlit-night.png', focus: '50% 70%', base: '#060a12', brightness: '.62',
    tint: 'linear-gradient(180deg,rgba(6,16,30,.35),rgba(8,10,24,.55))', accent: '#FFB86B',
  },
  ko: {
    art: 'covers/yoake-melody.png', focus: '60% 40%', base: '#140a14', brightness: '.5',
    tint: 'linear-gradient(180deg,rgba(40,12,40,.45),rgba(22,10,30,.62))', accent: '#FFB3A1',
  },
};

// [word] = accent color, {word} = karaoke fill halfway through.
export const COPY = {
  en: {
    lyrics: { kicker: 'Karaoke lyrics', title: 'Every word, right on {time.}', sub: 'Word-by-word timing for the song you\u2019re playing.' },
    pronfirst: { kicker: 'New \u00b7 Pronunciation first', title: 'Sing it, even if you [can\u2019t read it.]', sub: 'Pronunciation takes the lead line and fills in time with the music.' },
    pip: { kicker: 'Picture in Picture', title: 'Lyrics that float over [any app.]', sub: 'The current line stays on screen while you do other things.' },
    vinyl: { kicker: 'LP mode', title: 'Spin the cover like a [record.]', sub: 'A turntable view with the lyric line underneath.' },
    menu: { kicker: 'Translation', title: 'Know what you\u2019re [singing.]', sub: 'Translation and pronunciation under every line, in your language.' },
    player: { kicker: 'Now playing', title: 'Your song, [at a glance.]', sub: 'Artwork, controls and a live lyric preview.' },
  },
  ko: {
    lyrics: { kicker: '노래방 가사', title: '한 글자씩, 노래에 {맞춰}', sub: '재생 중인 곡의 가사가 단어 단위로 따라와요.' },
    pronfirst: { kicker: '새 기능 \u00b7 발음 우선', title: '못 읽어도 [따라 부르게]', sub: '발음을 원문 자리에 띄우고, 박자에 맞춰 채워요.' },
    pip: { kicker: 'PiP', title: '다른 앱 위에도 [가사를]', sub: '다른 앱을 쓰는 동안에도 지금 부르는 줄이 떠 있어요.' },
    vinyl: { kicker: 'LP 모드', title: '앨범 커버를 [레코드처럼]', sub: '커버가 돌아가는 턴테이블 화면에 가사까지.' },
    menu: { kicker: '번역 \u00b7 발음', title: '무슨 뜻인지 [바로 알게]', sub: '줄마다 번역과 발음을, 원하는 언어로 보여 줘요.' },
    player: { kicker: '재생 화면', title: '지금 듣는 곡을 [한눈에]', sub: '앨범아트와 재생 버튼, 실시간 가사 미리보기까지.' },
  },
};

const FULL = [
  { id: 'lyrics', shot: 'lyrics' },
  { id: 'pronfirst', shot: 'pronfirst' },
  { id: 'pip', shot: 'home', pip: true },
  { id: 'vinyl', shot: 'vinyl' },
  { id: 'player', shot: 'player' },
  { id: 'menu', shot: 'menu' },
];

export const SLIDES = {
  iphone: FULL,
  // Landscape iPad shows the player and lyrics side by side, so a separate player slide repeats the first.
  // The language menu is a phone-sized panel on a 13-inch screen; zoom the frame onto it.
  ipad: FULL.filter((slide) => slide.id !== 'player')
    .map((slide) => (slide.id === 'menu' ? { ...slide, zoom: { x: 0.49, y: 0.41, scale: 1.55 } } : slide)),
  duo: [
    { id: 'lyrics', shot: 'lyrics' },
    { id: 'pronfirst', shot: 'pronfirst' },
    { id: 'vinyl', shot: 'vinyl' },
    { id: 'pip', shot: 'home', pip: true },
  ],
};

