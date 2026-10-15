// Tropa presentation as an editable .pptx (13.33 x 7.5 in; 1 html px of the 1920x1080 slides = 1/144 in)
const pptxgen = require("pptxgenjs");
const path = require("path");

const IMG = path.join(__dirname, "img");
const OUT = process.argv[2] || path.join(__dirname, "Tropa.pptx");
const px = (v) => v / 144; // px -> inches
const HEAD = "Unbounded", BODY = "Rubik";

const pres = new pptxgen();
pres.layout = "LAYOUT_WIDE";
pres.title = "Tropa: трекер маршрутов";
pres.author = "Tropa";

// ---- helpers
function text(slide, t, x, y, w, h, o = {}) {
  slide.addText(t, Object.assign({
    x: px(x), y: px(y), w: px(w), h: px(h), isTextBox: true, margin: 0, valign: "top", fontFace: BODY, color: "0E2A22", fit: "none",
  }, o));
}
function eyebrow(slide, t, x, y, w, color) {
  text(slide, t.toUpperCase(), x, y, w, 40, { fontSize: 14, bold: true, color, charSpacing: 3 });
}
function title(slide, t, x, y, w, h, size, color) {
  text(slide, t, x, y, w, h, { fontFace: HEAD, fontSize: size, bold: true, color, lineSpacingMultiple: 1.05 });
}
// "Bold lead: rest" paragraphs
function bullets(slide, items, x, y, w, size, leadColor, color, gap) {
  const runs = [];
  items.forEach(([lead, rest], i) => {
    runs.push({ text: lead + " ", options: { bold: true, color: leadColor, breakLine: false } });
    runs.push({ text: rest, options: { color, breakLine: i < items.length - 1 } });
  });
  slide.addText(runs, {
    x: px(x), y: px(y), w: px(w), h: px(items.length * (size * 2 * 1.4 + gap) * 1), isTextBox: true, margin: 0, valign: "top",
    fontFace: BODY, fontSize: size, paraSpaceAfter: gap / 2, fit: "none",
  });
}
function phone(slide, key, x, y, w, rot, name) {
  const h = Math.round(w * 2.092);
  slide.addImage({ path: path.join(IMG, `phone_${key}.png`), x: px(x), y: px(y), w: px(w), h: px(h), rotate: rot || 0, altText: name, objectName: name });
}
function footer(slide, t, color) {
  text(slide, t, 128, 1016, 1400, 30, { fontSize: 12, color });
}
function bg(slide, color, img) {
  if (img) slide.background = { path: path.join(IMG, img) };
  else slide.background = { color };
}

// ============================================================ 1. cover
{
  const s = pres.addSlide();
  bg(s, null, "bg_cover.jpg");
  phone(s, "p2", 1030, 230, 384, -6, "Постер велопрогулки");
  phone(s, "home", 1350, 130, 384, 4, "Главный экран Tropa");
  s.addImage({ path: path.join(IMG, "logo_light.png"), x: px(128), y: px(215), w: px(760), h: px(234), altText: "Логотип Tropa", objectName: "Логотип" });
  title(s, "Трекер маршрутов, который работает без интернета", 128, 480, 880, 190, 25, "F6F1E3");
  text(s, "Проанализирует и запишет ваш маршрут, сохранит ваше достижение.", 128, 720, 800, 110, { fontSize: 15, color: "CFE3D8", lineSpacingMultiple: 1.2 });
  s.addNotes("Первый слайд объясняет суть и показывает результат: экран приложения и готовый постер.");
}

