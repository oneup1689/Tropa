import os

OUT = r"C:\Users\Nikita\AppData\Local\Temp\claude\C--Users-Nikita-Desktop-Coder-Projects-Tropa\c81c2703-d0a3-47ff-8ba3-ce716e1cffa2\scratchpad\deck\project\slides"
IMG = {
    "home": "2df8e1ed1f0b7aa218a648762472fd48", "record": "71b315bd9325bd45e8c15a3678413186", "route": "b8b193727da15a5fc2471537327c75fa",
    "nav": "1d2e37211ea10624cec0cab7e1164cb9", "auto": "39f0ec08ff0677be890e92fe28396c8c", "planner": "f4b710bc2449b5c761c611fc5e666542",
    "poster": "712db5545056f8ec56521b81a4b1428f", "p1": "ff7b80f906ccbfd006558b12aef71ba6", "p2": "3ea37282ace8d0de5d136066259cf32d",
    "p3": "56e7b23e6ccdb4676b6f75c60e9fe570",
}


def phone(key, alt, x, y, w=384, rot=0, shadow="0px 20px 56px rgba(0,0,0,0.5)"):
    """iPhone Pro proportions (71.5 x 149.6 mm): titanium rim, thin black bezel, screen ratio ~2.16."""
    h = round(w * 2.092)
    s = w / 384.0
    rim = max(2, round(3 * s))
    bez = round(9 * s)
    iw, ih = w - 2 * rim - 2 * bez, h - 2 * rim - 2 * bez
    r_out, r_in, r_img = round(58 * s), round(55 * s), round(46 * s)
    t = f"transform:rotate({rot}deg);" if rot else ""
    return (f'<div style="position:absolute;left:{x}px;top:{y}px;width:{w}px;height:{h}px;background:linear-gradient(135deg, #8E8E93, #2B2B2E);'
            f'border-radius:{r_out}px;padding:{rim}px;display:flex;box-shadow:{shadow};{t}">'
            f'<div style="flex:1;background:#050505;border-radius:{r_in}px;padding:{bez}px;display:flex">'
            f'<img src="/_blob/{IMG[key]}" alt="{alt}" style="width:{iw}px;height:{ih}px;object-fit:cover;border-radius:{r_img}px"></div></div>')


def write(name, text):
    with open(os.path.join(OUT, name + ".html"), "w", encoding="utf-8") as f:
        f.write(text)


EYEBROW = "font-size:28px;font-weight:500;letter-spacing:6px;text-transform:uppercase;"
H2 = "font-family:'Unbounded', Arial, sans-serif;font-weight:600;line-height:1.15;"

# ---------------------------------------------------------------- cover
logo = ('<svg aria-label="Логотип Tropa: слово tropa одной линией, хвост которой заканчивается точкой" viewBox="14 2 390 120" width="760" height="234" '
        'style="width:760px;height:234px"><g fill="none" stroke="#F2E8CF" stroke-width="10.5" stroke-linecap="round" stroke-linejoin="round">'
        '<path d="M50 16 V60 A20 20 0 0 0 70 80 M34 40 H68"/><path d="M95 40 V80 M95 60 A20 20 0 0 1 115 40"/>'
        '<path d="M139.5 60 A20.5 20.5 0 1 0 180.5 60 A20.5 20.5 0 1 0 139.5 60"/><path d="M205 40 V112"/>'
        '<path d="M204.5 60 A20.5 20.5 0 1 0 245.5 60 A20.5 20.5 0 1 0 204.5 60"/><path d="M259.5 60 A20.5 20.5 0 1 0 300.5 60 A20.5 20.5 0 1 0 259.5 60"/>'
        '<path d="M300 40 V60 A20 20 0 0 0 320 80 C342 80 342 56 364 56"/></g><circle cx="373.5" cy="56" r="8.5" fill="#FF7043"/></svg>')
contours = ('<svg aria-label="Тонкие линии высот, как на карте" viewBox="0 0 1920 1080" width="1920" height="1080" style="position:absolute;left:0px;top:0px;width:1920px;height:1080px">'
            '<g fill="none" stroke="#2A6B58" stroke-width="3" opacity="0.7"><path d="M1180 520 C1180 300 1500 220 1700 300 C1900 380 1900 700 1720 800 C1540 900 1180 820 1180 520 Z"/>'
            '<path d="M1260 520 C1260 360 1500 300 1650 360 C1800 420 1810 660 1680 740 C1540 820 1260 760 1260 520 Z"/>'
            '<path d="M1340 520 C1340 420 1500 380 1600 420 C1710 470 1720 620 1640 680 C1540 740 1340 690 1340 520 Z"/></g></svg>')
