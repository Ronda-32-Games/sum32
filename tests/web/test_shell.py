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


TESTS = []


async def main():
    srv = serve()
    try:
        async with async_playwright() as p:
            await test_bug005_engine_source(p)
            browser = await p.chromium.launch(args=ARGS)
            for t in TESTS:
                await t(browser)
            await browser.close()
    finally:
        srv.shutdown()
    print("RESULT:", "OK" if not failures else f"{len(failures)} FAILURES")
    sys.exit(1 if failures else 0)


asyncio.run(main())
