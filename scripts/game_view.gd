extends Control
## Vista y control de Sum 32 (H1, modo Practice): pantallas, HUD, arrastre, sonidos y
## efectos con el arte de Lía, y puente con la página (Telegram, récord, medición).
## Las reglas viven en Board (grilla) y Round (partida); los colores en
## assets/paleta.json; los sonidos en assets/sonidos/sonidos.json.

const CONFIG_PATH := "res://data/config.json"
const PALETTE_PATH := "res://assets/paleta.json"
const SOUNDS_PATH := "res://assets/sonidos/sonidos.json"

const SHEET := preload("res://assets/casillas/casillas_hoja_1280x256.png")
const PARTICLE := preload("res://assets/efectos/particula_32.png")

# Estados de la hoja de casillas, en el orden de Lía.
enum Tile { NORMAL, CADENA, JUSTO, PASADO, SALIENDO }
const TILE_PX := 256.0
const BODY_PX := 200.0
const BODY_CENTER_Y := [121.5, 113.5, 113.5, 113.5, 121.5]  # las de cadena suben 2 px

# Pantallas de H1.
enum Screen { START, PLAYING, PAUSED, RESULT, RANKING, WAIT }

# Tiempos del efecto del ¡32! (traspaso de Lía).
const FX_GROW := 0.08
const FX_GONE := 0.26
const FX_TEXT := 0.60
const FX_SCORE_FLY := 0.40
const FX_FLASH := 0.12
# BUG-004: un cuadro más largo que esto es que la app estuvo afuera; y el reloj nunca
# descuenta más que MAX_TICK_MS por cuadro.
const AWAY_S := 1.0
const MAX_TICK_MS := 250.0
# BUG-001: el resultado no se puede saltear durante este tiempo (segundos reales).
const RESULT_GUARD_S := 0.8
# BUG-002: una casilla se puede tocar cuando le falta caer menos que esto (fracción de casilla).
const SETTLED := 0.15
const PARTICLES_PER_CELL := 6
const PARTICLES_MAX := 48

var config: Dictionary = {}
var pal: Dictionary = {}
var board: Board
var round_: Round
var font_num: Font
var font_ui: Font
var sounds: Dictionary = {}
var screen := Screen.START
var seed_base := 0
var games_played := 0
# Daily (TASK-059, DEC-052). mode: "practice" o "daily". Sin servidor (fuera de Telegram,
# o con parámetros de prueba que cambian la partida) el juego queda como antes: solo Practice.
var daily: DailyClient
var mode := "practice"
var menu_note := ""        # aviso en el inicio (por ejemplo, si no se pudo empezar el Daily)

var chain := PackedInt32Array()
var dragging := false
var last_pointer := Vector2.ZERO
var chain_state := "neutro"

# Récord personal (navegador del jugador; en H2 pasa al servidor).
var best_score := 0
var new_best := false

# Reloj.
var ms_acc := 0.0
var last_tick_s := -1

# Geometría (unidades del juego), calculada en _layout().
var grid_origin := Vector2.ZERO
var grid_w := 600.0
var cell_pitch := 100.0
var top_inset := 0.0
var col_x := 0.0
var col_w := 720.0
var px := 2.0  # cuántas unidades del juego mide 1 px de un celular de 360 de ancho
var score_pos := Vector2.ZERO

# Animaciones.
var fall_offset := PackedFloat32Array()
var pending_fall := PackedInt32Array()
var fx_t := -1.0          # tiempo desde el borrado; -1 = sin efecto
var fx_cells := PackedInt32Array()
var fx_snapshot := PackedInt32Array()
var fx_text_pos := Vector2.ZERO
var fx_points := 0
var fx_combo := 10
var bonus_t := -1.0       # cartel "+2s"
var particles: Array = []
var fx_rng := RandomNumberGenerator.new()

var frames := 0
var fps_timer := 0.0
var result_age := 0.0  # segundos reales desde que salió TIME'S UP
var last_frame_ms := -1  # reloj real del cuadro anterior (BUG-004)
var test_mode := false
var record_enabled := true
var test_label: Array = []
var state_timer := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)
	config = _load_json(CONFIG_PATH)
	pal = _load_json(PALETTE_PATH)
	font_num = _load_font("res://assets/fuentes/MartianMono-Bold-Sum32.ttf")
	font_ui = _load_font("res://assets/fuentes/MartianMono-Medium-UI.ttf")
	_load_sounds()
	seed_base = int(Time.get_unix_time_from_system() * 1000.0) & Mulberry32.MASK
	_read_test_params()
	var saved = _js("window.r32 ? window.r32.getBest() : 0")
	best_score = int(saved) if saved != null else 0
	daily = DailyClient.new(JsTransport.new() if OS.has_feature("web") else null)
	if daily_enabled():
		daily.refresh()
	_new_round()
	fall_offset.resize(board.size * board.size)
	get_viewport().size_changed.connect(_layout)
	_layout()
	_js("window.r32 && window.r32.onGodotReady()")


## Modo de prueba (TASK-036, BUG-006). Los parámetros los arma la página: en el navegador
## vienen en la dirección (?seed=32&round=5&slow=10&test=1) y dentro de Telegram en
## startapp (t.me/ronda32games_bot/sum32?startapp=test_seed32_round5_slow10).
## Con seed, round o slow la partida no guarda récord.
func _read_test_params() -> void:
	var raw = _js("JSON.stringify(window.r32 ? window.r32.params : {})")
	var p = JSON.parse_string(raw) if raw is String else null
	if not (p is Dictionary):
		return
	test_mode = bool(p.get("test", false))
	if p.get("seed") != null:
		seed_base = int(p["seed"]) & Mulberry32.MASK
		record_enabled = false
		test_label.append("seed %d" % int(p["seed"]))
	if p.get("round") != null and int(p["round"]) > 0:
		config["round_seconds"] = int(p["round"])
		record_enabled = false
		test_label.append("%ds" % int(p["round"]))
	if p.get("slow") != null and int(p["slow"]) >= 1:
		Engine.time_scale = 1.0 / float(p["slow"])
		record_enabled = false
		test_label.append("slow x%d" % int(p["slow"]))


