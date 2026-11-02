"""Pruebas de navegador de la página de arranque y del juego exportado.

Uso (desde la raíz del repo, con la build en build/web):
    pip install playwright && python -m playwright install chromium
    python -I tests/web/test_shell.py build/web

Cada prueba lleva el BUG o la TASK que cubre. Sale con código 1 si algo falla.
"""
import asyncio
import functools
import http.server
import json
import sys
import threading

from playwright.async_api import async_playwright

BUILD = sys.argv[1] if len(sys.argv) > 1 else "build/web"
PORT = 8790
BASE = f"http://127.0.0.1:{PORT}/index.html"
# Sin Telegram: telegram.org apunta a un puerto cerrado y su script falla rápido; la página
# tiene que andar igual. No se usa page.route porque desactiva la caché del navegador.
ARGS = ["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist",
        "--host-resolver-rules=MAP telegram.org 127.0.0.1:9"]

failures = []


def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        failures.append(msg)


class Handler(http.server.SimpleHTTPRequestHandler):
    # Como GitHub Pages: el navegador puede guardar los archivos 10 minutos.
    def end_headers(self):
        self.send_header("Cache-Control", "max-age=600")
        super().end_headers()

    def log_message(self, *a):
        pass


def serve():
    handler = functools.partial(Handler, directory=BUILD)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


async def open_game(page, query=""):
    await page.goto(BASE + query)
    await page.wait_for_function("window.r32 && window.r32.metrics.first != null", timeout=120000)
    await page.wait_for_timeout(300)


async def new_page(browser):
    ctx = await browser.new_context(viewport={"width": 390, "height": 844})
    page = await ctx.new_page()
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    return ctx, page, errors


async def test_bug005_engine_source(pw):
    """BUG-005: el panel dice si el motor vino de internet o de la caché, y cold fuerza la descarga."""
    # Perfil en disco, como un teléfono: la caché en memoria del modo incógnito no guarda 38 MB.
    import tempfile
    profile = tempfile.mkdtemp(prefix="sum32-profile-")
    ctx = await pw.chromium.launch_persistent_context(profile, args=ARGS, viewport={"width": 390, "height": 844})
    page = ctx.pages[0] if ctx.pages else await ctx.new_page()
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    await open_game(page)
    first = await page.evaluate("window.r32.engineFrom()")
    check(first.startswith("network"), f"BUG-005 primera carga: motor de internet ({first})")
    await open_game(page, "?again=1")
    second = await page.evaluate("window.r32.engineFrom()")
    check(second == "cache", f"BUG-005 segunda carga: motor de la caché, no frío ({second})")
    await open_game(page, "?cold=1")
    cold = await page.evaluate("window.r32.engineFrom()")
    check(cold.startswith("network"), f"BUG-005 con cold: se vuelve a bajar el motor ({cold})")
    await open_game(page, "?tgWebAppStartParam=test_cold")
    cold_tg = await page.evaluate("window.r32.engineFrom()")
    check(cold_tg.startswith("network"), f"BUG-005 con startapp=test_cold: se vuelve a bajar ({cold_tg})")
    await page.click("#r32-btn")
    panel = await page.inner_text("#r32-panel")
    check("H0" not in panel and "load metrics" in panel, "BUG-005 el título del panel ya no dice H0")
    check("Engine         : network" in panel, "BUG-005 el panel muestra la línea Engine")
    check(not errors, f"sin errores de página ({errors[:2]})")
    await ctx.close()


async def tap_game(page, gx, gy):
    """Toca un punto en coordenadas del juego (las que informa window.r32.state)."""
    st = await page.evaluate("window.r32.state")
    w = await page.evaluate("window.innerWidth")
    k = w / st["view"][0]
    await page.mouse.click(gx * k, gy * k)


async def wait_state(page, cond, timeout=30000):
    await page.wait_for_function(f"window.r32 && window.r32.state && ({cond})", timeout=timeout)
    return await page.evaluate("window.r32.state")