// ============================================================ 2. record
{
  const s = pres.addSlide();
  bg(s, "F6F1E3");
  phone(s, "record", 1380, 138, 384, 0, "Экран записи");
  eyebrow(s, "Запись", 128, 262, 1100, "B0432C");
  title(s, "Запишите свой маршрут: в прогулке или в путешествии", 128, 318, 1150, 150, 29, "0E2A22");
  bullets(s, [
    ["Без интернета:", "в горах, в джунглях, за границей"],
    ["Экран погас — запись идёт:", "телефон можно убрать в карман"],
    ["Заметки по дороге:", "подпись или фото привяжутся к месту"],
  ], 128, 540, 1150, 16, "0E4D3A", "2F3C38", 22);
  const chips = ["Пешком", "Велосипед", "Авто", "Сплав", "Смешанный"];
  let cx = 128;
  chips.forEach((c) => {
    const w = 60 + c.length * 17;
    s.addText(c, { x: px(cx), y: px(770), w: px(w), h: px(56), shape: pres.ShapeType.roundRect, rectRadius: 0.2, fill: { color: "0E4D3A" }, color: "F6F1E3", fontFace: BODY, fontSize: 13, bold: true, align: "center", valign: "middle", margin: 0, isTextBox: true });
    cx += w + 16;
  });
  footer(s, "Tropa · 02", "6B7A72");
  s.addNotes("Экран записи из реального приложения (значения на кадре подставлены правдоподобные: 42 минуты, 3,27 км). Режим выбирается значками на карточке записи; смешанный режим сам делит маршрут на пешие и транспортные участки.");
}

// ============================================================ 3. nav
{
  const s = pres.addSlide();
  bg(s, "0E4D3A");
  phone(s, "route", 1050, 190, 384, -4, "Экран маршрута");
  phone(s, "navscreen", 1370, 120, 384, 3, "Экран навигации");
  eyebrow(s, "Навигатор", 128, 232, 860, "9FD8C0");
  title(s, "Идите по скачанному маршруту, как по навигатору", 128, 288, 860, 190, 27, "F6F1E3");
  bullets(s, [
    ["Подскажет поворот:", "голосом и вибрацией, заранее"],
    ["Скажет, если сбились,", "и отметит, когда вернулись"],
    ["Карта без сети:", "скачайте район заранее"],
    ["Ждать у старта:", "запись начнётся, когда вы дойдёте до начала"],
  ], 128, 520, 860, 15, "F6F1E3", "CFE3D8", 20);
  footer(s, "Tropa · 03 · Данные карты © OpenStreetMap", "9FD8C0");
  s.addNotes("Слева экран маршрута, справа экран навигации во время движения. Экран навигации ещё дорабатывается. Навигатор проверен на эмуляторе; на реальной прогулке ещё в тестировании.");
}

// ============================================================ 4. auto
{
  const s = pres.addSlide();
  bg(s, "C8553D");
  phone(s, "auto", 1050, 190, 384, -4, "Экран «Автозапись»");
  phone(s, "planner", 1370, 120, 384, 3, "Окно «Новая прогулка»");
  eyebrow(s, "Работает за вас", 128, 262, 860, "FFE3D2");
  title(s, "А если приключение начнётся в любую минуту?", 128, 318, 860, 190, 27, "FFF8EC");
  bullets(s, [
    ["Автозапись:", "включите её в приложении, и Tropa сама начнёт запись трека, когда вы начнёте движение."],
    ["Планировщик:", "выберите дату, время и способ передвижения, и запись начнётся в нужный момент."],
  ], 128, 560, 860, 15, "FFF8EC", "FFE9DC", 26);
  footer(s, "Tropa · 04", "FFE3D2");
  s.addNotes("Слева экран «Автозапись» с проверкой готовности телефона, справа окно «Новая прогулка» из планировщика.");
}

// ============================================================ 5. share
{
  const s = pres.addSlide();
  bg(s, "F6F1E3");
  phone(s, "poster", 1380, 138, 384, 0, "Экран постера");
  eyebrow(s, "Делитесь", 128, 262, 1100, "B0432C");
  title(s, "Делитесь своим маршрутом или постером пройденного пути", 128, 318, 1150, 215, 29, "0E2A22");
  bullets(s, [
    ["Маршрутом:", "файлом GPX, он откроется в любом навигаторе"],
    ["Постером:", "ваш путь на карте, цифры, погода и заметки"],
    ["Картой:", "снимок с вашей тропой"],
  ], 128, 575, 1150, 16, "0E4D3A", "2F3C38", 22);
  footer(s, "Tropa · 05", "6B7A72");
  s.addNotes("Экран постера из приложения: кнопки «Сохранить постер» и «Поделиться постером». В превью подставлен постер велопрогулки.");
}