## El Daily se ofrece si hay servidor y la partida es la oficial (sin seed, round ni slow).
func daily_enabled() -> bool:
	return record_enabled and daily != null and daily.available()


## daily_seed >= 0: partida del Daily con la semilla que dio el servidor.
func _new_round(daily_seed: int = -1) -> void:
	# Practice: grilla nueva por partida. Con ?seed=, la primera es la pedida.
	var seed_value := seed_base if games_played == 0 else Mulberry32.derive(seed_base, games_played)
	mode = "practice"
	if daily_seed >= 0:
		seed_value = daily_seed & Mulberry32.MASK
		mode = "daily"
	board = Board.new(config, seed_value)
	round_ = Round.new(config, board)
	chain = PackedInt32Array()
	chain_state = "neutro"
	dragging = false
	ms_acc = 0.0
	last_tick_s = -1
	new_best = false
	fx_t = -1.0
	bonus_t = -1.0
	particles.clear()
	fall_offset.resize(board.size * board.size)
	fall_offset.fill(0.0)


func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("No se pudo abrir " + path)
		return {}
	var data = JSON.parse_string(f.get_as_text())
	return data if data is Dictionary else {}


func _load_font(path: String) -> Font:
	var f = load(path)
	if f is FontFile:
		(f as FontFile).hinting = TextServer.HINTING_LIGHT
		(f as FontFile).antialiasing = TextServer.FONT_ANTIALIASING_GRAY
		return f
	return ThemeDB.fallback_font


func _load_sounds() -> void:
	var spec := _load_json(SOUNDS_PATH)
	for key in ["toque", "justo", "pasado", "clear_32", "combo", "tiempo_extra", "tick", "fin", "record", "boton"]:
		if not spec.has(key):
			continue
		var stream = load("res://assets/sonidos/" + str(spec[key]["archivo"]))
		if stream == null:
			continue
		var p := AudioStreamPlayer.new()
		p.stream = stream
		p.volume_db = float(spec[key].get("volumen_db", 0))
		p.max_polyphony = 4
		add_child(p)
		sounds[key] = p


func _play(key: String, pitch: float = 1.0) -> void:
	if sounds.has(key):
		var p: AudioStreamPlayer = sounds[key]
		p.pitch_scale = pitch
		p.play()


## Color de la paleta por nombre; acepta claves anidadas como "linea_cadena/justo".
func c(key: String) -> Color:
	var node: Variant = pal
	for part in key.split("/"):
		if node is Dictionary and (node as Dictionary).has(part):
			node = node[part]
		else:
			return Color.MAGENTA  # color faltante: se nota a propósito
	return Color.html(str(node))


func _js(code: String) -> Variant:
	if OS.has_feature("web"):
		return JavaScriptBridge.eval(code, true)
	return null


func _layout() -> void:
	var view := get_viewport_rect().size
	top_inset = 0.0
	var css_top = _js("window.r32 ? window.r32.topInsetCss() : 0")
	var css_h = _js("window.innerHeight || 0")
	if css_top != null and css_h != null and float(css_h) > 0.0:
		top_inset = float(css_top) * view.y / float(css_h)
	col_w = minf(view.x, (view.y - top_inset) * 0.6)
	col_x = (view.x - col_w) * 0.5
	px = col_w / 360.0
	var header_h := col_w * 0.46
	var avail_h := view.y - top_inset - header_h - col_w * 0.06
	grid_w = minf(col_w * 0.92, avail_h)
	cell_pitch = grid_w / board.size
	var extra := maxf(0.0, avail_h - grid_w)
	grid_origin = Vector2((view.x - grid_w) * 0.5, top_inset + header_h + extra * 0.3)
	score_pos = Vector2(col_x + col_w * 0.86, top_inset + col_w * 0.16)
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_pause()


func _pause() -> void:
	if screen != Screen.PLAYING:
		return
	screen = Screen.PAUSED
	dragging = false
	chain = PackedInt32Array()
	chain_state = "neutro"
	queue_redraw()