write("cover", f'''<section id="cover" data-transition="fade" style="background:linear-gradient(135deg, #0E4D3A, #071C2C);color:#F2E8CF;font-family:'Rubik', Arial, sans-serif;padding:128px;display:flex;flex-direction:column;justify-content:center;gap:44px">
{contours}
{phone("p2", "Постер велопрогулки на тёмной карте", 1030, 230, rot=-6)}
{phone("home", "Главный экран приложения Tropa: кнопка «Начать запись» и список прогулок", 1350, 130, rot=4, shadow="0px 24px 64px rgba(0,0,0,0.6)")}
{logo}
<h2 style="font-family:'Unbounded', Arial, sans-serif;font-size:50px;font-weight:500;line-height:1.25;color:#F6F1E3;width:860px">Трекер маршрутов, который работает без&nbsp;интернета</h2>
<p style="font-size:30px;font-weight:300;line-height:1.4;color:#CFE3D8;width:800px">Проанализирует и запишет ваш маршрут, сохранит ваше достижение.</p>
<aside>Первый слайд объясняет суть и показывает результат: экран приложения и готовый постер.</aside>
</section>
''')

# ---------------------------------------------------------------- record
chips = "".join(f'<p style="font-size:26px;font-weight:500;background:#0E4D3A;color:#F6F1E3;padding:12px 28px;border-radius:40px">{c}</p>'
                for c in ["Пешком", "Велосипед", "Авто", "Сплав", "Смешанный"])
write("record", f'''<section id="record" data-transition="fade" style="background:#F6F1E3;color:#0E2A22;font-family:'Rubik', Arial, sans-serif;padding:128px 128px 160px;display:flex;flex-direction:column;justify-content:center;gap:36px">
{phone("record", "Экран записи: таймер, дистанция, кнопки «Остановить», «Пауза», «Заметка»", 1380, 138, shadow="0px 20px 56px rgba(14,42,34,0.35)")}
<p style="{EYEBROW}color:#B0432C;width:1100px">Запись</p>
<h2 style="{H2}font-size:58px;color:#0E2A22;width:1150px">Запишите свой маршрут: в прогулке или в путешествии</h2>
<div style="display:flex;flex-direction:column;gap:22px;width:1150px">
<p style="font-size:32px;line-height:1.4;color:#2F4038"><b style="color:#0E4D3A">Без интернета:</b> в горах, в джунглях, за границей</p>
<p style="font-size:32px;line-height:1.4;color:#2F4038"><b style="color:#0E4D3A">Экран погас&nbsp;— запись идёт:</b> телефон можно убрать в карман</p>
<p style="font-size:32px;line-height:1.4;color:#2F4038"><b style="color:#0E4D3A">Заметки по дороге:</b> подпись или фото привяжутся к месту</p>
</div>
<div style="display:flex;gap:16px;width:1150px;flex-wrap:wrap">{chips}</div>
<p style="position:absolute;left:128px;bottom:64px;font-size:24px;color:#6B7A72">Tropa · 02</p>
<aside>Экран записи из реального приложения (значения на кадре подставлены правдоподобные: 42 минуты, 3,27 км). Режим выбирается значками на карточке записи; смешанный режим сам делит маршрут на пешие и транспортные участки.</aside>
</section>
''')

