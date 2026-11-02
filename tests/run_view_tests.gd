extends SceneTree
## Pruebas de la vista (game_view.gd), sin pantalla:
##   godot --headless -s tests/run_view_tests.gd
## Manejan la escena con toques y cuadros simulados. Cada prueba lleva el BUG que cubre
## y el caso Q del plan de Nahir que lo re-prueba en el teléfono.
## Grilla de ?seed=32 (traspaso de Nahir): la Corta es F1C3-F1C4-F1C5 (índices 2, 3, 4);
## la Larga es F2C1-F2C2-F3C2-F4C2-F5C2-F6C2 (índices 6, 7, 13, 19, 25, 31).

const START := 0
const PLAYING := 1
const PAUSED := 2
const RESULT := 3
const CORTA := [2, 3, 4]
const LARGA := [6, 7, 13, 19, 25, 31]

var failures := 0
var view: Control


var started := false


func _initialize() -> void:
	view = load("res://scenes/main.tscn").instantiate()
	root.add_child(view)


## Las pruebas corren en el primer cuadro, con la escena ya dentro del árbol.
## Los cuadros del juego los da cada prueba llamando a view._process.
func _process(_delta: float) -> bool:
	if started:
		return false
	started = true
	view.set_process(false)  # que el motor no avance la partida por su cuenta
	_run()
	return false


func _run() -> void:
	# Si game_view.gd no compila, la escena queda sin script y todo lo demás "pasa" sin probar nada.
	if not view.has_method("_new_round"):
		print("FAIL game_view.gd no cargó (error de sintaxis)")
		quit(1)
		return
	_test_bug004_background_does_not_eat_time()
	_test_bug001_result_is_protected()
	_test_bug003_early_drag_starts_after_effect()
	_test_bug002_falling_cells_not_selectable()
	_test_task036_no_record_with_params()
	_test_task059_daily_flow()
	_test_task059_daily_errors()
	print("RESULT: ", "OK" if failures == 0 else "%d FAILURES" % failures)
	quit(1 if failures > 0 else 0)


func check(cond: bool, msg: String) -> void:
	print(("ok   " if cond else "FAIL ") + msg)
	if not cond:
		failures += 1


# --- Ayudas ------------------------------------------------------------------

func _start_round(seed_value: int, seconds: int = 60) -> void:
	view.config["round_seconds"] = seconds
	view.seed_base = seed_value
	view.games_played = 0
	view._new_round()
	view._layout()
	view.screen = PLAYING


func _step(seconds: float, frames: int = 1) -> void:
	for k in frames:
		view._process(seconds / frames)


func _pos(i: int) -> Vector2:
	# Centro donde se VE la casilla (incluye lo que le falta caer).
	return view._cell_center(i) - Vector2(0, view.fall_offset[i])


func _press(p: Vector2) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.position = p
	view._gui_input(e)


func _release(p: Vector2) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = false
	e.position = p
	view._gui_input(e)