func _process(delta: float) -> void:
	frames += 1
	if frames == 2:
		_js("window.r32 && window.r32.onFirstFrame()")
	fps_timer += delta
	if fps_timer >= 0.5:
		fps_timer = 0.0
		_js("window.r32 && window.r32.reportFps(%d, %s)" % [Engine.get_frames_per_second(), "true" if dragging else "false"])
	var real_delta := delta / maxf(Engine.time_scale, 0.0001)
	# Godot recorta los saltos largos de delta, así que el tiempo afuera se mide con el
	# reloj real entre cuadros.
	var now_ms := Time.get_ticks_msec()
	var wall_gap_s := 0.0 if last_frame_ms < 0 else (now_ms - last_frame_ms) / 1000.0
	last_frame_ms = now_ms
	_update_daily(now_ms / 1000.0)
	if test_mode:
		state_timer += real_delta
		if state_timer >= 0.1:
			state_timer = 0.0
			_publish_state()
	if screen == Screen.PLAYING:
		# BUG-004: con la página oculta el navegador no da cuadros, así que no alcanza con
		# preguntar si está oculta: la página deja una marca al ocultarse y acá se lee.
		# Si igual llega un cuadro larguísimo, es que estuvo afuera: pausa sin descontar.
		var hid = _js("window.r32 ? window.r32.consumeHidden() : 0")  # booleanos llegan como 0 o 1
		if real_delta > AWAY_S or wall_gap_s > AWAY_S or (hid != null and bool(hid)):
			_pause()
		else:
			_tick_clock(delta)
		# BUG-003: dedo apoyado esperando que termine el efecto o que llegue la casilla.
		if dragging and chain.size() == 0 and screen == Screen.PLAYING:
			_try_start(last_pointer)
	elif screen == Screen.RESULT:
		result_age += real_delta
		if result_age < RESULT_GUARD_S + 0.1:
			queue_redraw()
	elif screen == Screen.WAIT:
		queue_redraw()  # los puntitos de "Loading"

	var animating := screen == Screen.PLAYING
	if fx_t >= 0.0:
		var before := fx_t
		fx_t += delta
		if before < FX_GROW and fx_t >= FX_GROW:
			_spawn_particles()
		if before < FX_GONE and fx_t >= FX_GONE:
			# Recién ahora caen las nuevas: la cadena se ve irse antes de que llegue lo nuevo.
			for i in pending_fall.size():
				fall_offset[i] = pending_fall[i] * cell_pitch
		if fx_t > FX_GONE + FX_TEXT:
			fx_t = -1.0
		animating = true
	if bonus_t >= 0.0:
		bonus_t += delta
		if bonus_t > 0.9:
			bonus_t = -1.0
		animating = true
	var speed := cell_pitch * 14.0 * delta
	for i in fall_offset.size():
		if fall_offset[i] > 0.0:
			fall_offset[i] = maxf(0.0, fall_offset[i] - speed)
			animating = true
	for prt in particles:
		prt["life"] -= delta
		prt["pos"] += prt["vel"] * delta
		prt["rot"] += prt["spin"] * delta
	particles = particles.filter(func(prt): return prt["life"] > 0.0)
	if particles.size() > 0:
		animating = true
	if animating:
		queue_redraw()


## En modo de prueba, la página ve el estado del juego (lo usan las pruebas de navegador).
func _publish_state() -> void:
	var btn := _button_rect()
	var st := {
		"screen": ["start", "playing", "paused", "result", "ranking", "wait"][screen],
		"mode": mode,
		"daily": {"enabled": daily_enabled(), "day": daily.day_state, "left": daily.attempts_left(),
			"run": daily.run_state, "score": daily.result.get("score"), "rank": daily.result.get("rank"),
			"board": daily.board_state, "error": daily.error},
		"buttons": _buttons().map(func(b): return [b["id"], (b["rect"] as Rect2).get_center().x, (b["rect"] as Rect2).get_center().y, b["enabled"]]),
		"score": round_.score,
		"remaining_ms": round_.remaining_ms(),
		"chain": Array(chain),
		"first_row": Array(board.cells.slice(0, board.size)),
		"cells": Array(board.cells),
		"grid": [grid_origin.x, grid_origin.y, cell_pitch, board.size],
		"record_enabled": record_enabled,
		"best": best_score,
		"button": [btn.get_center().x, btn.get_center().y],
		"view": [get_viewport_rect().size.x, get_viewport_rect().size.y],
	}
	_js("window.r32 && (window.r32.state = %s)" % JSON.stringify(st))


func _tick_clock(delta: float) -> void:
	ms_acc += minf(delta * 1000.0, MAX_TICK_MS)
	var ms := int(ms_acc)
	ms_acc -= ms
	round_.advance(ms)
	var left_s := int(ceil(round_.remaining_ms() / 1000.0))
	if left_s <= 10 and left_s > 0 and left_s != last_tick_s:
		_play("tick")
	last_tick_s = left_s
	if round_.is_over():
		_finish()


func _finish() -> void:
	# Una cadena que se está arrastrando al terminar no cuenta.
	dragging = false
	chain = PackedInt32Array()
	chain_state = "neutro"
	screen = Screen.RESULT
	result_age = 0.0
	_play("fin")
	_haptic("heavy")
	if mode == "daily":
		# El puntaje que vale es el que calcula el servidor rehaciendo la partida.
		daily.push_moves(round_.moves, true)
		queue_redraw()
		return
	games_played += 1
	# Analítica (TASK-063): la página avisa al servidor; en modo de prueba no manda nada.
	_js("window.r32 && window.r32.roundEnd && window.r32.roundEnd(%d)" % round_.score)
	# Con parámetros de prueba no hay récord: ensuciaría el del jugador.
	if record_enabled and round_.score > best_score:
		best_score = round_.score
		new_best = round_.score > 0
		_js("window.r32 && window.r32.setBest(%d)" % best_score)
		if new_best:
			_play("record")
	queue_redraw()


# --- Input -------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if screen != Screen.PLAYING:
			if event.pressed:
				_on_tap_overlay(event.position)
		elif event.pressed:
			_begin(event.position)
		else:
			_end()
		accept_event()
	elif event is InputEventMouseMotion and dragging:
		_move(event.position)
		accept_event()


func _on_tap_overlay(pos: Vector2) -> void:
	match screen:
		Screen.START, Screen.RESULT, Screen.RANKING:
			# BUG-001: el resultado queda a la vista un momento antes de poder saltearlo.
			if screen == Screen.RESULT and result_age < RESULT_GUARD_S:
				return
			for b in _buttons():
				if b["enabled"] and (b["rect"] as Rect2).has_point(pos):
					_play("boton")
					_on_button(b["id"])
					return
		Screen.PAUSED:
			_play("boton")
			screen = Screen.PLAYING  # cualquier toque sigue
			queue_redraw()