# ---------------------------------------------------------------- nav
write("nav", f'''<section id="nav" data-transition="fade" style="background:#0E4D3A;color:#F6F1E3;font-family:'Rubik', Arial, sans-serif;padding:128px 128px 160px;display:flex;flex-direction:column;justify-content:center;gap:36px">
{phone("route", "Экран маршрута: карта, длина, время в пути, кнопка «Идти по маршруту»", 1050, 190, rot=-4, shadow="0px 20px 56px rgba(0,0,0,0.45)")}
{phone("nav", "Экран навигации: поворот направо через 55 метров, осталось 3,13 км, голосовые подсказки", 1370, 120, rot=3, shadow="0px 24px 64px rgba(0,0,0,0.55)")}
<p style="{EYEBROW}color:#9FD8C0;width:860px">Навигатор</p>
<h2 style="{H2}font-size:54px;color:#F6F1E3;width:860px">Идите по скачанному маршруту, как по навигатору</h2>
<div style="display:flex;flex-direction:column;gap:20px;width:860px">
<p style="font-size:30px;line-height:1.4;color:#CFE3D8"><b style="color:#F6F1E3">Подскажет поворот:</b> голосом и вибрацией, заранее</p>
<p style="font-size:30px;line-height:1.4;color:#CFE3D8"><b style="color:#F6F1E3">Скажет, если сбились,</b> и отметит, когда вернулись</p>
<p style="font-size:30px;line-height:1.4;color:#CFE3D8"><b style="color:#F6F1E3">Карта без сети:</b> скачайте район заранее</p>
<p style="font-size:30px;line-height:1.4;color:#CFE3D8"><b style="color:#F6F1E3">Ждать у старта:</b> запись начнётся, когда вы дойдёте до начала</p>
</div>
<p style="position:absolute;left:128px;bottom:64px;font-size:24px;color:#9FD8C0">Tropa · 03 · Данные карты © OpenStreetMap</p>
<aside>Слева экран маршрута, справа экран навигации во время движения. Экран навигации ещё дорабатывается. Навигатор проверен на эмуляторе; на реальной прогулке ещё в тестировании.</aside>
</section>
''')

# ---------------------------------------------------------------- auto
write("auto", f'''<section id="auto" data-transition="fade" style="background:#C8553D;color:#FFF8EC;font-family:'Rubik', Arial, sans-serif;padding:128px 128px 160px;display:flex;flex-direction:column;justify-content:center;gap:36px">
{phone("auto", "Экран «Автозапись»: переключатель, готовность телефона, кнопка «Запланировать»", 1050, 190, rot=-4, shadow="0px 20px 56px rgba(80,24,10,0.5)")}
{phone("planner", "Окно «Новая прогулка»: название, дата и время, способ передвижения, автозапуск", 1370, 120, rot=3, shadow="0px 24px 64px rgba(80,24,10,0.55)")}
<p style="{EYEBROW}color:#FFE3D2;width:860px">Работает за вас</p>
<h2 style="{H2}font-size:54px;color:#FFF8EC;width:860px">А если приключение начнётся в любую минуту?</h2>
<div style="display:flex;flex-direction:column;gap:26px;width:860px">
<p style="font-size:30px;line-height:1.4;color:#FFE9DC"><b style="color:#FFF8EC">Автозапись:</b> включите её в приложении, и Tropa сама начнёт запись трека, когда вы начнёте движение.</p>
<p style="font-size:30px;line-height:1.4;color:#FFE9DC"><b style="color:#FFF8EC">Планировщик:</b> выберите дату, время и способ передвижения, и запись начнётся в нужный момент.</p>
</div>
<p style="position:absolute;left:128px;bottom:64px;font-size:24px;color:#FFE3D2">Tropa · 04</p>
<aside>Слева экран «Автозапись» с проверкой готовности телефона, справа окно «Новая прогулка» из планировщика.</aside>
</section>
''')

# ---------------------------------------------------------------- share
write("share", f'''<section id="share" data-transition="fade" style="background:#F6F1E3;color:#0E2A22;font-family:'Rubik', Arial, sans-serif;padding:128px 128px 160px;display:flex;flex-direction:column;justify-content:center;gap:40px">
{phone("poster", "Экран постера: готовый постер и кнопки «Сохранить постер» и «Поделиться постером»", 1380, 138, shadow="0px 20px 56px rgba(14,42,34,0.35)")}
<p style="{EYEBROW}color:#B0432C;width:1100px">Делитесь</p>
<h2 style="{H2}font-size:58px;color:#0E2A22;width:1150px">Делитесь своим маршрутом или постером пройденного пути</h2>
<div style="display:flex;flex-direction:column;gap:22px;width:1150px">
<p style="font-size:32px;line-height:1.4;color:#2F4038"><b style="color:#0E4D3A">Маршрутом:</b> файлом GPX, он откроется в любом навигаторе</p>
<p style="font-size:32px;line-height:1.4;color:#2F4038"><b style="color:#0E4D3A">Постером:</b> ваш путь на карте, цифры, погода и заметки</p>
<p style="font-size:32px;line-height:1.4;color:#2F4038"><b style="color:#0E4D3A">Картой:</b> снимок с вашей тропой</p>
</div>
<p style="position:absolute;left:128px;bottom:64px;font-size:24px;color:#6B7A72">Tropa · 05</p>
<aside>Экран постера из приложения: кнопки «Сохранить постер» и «Поделиться постером». В превью подставлен постер велопрогулки.</aside>
</section>
''')