async def test_task036_test_mode(browser):
    """TASK-036 y BUG-006: el panel solo en modo de prueba; startapp fija la grilla; sin récord."""
    ctx, page, errors = await new_page(browser)
    await open_game(page)
    check(not await page.is_visible("#r32-btn"), "TASK-036 sin parámetros no se ve el botón ms")
    check(await page.evaluate("window.r32.state === undefined"), "TASK-036 sin parámetros no se publica el estado")
    # Como llega dentro de Telegram: t.me/ronda32games_bot/sum32?startapp=test_seed32_round3
    await open_game(page, "?tgWebAppStartParam=test_seed32_round3")
    check(await page.is_visible("#r32-btn"), "TASK-036 en modo de prueba se ve el botón ms")
    st = await wait_state(page, "true")
    check(st["first_row"] == [10, 12, 11, 11, 10, 9], f"BUG-006 startapp con seed32 fija la grilla ({st['first_row']})")
    check(st["remaining_ms"] == 3000, f"BUG-006 startapp con round3 dura 3 s ({st['remaining_ms']})")
    check(st["record_enabled"] is False, "TASK-036 con parámetros no hay récord")
    await tap_game(page, *st["button"])
    st = await wait_state(page, "window.r32.state.screen === 'result'", 20000)
    best = await page.evaluate("localStorage.getItem('sum32_best')")
    check(best is None, f"TASK-036 la partida de prueba no guardó récord ({best})")
    check(not errors, f"sin errores de página ({errors[:2]})")
    await ctx.close()


HOLD_FRAMES = """(() => {
  // Como en el teléfono con la app en segundo plano: el navegador deja de dar cuadros.
  const raf = window.requestAnimationFrame.bind(window); window.__hold = true;
  window.requestAnimationFrame = function (cb) {
    return raf(function step(ts) { if (window.__hold) raf(step); else cb(ts); });
  };
})()"""


async def start_playing(page, query):
    await open_game(page, query)
    st = await wait_state(page, "true")
    await tap_game(page, *st["button"])
    await wait_state(page, "window.r32.state.screen === 'playing'")
    await page.wait_for_timeout(1000)
    return (await page.evaluate("window.r32.state"))["remaining_ms"]


async def test_bug004_background(browser):
    """BUG-004: al volver de segundo plano, pausa y no descuenta el tiempo de afuera."""
    # A: sin ningún aviso del navegador, solo 6 s sin cuadros.
    ctx, page, errors = await new_page(browser)
    before = await start_playing(page, "?test=1")
    await page.evaluate(HOLD_FRAMES)
    await asyncio.sleep(6)
    await page.evaluate("window.__hold = false")
    st = await wait_state(page, "window.r32.state.screen !== 'playing'", 10000)
    lost = before - st["remaining_ms"]
    check(st["screen"] == "paused", f"BUG-004 sin aviso: al volver está en pausa ({st['screen']})")
    check(lost < 1000, f"BUG-004 sin aviso: no descontó el tiempo de afuera ({lost} ms)")
    await ctx.close()
    # B: el navegador avisa que la página se ocultó, y vuelve enseguida.
    ctx, page, errors2 = await new_page(browser)
    before = await start_playing(page, "?test=1")
    await page.evaluate("""(() => {
      Object.defineProperty(document, 'hidden', { configurable: true, get: () => true });
      document.dispatchEvent(new Event('visibilitychange'));
      Object.defineProperty(document, 'hidden', { configurable: true, get: () => false });
    })()""")
    st = await wait_state(page, "window.r32.state.screen !== 'playing'", 10000)
    check(st["screen"] == "paused", f"BUG-004 con aviso de oculto: pausa aunque vuelva rápido ({st['screen']})")
    check(not (errors + errors2), f"sin errores de página ({(errors + errors2)[:2]})")
    await ctx.close()


def find_chain(cells, n, target=32):
    """Una cadena de vecinas (arriba, abajo, costados) que suma target, o None."""
    def walk(path, total):
        if total == target and len(path) >= 2:
            return path
        if total >= target:
            return None
        r, c = divmod(path[-1], n)
        for dr, dc in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            rr, cc = r + dr, c + dc
            j = rr * n + cc
            if 0 <= rr < n and 0 <= cc < n and j not in path:
                got = walk(path + [j], total + cells[j])
                if got:
                    return got
        return None
    for i in range(n * n):
        got = walk([i], cells[i])
        if got:
            return got
    return None