func _begin(pos: Vector2) -> void:
	# BUG-003: el dedo queda apoyado aunque todavía no se pueda empezar (efecto del ¡32!
	# o casilla cayendo); la cadena arranca sola apenas se puede, sin levantar el dedo.
	dragging = true
	chain = PackedInt32Array()
	chain_state = "neutro"
	last_pointer = pos
	_try_start(pos)


func _try_start(pos: Vector2) -> void:
	var i := _cell_at(pos, 0.48)
	if i < 0:
		return
	chain = PackedInt32Array([i])
	chain_state = "neutro"
	_on_chain_changed(true)


func _move(pos: Vector2) -> void:
	# Recorre el trayecto en pasos chicos para no saltear casillas si el dedo va rápido.
	var dist := last_pointer.distance_to(pos)
	var steps := maxi(1, int(dist / (cell_pitch * 0.2)))
	for s in range(1, steps + 1):
		var p := last_pointer.lerp(pos, float(s) / steps)
		if chain.size() == 0:
			_try_start(p)
			continue
		var i := _cell_at(p, 0.4)
		if i >= 0:
			_try_add(i)
	last_pointer = pos


func _try_add(i: int) -> void:
	var n := chain.size()
	if n == 0 or chain[n - 1] == i:
		return
	if n >= 2 and chain[n - 2] == i:
		chain.remove_at(n - 1)  # volver a la anterior la saca
		_on_chain_changed(false)
		return
	if chain.has(i) or not board.are_adjacent(chain[n - 1], i):
		return  # diagonal, salto o casilla vieja: no hace nada
	chain.append(i)
	_on_chain_changed(true)


func _on_chain_changed(added: bool) -> void:
	var s := board.chain_sum(chain)
	var new_state := "neutro"
	if chain.size() >= 2 and s == board.target:
		new_state = "justo"
	elif s > board.target:
		new_state = "pasado"
	if added:
		# El toque sube de tono con cada casilla: la cadena larga se escucha.
		var n := mini(chain.size() - 1, 9)
		_play("toque", pow(2.0, n / 12.0))
		_haptic("light")
	if new_state != chain_state:
		if new_state == "justo":
			_play("justo")
		elif new_state == "pasado" and chain_state != "pasado":
			_play("pasado")  # una vez por cruce, no en cada casilla
	chain_state = new_state
	queue_redraw()


func _end() -> void:
	if not dragging:
		return
	dragging = false
	if board.is_valid_chain(chain):
		var snapshot := board.cells.duplicate()
		var cells := chain.duplicate()
		var res := round_.close_chain(chain)
		if not res.is_empty():
			fx_snapshot = snapshot
			fx_cells = cells
			fx_text_pos = _cell_center(cells[cells.size() - 1])
			pending_fall = res["fall"]
			fx_points = res["points"]
			fx_combo = res["combo"]
			fx_t = 0.0
			if fx_combo > 10:
				_play("combo")
				_haptic("heavy")
			else:
				_play("clear_32")
				_haptic("medium")
			if res["bonus_ms"] > 0:
				bonus_t = 0.0
				_play("tiempo_extra")
			if mode == "daily":
				daily.push_moves(round_.moves, false)  # DEC-052: si se abandona, queda esto
	chain = PackedInt32Array()
	chain_state = "neutro"
	queue_redraw()


func _haptic(kind: String) -> void:
	_js("window.r32 && window.r32.haptic('%s')" % kind)


func _cell_center(i: int) -> Vector2:
	return grid_origin + Vector2((board.col_of(i) + 0.5) * cell_pitch, (board.row_of(i) + 0.5) * cell_pitch)


## Casilla bajo el dedo, según donde se VE (BUG-002). Mientras la cadena anterior se va,
## o si la casilla todavía está cayendo, no hay casilla para tocar.
func _cell_at(pos: Vector2, radius_ratio: float) -> int:
	if fx_t >= 0.0 and fx_t < FX_GONE:
		return -1  # se ve la grilla vieja; la nueva todavía no apareció
	var col := int(floor((pos.x - grid_origin.x) / cell_pitch))
	if col < 0 or col >= board.size:
		return -1
	for row in board.size:
		var i := board.index(row, col)
		if fall_offset[i] > cell_pitch * SETTLED:
			continue
		var center := _cell_center(i) - Vector2(0, fall_offset[i])
		if pos.distance_to(center) <= cell_pitch * radius_ratio:
			return i  # solo cuenta el centro de la casilla: evita diagonales accidentales
	return -1


func _spawn_particles() -> void:
	var colors := [c("justo"), c("texto")]
	var per_cell := PARTICLES_PER_CELL * (3 if fx_combo > 10 else 2) / 2  # 1,5 veces con combo
	var cap := PARTICLES_MAX * (3 if fx_combo > 10 else 2) / 2
	var k := 0
	for i in fx_cells:
		for j in per_cell:
			if particles.size() >= cap:
				return
			var ang := fx_rng.randf() * TAU
			var dist := fx_rng.randf_range(40.0, 70.0) * px
			particles.append({
				"pos": _cell_center(i),
				"vel": Vector2.from_angle(ang) * dist / 0.3,
				"rot": fx_rng.randf() * TAU,
				"spin": fx_rng.randf_range(-8.0, 8.0),
				"size": fx_rng.randf_range(10.0, 16.0) * px,
				"life": 0.3,
				"color": colors[k % 2],
			})
			k += 1


# --- Dibujo ------------------------------------------------------------------