# ---------------------------------------------------------------- trio
cap = lambda x, t1, t2: (f'<div style="position:absolute;left:{x - 50}px;top:930px;width:411px;display:flex;flex-direction:column;gap:4px;align-items:center">'
                         f'<p style="font-size:32px;font-weight:600;color:#F6F1E3;text-align:center">{t1}</p>'
                         f'<p style="font-size:26px;color:#CFE3D8;text-align:center">{t2}</p></div>')
write("trio", f'''<section id="trio" data-transition="fade" style="background:#08211F;color:#F6F1E3;font-family:'Rubik', Arial, sans-serif;padding:96px 128px 64px;display:flex;flex-direction:column;gap:20px">
<p style="font-size:26px;font-weight:500;letter-spacing:6px;text-transform:uppercase;color:#9FD8C0">Постеры</p>
<h2 style="{H2}font-size:52px;color:#F6F1E3;width:1664px">Ваша прогулка&nbsp;— одной картинкой</h2>
{phone("p1", "Постер: подъём на гору Хан-Муа, линия окрашена по высоте", 293, 250, w=311, shadow="0px 16px 48px rgba(0,0,0,0.55)")}
{phone("p2", "Постер: велопрогулка, линия окрашена по скорости", 804, 250, w=311, shadow="0px 16px 48px rgba(0,0,0,0.55)")}
{phone("p3", "Постер: дорога на машине и сплав по реке", 1315, 250, w=311, shadow="0px 16px 48px rgba(0,0,0,0.55)")}
{cap(293, "Поход в горы", "цвет линии&nbsp;— высота")}
{cap(804, "Велопрогулка", "цвет линии&nbsp;— скорость")}
{cap(1315, "Дорога и сплав", "два способа в одном маршруте")}
<aside>Три постера из трёх регионов: Хан-Муа (Вьетнам, реальная запись), Урал (велосипед) и Горный Алтай (машина и сплав). Маршруты на Урале и Алтае проложены по реальным дорогам и рекам, скорость и остановки смоделированы; фото ваши.</aside>
</section>
''')

# ---------------------------------------------------------------- finale
write("finale", f'''<section id="finale" data-transition="fade" style="background:linear-gradient(135deg, #0E4D3A, #071C2C);color:#F2E8CF;font-family:'Rubik', Arial, sans-serif;padding:128px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:56px">
<h2 style="{H2}font-size:64px;color:#F6F1E3;text-align:center;width:1664px">Путешествуй, сохраняй, делись!</h2>
<svg aria-label="Логотип Tropa: слово tropa одной линией, хвост которой заканчивается точкой" viewBox="14 2 390 120" width="520" height="160" style="width:520px;height:160px"><g fill="none" stroke="#F2E8CF" stroke-width="10.5" stroke-linecap="round" stroke-linejoin="round"><path d="M50 16 V60 A20 20 0 0 0 70 80 M34 40 H68"/><path d="M95 40 V80 M95 60 A20 20 0 0 1 115 40"/><path d="M139.5 60 A20.5 20.5 0 1 0 180.5 60 A20.5 20.5 0 1 0 139.5 60"/><path d="M205 40 V112"/><path d="M204.5 60 A20.5 20.5 0 1 0 245.5 60 A20.5 20.5 0 1 0 204.5 60"/><path d="M259.5 60 A20.5 20.5 0 1 0 300.5 60 A20.5 20.5 0 1 0 259.5 60"/><path d="M300 40 V60 A20 20 0 0 0 320 80 C342 80 342 56 364 56"/></g><circle cx="373.5" cy="56" r="8.5" fill="#FF7043"/></svg>
<p style="font-size:34px;font-weight:300;line-height:1.4;color:#CFE3D8;text-align:center;width:1200px">Трекер маршрутов, который работает без интернета.</p>
<aside>Финал и главный лозунг. Полный логотип, как на обложке, в меньшем масштабе.</aside>
</section>
''')
print("ok")