// ============================================================ 6. trio
{
  const s = pres.addSlide();
  bg(s, "08211F");
  eyebrow(s, "Постеры", 128, 96, 1000, "9FD8C0");
  title(s, "Ваша прогулка — одной картинкой", 128, 140, 1664, 90, 26, "F6F1E3");
  const W = 311;
  [[293, "p1", "Поход в горы", "цвет линии — высота"], [804, "p2", "Велопрогулка", "цвет линии — скорость"], [1315, "p3", "Дорога и сплав", "два способа в одном маршруте"]].forEach(([x, k, t1, t2]) => {
    phone(s, k, x, 250, W, 0, t1);
    text(s, t1, x - 50, 930, 411, 50, { fontSize: 16, bold: true, color: "F6F1E3", align: "center" });
    text(s, t2, x - 50, 982, 411, 40, { fontSize: 13, color: "CFE3D8", align: "center" });
  });
  s.addNotes("Три постера из трёх регионов: Хан-Муа (Вьетнам, реальная запись), Урал (велосипед) и Горный Алтай (машина и сплав). Маршруты на Урале и Алтае проложены по реальным дорогам и рекам, скорость и остановки смоделированы; фото ваши.");
}

// ============================================================ 7. pro
{
  const s = pres.addSlide();
  bg(s, "08211F");
  eyebrow(s, "Для экрана и для печати", 128, 96, 1000, "9FD8C0");
  title(s, "Весь маршрут на одном листе", 128, 140, 1664, 90, 26, "F6F1E3");
  s.addImage({ path: path.join(IMG, "wide_pro.jpg"), x: px(128), y: px(300), w: px(808), h: px(539), altText: "Профи-карта", objectName: "Профи-карта" });
  s.addImage({ path: path.join(IMG, "wide_week.jpg"), x: px(984), y: px(300), w: px(808), h: px(539), altText: "Неделя приключений", objectName: "Неделя" });
  text(s, "Профи-карта", 128, 866, 808, 50, { fontSize: 16, bold: true, color: "F6F1E3" });
  text(s, "Карта, профиль высоты, погода и заметки.", 128, 920, 808, 50, { fontSize: 13, color: "CFE3D8" });
  text(s, "Неделя приключений", 984, 866, 808, 50, { fontSize: 16, bold: true, color: "F6F1E3" });
  text(s, "Пять прогулок на одной карте, каждая в своём цвете.", 984, 920, 808, 50, { fontSize: 13, color: "CFE3D8" });
  s.addNotes("Горизонтальная раскладка доступна в режиме «Профи». Неделя: пять демо-велопрогулок по реальным дорогам одного района (Урал), 228 км в сумме.");
}

// ============================================================ 8. finale
{
  const s = pres.addSlide();
  bg(s, null, "bg_finale.jpg");
  text(s, "Путешествуй, сохраняй, делись!", 128, 330, 1664, 110, { fontFace: HEAD, fontSize: 32, bold: true, color: "F6F1E3", align: "center" });
  s.addImage({ path: path.join(IMG, "logo_light.png"), x: px(700), y: px(500), w: px(520), h: px(160), altText: "Логотип Tropa", objectName: "Логотип" });
  text(s, "Трекер маршрутов, который работает без интернета.", 360, 720, 1200, 60, { fontSize: 17, color: "CFE3D8", align: "center" });
  s.addNotes("Финал и главный лозунг. Полный логотип, как на обложке, в меньшем масштабе.");
}
// centre the two finale texts
pres.writeFile({ fileName: OUT }).then(() => console.log("written", OUT));