func _draw() -> void:
	var view := get_viewport_rect().size
	var bg := c("fondo")
	if fx_combo > 10 and fx_t >= FX_GONE and fx_t < FX_GONE + FX_FLASH:
		bg = c("panel")  # destello del fondo con combo
	draw_rect(Rect2(Vector2.ZERO, view), bg)
	_draw_header()
	if screen == Screen.PLAYING or screen == Screen.RESULT:
		_draw_chain_line()
		_draw_grid()
		_draw_particles()
		_draw_fx_text()
		_draw_bonus()
	if test_mode:
		var tag := "TEST" + (" · " + " · ".join(test_label) if test_label.size() > 0 else "")
		if not record_enabled:
			tag += " · no record"
		_text(font_ui, tag, Vector2(col_x + col_w * 0.5, view.y - 70.0 * px), 11.0 * px, c("pasado"))  # arriba del botón ms
	match screen:
		Screen.START:
			_draw_start()
		Screen.PAUSED:
			_draw_cover("Paused", "Tap to continue")
		Screen.RESULT:
			_draw_result()
		Screen.RANKING:
			_draw_ranking()
		Screen.WAIT:
			var dots := ".".repeat(1 + (Time.get_ticks_msec() / 400) % 3)
			_draw_cover("Daily", "Loading" + dots)


func _fmt_score(v: int) -> String:
	var s := str(v)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out


func _draw_header() -> void:
	var cx := col_x + col_w * 0.5
	var y0 := top_inset + col_w * 0.07
	# Reloj a la izquierda, puntaje a la derecha.
	var left_ms := round_.remaining_ms()
	var secs := int(ceil(left_ms / 1000.0))
	var clock_col := c("reloj_ultimos_10s") if secs <= 10 and screen == Screen.PLAYING else c("texto")
	_text(font_ui, "TIME", Vector2(col_x + col_w * 0.14, y0), 11.0 * px, c("texto_suave"))
	_text(font_num, str(secs), Vector2(col_x + col_w * 0.14, y0 + 30.0 * px), 26.0 * px, clock_col)
	_text(font_ui, "SCORE", Vector2(score_pos.x, y0), 11.0 * px, c("texto_suave"))
	_text(font_num, _fmt_score(round_.score), Vector2(score_pos.x, y0 + 30.0 * px), 22.0 * px, c("texto"))
	# Indicador de suma al centro.
	var box_w := col_w * 0.4
	var box_h := col_w * 0.17
	var box := Rect2(Vector2(cx - box_w * 0.5, y0 - col_w * 0.025), Vector2(box_w, box_h))
	var spec: Dictionary = pal.get("indicador_suma", {}).get(chain_state, {})
	var sb := StyleBoxFlat.new()
	sb.bg_color = c("indicador_suma/%s/fondo" % chain_state)
	sb.set_corner_radius_all(int(box_h * 0.28))
	draw_style_box(sb, box)
	var s := board.chain_sum(chain)
	var label := str(spec.get("formato", "{suma}")).replace("{suma}", str(s))
	var label_col := c("indicador_suma/%s/texto" % chain_state)
	if chain.size() == 0:
		label = str(board.target)  # sin cadena: muestra el objetivo, apagado
		label_col = c("texto_suave")
	_text(font_num, label, box.get_center() + Vector2(0, box_h * 0.17), box_h * 0.5, label_col)
	# Combo vigente debajo, si lo hay.
	var combo := round_.current_combo()
	if screen == Screen.PLAYING and combo > 10:
		_text(font_num, "×%s" % _combo_txt(combo), Vector2(cx, box.end.y + col_w * 0.08), 18.0 * px, c("justo"))


func _combo_txt(tenths: int) -> String:
	return str(tenths / 10) if tenths % 10 == 0 else "%d.%d" % [tenths / 10, tenths % 10]


func _tile_state_for_chain() -> int:
	match chain_state:
		"justo":
			return Tile.JUSTO
		"pasado":
			return Tile.PASADO
		_:
			return Tile.CADENA


func _draw_grid() -> void:
	var showing_old := fx_t >= 0.0 and fx_t < FX_GONE
	var values := fx_snapshot if showing_old else board.cells
	var chain_tile := _tile_state_for_chain()
	for i in values.size():
		var center := _cell_center(i)
		var sc := 1.0
		var alpha := 1.0
		var state := Tile.NORMAL
		if showing_old and fx_cells.has(i):
			state = Tile.SALIENDO
			if fx_t < FX_GROW:
				sc = lerpf(1.0, 1.12, ease(fx_t / FX_GROW, 0.4))  # ease-out
			else:
				var k := (fx_t - FX_GROW) / (FX_GONE - FX_GROW)
				sc = lerpf(1.12, 0.0, ease(k, 2.2))  # ease-in
				alpha = 1.0 - k
		elif not showing_old:
			center.y -= fall_offset[i]
			if center.y < grid_origin.y - cell_pitch * 0.25:
				continue  # todavía cayendo desde fuera de la grilla
			if chain.has(i):
				state = chain_tile
		_draw_tile(center, state, values[i], sc, alpha)


func _draw_tile(center: Vector2, state: int, value: int, sc: float, alpha: float) -> void:
	# La hoja trae aire alrededor: escalamos para que el cuerpo ocupe ~86 % del paso.
	var dest := cell_pitch * 1.1 * sc
	var k := dest / TILE_PX
	var origin := center - Vector2(127.5 * k, float(BODY_CENTER_Y[state]) * k)
	var mod := Color(1, 1, 1, alpha)
	draw_texture_rect_region(SHEET, Rect2(origin, Vector2(dest, dest)), Rect2(state * TILE_PX, 0, TILE_PX, TILE_PX), mod)
	if sc <= 0.05:
		return
	var body := BODY_PX * k
	var digits := str(value)
	var fsz := body * (0.36 if digits.length() == 1 else 0.32)
	var num_col := c("numero")
	num_col.a = alpha
	_text(font_num, digits, center + Vector2(0, fsz * 0.36), fsz, num_col)


