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
	_test_bug004_background_does_not_eat_time()
	_test_bug001_result_is_protected()
	_test_bug003_early_drag_starts_after_effect()
	_test_bug002_falling_cells_not_selectable()
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