async def swipe_cells(page, st, cells):
    w = await page.evaluate("window.innerWidth")
    k = w / st["view"][0]
    ox, oy, pitch, n = st["grid"]
    pts = [((ox + (i % n + 0.5) * pitch) * k, (oy + (i // n + 0.5) * pitch) * k) for i in cells]
    await page.mouse.move(*pts[0])
    await page.mouse.down()
    for p in pts[1:]:
        await page.mouse.move(*p, steps=4)
    await page.mouse.up()


def button(st, name):
    return next((b for b in st["buttons"] if b[0] == name), None)


async def test_task059_daily(browser):
    """TASK-059 (DEC-052): Daily de punta a punta contra la base local (server/scripts/dev.js)."""
    import os, subprocess, tempfile, urllib.request
    db = os.path.join(tempfile.mkdtemp(prefix="sum32-dev-"), "dev.db")
    here = os.path.dirname(os.path.abspath(__file__))
    srv = subprocess.Popen(["node", os.path.join(here, "../../server/scripts/dev.js"), "--port", "8791", "--db", db],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        srv.stdout.readline()  # "Sum 32, base local: ..."
        ctx, page, errors = await new_page(browser)
        await open_game(page, "?test&api=http://127.0.0.1:8791")
        st = await wait_state(page, "window.r32.state.daily.day === 'ok'")
        check([b[0] for b in st["buttons"]] == ["daily", "practice", "ranking"], f"TASK-059 inicio con DAILY, PRACTICE y RANKING ({[b[0] for b in st['buttons']]})")
        check(st["daily"]["left"] == 3, f"TASK-059 3 intentos (DEC-052) ({st['daily']['left']})")
        await tap_game(page, *button(st, "daily")[1:3])
        st = await wait_state(page, "window.r32.state.screen === 'playing' && window.r32.state.mode === 'daily'")
        made = 0
        for _ in range(3):
            st = await page.evaluate("window.r32.state")
            ch = find_chain(st["cells"], st["grid"][3])
            if not ch or st["screen"] != "playing":
                break
            await swipe_cells(page, st, ch)
            await page.wait_for_timeout(900)  # que caigan las nuevas
            made += 1
        st = await page.evaluate("window.r32.state")
        check(made >= 2 and st["score"] > 0, f"TASK-059 se jugaron {made} cadenas ({st['score']} puntos)")
        st = await wait_state(page, "window.r32.state.screen === 'result' && window.r32.state.daily.run !== 'pending'", 90000)
        check(st["daily"]["run"] == "ok" and st["daily"]["score"] == st["score"], f"TASK-059 el servidor rehizo la partida y da el mismo puntaje ({st['daily']['score']} = {st['score']})")
        check(st["daily"]["rank"] == 1, f"TASK-059 puesto 1 del día ({st['daily']['rank']})")
        await page.wait_for_timeout(900)
        await tap_game(page, *button(st, "ranking")[1:3])
        st = await wait_state(page, "window.r32.state.screen === 'ranking' && window.r32.state.daily.board === 'ok'")
        check(True, "TASK-059 la pantalla de ranking cargó")
        await tap_game(page, *button(st, "back")[1:3])
        st = await wait_state(page, "window.r32.state.screen === 'start' && window.r32.state.mode === 'practice' && window.r32.state.daily.left === 2")
        check(True, "TASK-059 vuelve al inicio con 2 intentos")
        login = json.load(urllib.request.urlopen("http://127.0.0.1:8791/dev/login?user=1"))
        req = urllib.request.Request("http://127.0.0.1:8791/leaderboard", headers={"Authorization": "tma " + login["init_data"]})
        lb = json.load(urllib.request.urlopen(req))
        check(lb["players"] == 1 and lb["top"][0]["score"] > 0, f"TASK-059 la base guardó el puntaje del Daily ({lb['top']})")
        check(not errors, f"sin errores de página ({errors[:2]})")
        await ctx.close()
    finally:
        srv.terminate()


# Para correr solo algunas: python -I tests/web/test_shell.py build/web test_task059_daily
TESTS = [test_task036_test_mode, test_bug004_background, test_task059_daily]


async def main():
    srv = serve()
    try:
        async with async_playwright() as p:
            if not sys.argv[2:]:
                await test_bug005_engine_source(p)
            browser = await p.chromium.launch(args=ARGS)
            only = sys.argv[2:]
            for t in TESTS:
                if not only or t.__name__ in only:
                    await t(browser)
            await browser.close()
    finally:
        srv.shutdown()
    print("RESULT:", "OK" if not failures else f"{len(failures)} FAILURES")
    sys.exit(1 if failures else 0)


asyncio.run(main())