func _draw_chain_line() -> void:
	# Va detrás de las casillas: se ve solo en los huecos.
	if chain.size() < 2:
		return
	var pts := PackedVector2Array()
	for i in chain:
		pts.append(_cell_center(i))
	var key := "linea_cadena/" + ("justo" if chain_state == "justo" else ("pasado" if chain_state == "pasado" else "cadena"))
	var col := c(key)
	var w := cell_pitch * 0.2  # 12 px con casillas de ~55 px (celular de 360)
	draw_polyline(pts, col, w, true)
	for p in pts:
		draw_circle(p, w * 0.5, col)  # puntas y codos redondos


func _draw_particles() -> void:
	for prt in particles:
		var col: Color = prt["color"]
		col.a = clampf(prt["life"] / 0.3, 0.0, 1.0)
		var sz: float = prt["size"]
		draw_set_transform(prt["pos"], prt["rot"], Vector2.ONE)
		draw_texture_rect(PARTICLE, Rect2(Vector2(-sz, -sz) * 0.5, Vector2(sz, sz)), false, col)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_fx_text() -> void:
	if fx_t < FX_GONE:
		return
	var t := fx_t - FX_GONE
	var s := 1.0
	if t < 0.09:
		s = lerpf(0.6, 1.15, t / 0.09)
	elif t < 0.18:
		s = lerpf(1.15, 1.0, (t - 0.09) / 0.09)
	var alpha := 1.0 if t < FX_TEXT - 0.15 else clampf((FX_TEXT - t) / 0.15, 0.0, 1.0)
	var pos := fx_text_pos - Vector2(0, 24.0 * px * clampf(t / FX_TEXT, 0.0, 1.0))
	var label := "32!" if fx_combo <= 10 else "32! ×" + _combo_txt(fx_combo)
	_text_outlined(label, pos, 44.0 * px * s * (0.8 if fx_combo > 10 else 1.0), c("justo"), alpha)
	# El puntaje vuela al marcador.
	if t < FX_SCORE_FLY:
		var k := ease(t / FX_SCORE_FLY, 2.0)
		var from := fx_text_pos + Vector2(0, 30.0 * px)
		var at := from.lerp(score_pos + Vector2(0, 20.0 * px), k)
		_text_outlined("+%s" % _fmt_score(fx_points), at, 20.0 * px, c("texto"), 1.0 - k * 0.5)


func _draw_bonus() -> void:
	if bonus_t < 0.0:
		return
	var alpha := clampf(1.0 - (bonus_t - 0.5) / 0.4, 0.0, 1.0)
	var at := Vector2(col_x + col_w * 0.14, top_inset + col_w * 0.07 + 55.0 * px - 14.0 * px * bonus_t)
	_text_outlined("+%ds" % (round_.long_bonus_ms / 1000), at, 18.0 * px, c("justo"), alpha, font_ui)


func _draw_panel(rect: Rect2) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c("panel")
	sb.set_corner_radius_all(int(16.0 * px))
	draw_style_box(sb, rect)


## Botones de la pantalla actual: lo usan el dibujo, el toque y el estado que lee el navegador.
## Cada uno: {"id", "label", "rect", "primary", "enabled"}. Sin Daily, las pantallas tienen
## un solo botón, como en H1.
func _buttons() -> Array:
	var out: Array = []
	var with_daily := daily_enabled() and daily.day_state == "ok"
	match screen:
		Screen.START:
			if with_daily:
				var left := daily.attempts_left()
				out.append(_btn("daily", "DAILY" if left > 0 else "DAILY DONE", 0, left > 0, true))
				out.append(_btn("practice", "PRACTICE", 1, true, false))
				out.append(_btn("ranking", "RANKING", 2, true, false))
			else:
				out.append(_btn("practice", "PLAY", -1, true, true))
		Screen.RESULT:
			var ready := result_age >= RESULT_GUARD_S
			if mode == "daily":
				out.append(_btn("ranking", "RANKING", 0, ready, true))
				out.append(_btn("menu", "MENU", 3, ready, false))
			elif with_daily:
				out.append(_btn("practice", "PLAY AGAIN", 0, ready, true))
				out.append(_btn("menu", "MENU", 3, ready, false))
			else:
				out.append(_btn("practice", "PLAY AGAIN", -1, ready, true))
		Screen.RANKING:
			out.append(_btn("back", "BACK", -1, true, true))
	return out


## slot -1: botón único (como H1). 0: principal arriba. 1 y 2: mitades de abajo. 3: abajo entero.
func _btn(id: String, label: String, slot: int, enabled: bool, primary: bool) -> Dictionary:
	var r := _overlay_rect()
	var cx := r.get_center().x
	var rect: Rect2
	if slot == -1:
		var bsz := Vector2(col_w * 0.6, 52.0 * px)
		rect = Rect2(Vector2(cx, r.position.y + r.size.y * 0.78) - bsz * 0.5, bsz)
	elif slot == 0:
		var bsz := Vector2(col_w * 0.6, 48.0 * px)
		rect = Rect2(Vector2(cx, r.position.y + r.size.y * 0.71) - bsz * 0.5, bsz)
	else:
		var y := r.position.y + r.size.y * 0.885
		var h := 38.0 * px
		var w := col_w * 0.6
		if slot == 3:
			rect = Rect2(Vector2(cx - w * 0.5, y - h * 0.5), Vector2(w, h))
		else:
			var half := (w - 8.0 * px) * 0.5
			var x := cx - w * 0.5 if slot == 1 else cx + 4.0 * px
			rect = Rect2(Vector2(x, y - h * 0.5), Vector2(half, h))
	return {"id": id, "label": label, "rect": rect, "primary": primary, "enabled": enabled}