func _drag_to(p: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = p
	view._gui_input(e)


func _swipe(cells: Array) -> void:
	_press(view._cell_center(cells[0]))
	for k in range(1, cells.size()):
		_drag_to(view._cell_center(cells[k]))
	_release(view._cell_center(cells[cells.size() - 1]))


# --- Pruebas -----------------------------------------------------------------

## BUG-004 (Q14 a Q16): volver de segundo plano no descuenta el tiempo de afuera.
## Con la página oculta el navegador no da cuadros; al volver llega un cuadro de 20 s.
func _test_bug004_background_does_not_eat_time() -> void:
	_start_round(32)
	_step(0.5, 5)
	var before: int = view.round_.remaining_ms()
	_step(20.0)  # un solo cuadro largo: estuvo afuera y no llegó el aviso de foco
	var after: int = view.round_.remaining_ms()
	check(view.screen == PAUSED, "BUG-004 un cuadro de 20 s pausa la partida")
	check(before - after <= 250, "BUG-004 el reloj no descuenta el tiempo de afuera (%d ms)" % (before - after))
	check(not view.round_.is_over(), "BUG-004 la partida no termina estando afuera")
	# Un toque sigue la partida y no arranca una cadena (Q17).
	_press(view._cell_center(2))
	check(view.screen == PLAYING and view.chain.size() == 0, "BUG-004 el toque de Tap to continue no empieza cadena")
	_release(view._cell_center(2))


## BUG-001 (Q13): un toque apurado tras TIME'S UP no arranca otra partida.
func _test_bug001_result_is_protected() -> void:
	_start_round(32, 1)
	_step(1.2, 12)
	check(view.screen == RESULT, "BUG-001 la partida terminó")
	var btn: Rect2 = view._button_rect()
	_press(btn.get_center())
	check(view.screen == RESULT, "BUG-001 un toque apenas sale TIME'S UP no arranca otra")
	_release(btn.get_center())
	_step(0.9, 9)
	_press(btn.get_center())
	check(view.screen == PLAYING, "BUG-001 pasados 0,8 s, PLAY AGAIN responde")
	_release(btn.get_center())


## BUG-003 (Q21): un arrastre empezado durante el efecto del ¡32! no se pierde.
func _test_bug003_early_drag_starts_after_effect() -> void:
	_start_round(32)
	_swipe(CORTA)
	check(view.round_.score == 90, "BUG-003 la Corta da 90")
	# Antes de 0,26 s: apoyo el dedo en F2C1 y no lo levanto.
	_press(view._cell_center(6))
	_step(0.4, 8)  # termina el efecto; el dedo sigue apoyado
	_drag_to(view._cell_center(7))
	check(view.chain.size() == 2 and view.chain[0] == 6 and view.chain[1] == 7,
		"BUG-003 la cadena arranca sola al terminar el efecto, sin levantar el dedo (%s)" % [view.chain])
	_release(view._cell_center(7))
	_step(1.0, 20)


## BUG-002 (Q21): durante la caída no se puede tomar una casilla que todavía no llegó.
func _test_bug002_falling_cells_not_selectable() -> void:
	_start_round(32)
	_swipe(CORTA)
	_step(3.5, 70)  # más de 3 s: sin combo
	_swipe(LARGA)
	check(view.round_.score == 90 + 360, "BUG-002 la Larga da 360 (total %d)" % view.round_.score)
	_step(0.3, 6)   # termina el efecto: empieza la caída de la columna 2
	_step(0.05, 1)  # el 12 de F1C2 todavía está arriba, bajando
	var spot: Vector2 = view._cell_center(31)  # F6C2, donde va a llegar
	check(view.fall_offset[31] > view.cell_pitch, "BUG-002 F6C2 todavía está cayendo")
	_press(spot)
	var ok := true
	for i in view.chain:
		if view.fall_offset[i] > view.cell_pitch * 0.15:
			ok = false
	check(ok, "BUG-002 no se toma una casilla que todavía cae (cadena %s)" % [view.chain])
	_step(1.0, 20)  # llega; el dedo sigue ahí
	check(view.chain.size() == 1 and view.chain[0] == 31, "BUG-002 al llegar, la casilla bajo el dedo entra (%s)" % [view.chain])
	_release(spot)


## TASK-036: con parámetros de prueba la partida no guarda récord.
func _test_task036_no_record_with_params() -> void:
	view.best_score = 0
	view.record_enabled = false
	_start_round(32, 2)
	_swipe(CORTA)
	_step(2.5, 25)
	check(view.screen == RESULT and view.round_.score == 90, "TASK-036 la partida terminó con 90")
	check(view.best_score == 0 and not view.new_best, "TASK-036 sin récord con parámetros de prueba")
	view.record_enabled = true
	_start_round(32, 2)
	_swipe(CORTA)
	_step(2.5, 25)
	check(view.best_score == 90 and view.new_best, "TASK-036 sin parámetros, el récord sí se guarda")


# --- TASK-059: Daily ---------------------------------------------------------

## Servidor de mentira: guarda los pedidos y responde lo que la prueba le pone en replies.
class FakeServer:
	extends RefCounted
	var up := true
	var log: Array = []           # [método, ruta, cuerpo]
	var replies := {}             # "GET /daily" -> {"status", "body"} (o Array para responder en orden)
	var _out := {}

	func available() -> bool:
		return up

	func request(id: String, method: String, path: String, body: Variant) -> void:
		log.append([method, path, body])
		var key := method + " " + path
		var r = replies.get(key, {"status": 0, "body": {"error": "network"}})
		if r is Array:
			r = r.pop_front() if r.size() > 1 else r[0]
		_out[id] = r

	func poll(id: String) -> Variant:
		var r = _out.get(id)
		_out.erase(id)
		return r

	func sent(key: String) -> Array:
		return log.filter(func(e): return e[0] + " " + e[1] == key)


func _fake_daily(left: int) -> FakeServer:
	var f := FakeServer.new()
	f.replies["GET /daily"] = {"status": 200, "body": {"day": "2026-11-02", "attempts_allowed": 3, "attempts_used": 3 - left, "attempts_left": left, "best": null, "resets_in_ms": 3600000}}
	f.replies["POST /daily/start"] = {"status": 200, "body": {"run_id": "run-1", "seed": 32, "day": "2026-11-02", "attempts_left": left - 1}}
	f.replies["GET /leaderboard"] = {"status": 200, "body": {"day": "2026-11-02", "players": 2, "top": [{"rank": 1, "name": "Ana", "score": 900, "me": false}, {"rank": 2, "name": "Nacho", "score": 450, "me": true}], "me": {"rank": 2, "score": 450}}}
	view.daily = DailyClient.new(f)
	view.record_enabled = true
	view.daily.refresh()
	view.mode = "practice"
	view.screen = START
	view._new_round()
	view._layout()
	_step(0.016)
	return f


func _tap(id: String) -> bool:
	for b in view._buttons():
		if b["id"] == id and b["enabled"]:
			_press((b["rect"] as Rect2).get_center())
			return true
	return false


func _ids() -> Array:
	return view._buttons().map(func(b): return b["id"])


## TASK-059 (DEC-052): el Daily gasta el intento al empezar, juega la grilla del servidor,
## manda las jugadas a mitad de partida y al final, y muestra el puesto y el ranking.
func _test_task059_daily_flow() -> void:
	var f := _fake_daily(3)
	check(_ids() == ["daily", "practice", "ranking"], "TASK-059 con servidor, el inicio ofrece DAILY, PRACTICE y RANKING (%s)" % [_ids()])
	view.config["round_seconds"] = 2
	check(_tap("daily") and view.screen == 5, "TASK-059 DAILY pide el intento y espera")
	_step(0.016)
	check(view.screen == PLAYING and view.mode == "daily", "TASK-059 llegó la semilla: empieza el Daily")
	check(view.board.cells.slice(0, 6) == Board.new(view.config, 32).cells.slice(0, 6), "TASK-059 la grilla es la de la semilla del servidor")
	f.replies["POST /run"] = {"status": 200, "body": {"score": 90, "chains": 1, "best_chain": 3, "status": "open", "day": "2026-11-02", "day_best": 90, "rank": 2}}
	_swipe(CORTA)
	_step(0.016)
	var partial := f.sent("POST /run")
	check(partial.size() == 1 and partial[0][2]["final"] == false and partial[0][2]["moves"].size() == 1, "TASK-059 la cadena sale enseguida como jugada parcial")
	f.replies["POST /run"] = {"status": 200, "body": {"score": 90, "chains": 1, "best_chain": 3, "status": "done", "day": "2026-11-02", "day_best": 90, "rank": 2}}
	_step(2.5, 25)
	var runs := f.sent("POST /run")
	var last: Dictionary = runs[runs.size() - 1][2]
	check(view.screen == RESULT and last["final"] == true and last["run_id"] == "run-1" and last["moves"].size() == 1, "TASK-059 al terminar sale la jugada final con todas las jugadas")
	check(view.daily.run_state == "ok" and view.daily.result["rank"] == 2, "TASK-059 el resultado muestra el puesto del servidor")
	check(view.best_score == 0 or not view.new_best, "TASK-059 el Daily no toca el récord de Practice")
	check(_ids() == ["ranking", "menu"], "TASK-059 después del Daily: RANKING y MENU (%s)" % [_ids()])
	_step(1.0, 10)
	check(_tap("ranking") and view.screen == 4 and f.sent("GET /leaderboard").size() == 1, "TASK-059 RANKING trae la tabla del día")
	_step(0.016)
	check(view.daily.board_state == "ok" and view.daily.leaderboard["top"].size() == 2, "TASK-059 la tabla llegó")
	f.replies["GET /daily"]["body"]["attempts_left"] = 2
	check(_tap("back") and view.screen == START and view.mode == "practice", "TASK-059 BACK vuelve al inicio con una grilla de Practice")
	_step(0.016)
	check(view.daily.attempts_left() == 2, "TASK-059 el inicio muestra los intentos que quedan (2)")
	view.config["round_seconds"] = 60


## TASK-059: sin intentos no empieza; si la red falla, la jugada final se reintenta.
func _test_task059_daily_errors() -> void:
	var f := _fake_daily(0)
	var daily_btn = view._buttons()[0]
	check(daily_btn["id"] == "daily" and not daily_btn["enabled"], "TASK-059 sin intentos, DAILY está apagado")
	check(_tap("practice") and view.screen == PLAYING and view.mode == "practice", "TASK-059 PRACTICE sigue andando")
	f = _fake_daily(1)
	f.replies["POST /daily/start"] = {"status": 403, "body": {"error": "no_attempts"}}
	_tap("daily")
	_step(0.016)
	check(view.screen == START and view.menu_note != "", "TASK-059 si el servidor dice que no quedan intentos, vuelve al inicio con aviso")
	# Reintento de la final: la red falla dos veces y después anda.
	f = _fake_daily(2)
	var d: DailyClient = view.daily
	d.start()
	d.update(0.0)
	f.replies["POST /run"] = [{"status": 0, "body": {"error": "network"}}, {"status": 503, "body": {"error": "server"}}, {"status": 200, "body": {"score": 0, "status": "done", "rank": null}}]
	d.push_moves([], true)
	d.update(10.0)
	check(d.run_state == "pending", "TASK-059 la red falló: la final queda pendiente")
	d.update(11.5)   # primer reintento (1 s después)
	d.update(12.0)   # llega el 503: el siguiente, 2 s después
	d.update(14.5)
	d.update(14.6)
	check(f.sent("POST /run").size() == 3 and d.run_state == "ok", "TASK-059 la final se reintenta hasta que llega (%d envíos)" % f.sent("POST /run").size())
	f.up = false
	view.screen = START
	check(not view.daily_enabled() and _ids() == ["practice"], "TASK-059 sin servidor queda como H1: solo PLAY")
	view.daily = DailyClient.new(null)