## El botón principal (lo usan las pruebas de H1 y el navegador).
func _button_rect() -> Rect2:
	for b in _buttons():
		if b["primary"]:
			return b["rect"]
	return Rect2()


func _on_button(id: String) -> void:
	match id:
		"practice":
			_new_round()
			_layout()
			screen = Screen.PLAYING
		"daily":
			menu_note = ""
			daily.start()
			screen = Screen.WAIT
		"ranking":
			daily.fetch_leaderboard()
			screen = Screen.RANKING
		"menu":
			_to_menu()
		"back":
			_to_menu()
	queue_redraw()


func _to_menu() -> void:
	screen = Screen.START
	if mode == "daily":
		_new_round()  # que el inicio no muestre la grilla del Daily terminada
		_layout()
	daily.refresh()


## Respuestas del servidor del Daily. now_s: reloj real.
func _update_daily(now_s: float) -> void:
	if daily == null:
		return
	daily.update(now_s)
	if screen == Screen.WAIT and daily.start_state != "pending":
		if daily.start_state == "ok":
			_new_round(daily.seed)
			_layout()
			screen = Screen.PLAYING
		else:
			menu_note = "No attempts left today." if daily.error == "no_attempts" else "Couldn't start the Daily. Try again."
			screen = Screen.START
			daily.refresh()
		queue_redraw()
	elif screen == Screen.RESULT and mode == "daily":
		queue_redraw()  # "Checking..." hasta que llegue el puntaje
	elif screen == Screen.RANKING or screen == Screen.START:
		queue_redraw()


func _draw_button_at(b: Dictionary) -> void:
	var rect: Rect2 = b["rect"]
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(int(14.0 * px))
	var label_col := c("numero")
	if b["primary"]:
		sb.bg_color = c("justo") if b["enabled"] else c("justo").darkened(0.45)
	else:
		sb.bg_color = c("fondo")
		sb.border_color = c("texto_suave")
		sb.set_border_width_all(maxi(1, int(1.5 * px)))
		label_col = c("texto") if b["enabled"] else c("texto_suave")
	draw_style_box(sb, rect)
	var size := (20.0 if b["primary"] else 14.0) * px
	_text(font_ui, b["label"], rect.get_center() + Vector2(0, size * 0.35), size, label_col)


func _draw_buttons() -> void:
	for b in _buttons():
		_draw_button_at(b)


func _overlay_rect() -> Rect2:
	return Rect2(Vector2(grid_origin.x, grid_origin.y), Vector2(grid_w, grid_w))


func _fmt_wait(ms: int) -> String:
	var mins := int(ceil(ms / 60000.0))
	return "%dh %02dm" % [mins / 60, mins % 60] if mins >= 60 else "%dm" % mins


func _draw_start() -> void:
	var r := _overlay_rect()
	_draw_panel(r)
	var cx := r.get_center().x
	var with_daily := daily_enabled() and daily.day_state == "ok"
	_text(font_ui, "SUM 32", Vector2(cx, r.position.y + r.size.y * (0.2 if with_daily else 0.26)), 40.0 * px, c("texto"))
	var secs := int(config.get("round_seconds", 60))
	var lines := ["Link neighbours that", "add up to %d." % board.target, "Longer chains score more.", "%d seconds." % secs]
	var y0 := 0.31 if with_daily else 0.38
	for k in lines.size():
		_text(font_ui, lines[k], Vector2(cx, r.position.y + r.size.y * (y0 + k * 0.06)), 12.0 * px, c("texto_suave"))
	if with_daily:
		var left := daily.attempts_left()
		var line := "Daily: %d of %d attempts left" % [left, daily.attempts_allowed()]
		if left <= 0:
			line = "New Daily in " + _fmt_wait(daily.resets_in_ms(Time.get_ticks_msec() / 1000.0))
		_text(font_ui, line, Vector2(cx, r.position.y + r.size.y * 0.58), 13.0 * px, c("texto"))
		var sub := menu_note
		if sub == "" and daily.best_today() > 0:
			sub = "Best today: " + _fmt_score(daily.best_today())
		if sub != "":
			_text(font_ui, sub, Vector2(cx, r.position.y + r.size.y * 0.63), 12.0 * px, c("texto_suave"))
	elif best_score > 0:
		_text(font_ui, "Best: " + _fmt_score(best_score), Vector2(cx, r.position.y + r.size.y * 0.66), 14.0 * px, c("texto"))
	_draw_buttons()


func _draw_cover(title: String, subtitle: String) -> void:
	var r := _overlay_rect()
	_draw_panel(r)  # tapa la grilla: pausar no sirve para pensar
	_text(font_ui, title, r.get_center() + Vector2(0, -6.0 * px), 26.0 * px, c("texto"))
	_text(font_ui, subtitle, r.get_center() + Vector2(0, 26.0 * px), 14.0 * px, c("texto_suave"))


func _draw_result() -> void:
	var r := _overlay_rect()
	_draw_panel(r)
	var cx := r.get_center().x
	var at := func(f: float) -> float: return r.position.y + r.size.y * f
	if mode == "daily":
		_text(font_ui, "DAILY · TIME'S UP", Vector2(cx, at.call(0.14)), 15.0 * px, c("texto_suave"))
		_text(font_num, _fmt_score(round_.score), Vector2(cx, at.call(0.31)), 44.0 * px, c("texto"))
		var line := "Checking score..."
		var col := c("texto_suave")
		match daily.run_state:
			"ok":
				var rank = daily.result.get("rank")
				line = "Saved" + ("  ·  Rank #%d" % int(rank) if rank != null else "")
				col = c("justo")
				if int(daily.result.get("score", round_.score)) != round_.score:
					line = "Saved: " + _fmt_score(int(daily.result["score"])) + ("  ·  #%d" % int(rank) if rank != null else "")
			"error":
				line = "Not saved (%s)" % daily.error
				col = c("pasado")
		_text(font_ui, line, Vector2(cx, at.call(0.41)), 14.0 * px, col)
		_text(font_ui, "Chains: %d   Longest: %d" % [round_.chains, round_.best_chain], Vector2(cx, at.call(0.50)), 13.0 * px, c("texto"))
		var left := daily.attempts_left()
		_text(font_ui, "%d attempt%s left today" % [left, "" if left == 1 else "s"], Vector2(cx, at.call(0.57)), 12.0 * px, c("texto_suave"))
	else:
		var with_daily := daily_enabled() and daily.day_state == "ok"
		var k := 0.9 if with_daily else 1.0  # con dos botones el texto sube un poco
		_text(font_ui, "TIME'S UP", Vector2(cx, at.call(0.17 * k)), 15.0 * px, c("texto_suave"))
		_text(font_num, _fmt_score(round_.score), Vector2(cx, at.call(0.36 * k)), 44.0 * px, c("justo") if new_best else c("texto"))
		if new_best:
			_text(font_ui, "NEW BEST!", Vector2(cx, at.call(0.46 * k)), 15.0 * px, c("justo"))
		else:
			_text(font_ui, "Best: " + _fmt_score(best_score), Vector2(cx, at.call(0.46 * k)), 14.0 * px, c("texto_suave"))
		_text(font_ui, "Chains: %d   Longest: %d" % [round_.chains, round_.best_chain], Vector2(cx, at.call(0.58 * k)), 14.0 * px, c("texto"))
	_draw_buttons()


const RANK_ROWS := 8


func _draw_ranking() -> void:
	var r := _overlay_rect()
	_draw_panel(r)
	var cx := r.get_center().x
	var at := func(f: float) -> float: return r.position.y + r.size.y * f
	_text(font_ui, "TODAY'S RANKING", Vector2(cx, at.call(0.1)), 16.0 * px, c("texto"))
	if daily.board_state != "ok":
		var msg := "Loading..." if daily.board_state == "pending" else "Couldn't load the ranking."
		_text(font_ui, msg, Vector2(cx, at.call(0.42)), 13.0 * px, c("texto_suave"))
		_draw_buttons()
		return
	var lb := daily.leaderboard
	var top: Array = lb.get("top", [])
	var players := int(lb.get("players", 0))
	_text(font_ui, "%d player%s · resets 00:00 UTC" % [players, "" if players == 1 else "s"], Vector2(cx, at.call(0.155)), 11.0 * px, c("texto_suave"))
	if top.is_empty():
		_text(font_ui, "Nobody yet. Be the first!", Vector2(cx, at.call(0.42)), 13.0 * px, c("texto_suave"))
	var left_x := r.position.x + r.size.x * 0.1
	var right_x := r.position.x + r.size.x * 0.9
	var rows := top.slice(0, RANK_ROWS)
	var me = lb.get("me")
	var me_in_top := rows.any(func(row): return bool(row.get("me", false)))
	if me is Dictionary and not me_in_top:
		# Fuera de los 8: los 6 primeros, "···" y tu fila, sin pisar el botón.
		rows = top.slice(0, RANK_ROWS - 2)
		_text(font_ui, "···", Vector2(cx, at.call(0.24 + (RANK_ROWS - 2) * 0.058 - 0.015)), 12.0 * px, c("texto_suave"))
		_rank_row({"rank": me["rank"], "name": "You", "score": me["score"], "me": true}, at.call(0.24 + (RANK_ROWS - 1) * 0.058), left_x, right_x)
	for k in rows.size():
		_rank_row(rows[k], at.call(0.24 + k * 0.058), left_x, right_x)
	_draw_buttons()


func _rank_row(row: Dictionary, y: float, left_x: float, right_x: float) -> void:
	var size := int(13.0 * px)
	var col := c("justo") if bool(row.get("me", false)) else c("texto")
	var name := "%d. %s" % [int(row.get("rank", 0)), str(row.get("name", "?"))]
	draw_string(font_ui, Vector2(left_x, y), name, HORIZONTAL_ALIGNMENT_LEFT, (right_x - left_x) * 0.7, size, col)
	var score := _fmt_score(int(row.get("score", 0)))
	var w := font_ui.get_string_size(score, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(font_ui, Vector2(right_x - w, y), score, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _text(font: Font, text: String, center_baseline: Vector2, size_px: float, color: Color) -> void:
	var sz := int(size_px)
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x
	draw_string(font, center_baseline - Vector2(w * 0.5, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, color)


func _text_outlined(text: String, center: Vector2, size_px: float, fill: Color, alpha: float, font: Font = null) -> void:
	if font == null:
		font = font_num
	var sz := int(size_px)
	fill.a = alpha
	var outline := c("fondo")
	outline.a = alpha
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x
	var at := center + Vector2(-w * 0.5, sz * 0.36)
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, int(8.0 * px), outline)
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, fill)
