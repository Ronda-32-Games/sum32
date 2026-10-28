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
enum Screen { START, PLAYING, PAUSED, RESULT }

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


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)
	config = _load_json(CONFIG_PATH)
	pal = _load_json(PALETTE_PATH)
	font_num = _load_font("res://assets/fuentes/MartianMono-Bold-Sum32.ttf")
	font_ui = _load_font("res://assets/fuentes/MartianMono-Medium-UI.ttf")
	_load_sounds()
	seed_base = int(Time.get_unix_time_from_system() * 1000.0) & Mulberry32.MASK
	# Para pruebas (Nahir): ?seed=123 en la dirección repite siempre la misma grilla.
	var url_seed = _js("new URLSearchParams(location.search).get('seed') || ''")
	if url_seed is String and (url_seed as String).is_valid_int():
		seed_base = int(url_seed) & Mulberry32.MASK
	# Para revisar animaciones (Lía, Nahir): ?slow=10 corre todo 10 veces más lento.
	var url_slow = _js("new URLSearchParams(location.search).get('slow') || ''")
	if url_slow is String and (url_slow as String).is_valid_float() and float(url_slow) >= 1.0:
		Engine.time_scale = 1.0 / float(url_slow)
	# Para pruebas (Nahir): ?round=5 acorta la partida a 5 segundos.
	var url_round = _js("new URLSearchParams(location.search).get('round') || ''")
	if url_round is String and (url_round as String).is_valid_int() and int(url_round) > 0:
		config["round_seconds"] = int(url_round)
	var saved = _js("window.r32 ? window.r32.getBest() : 0")
	best_score = int(saved) if saved != null else 0
	_new_round()
	fall_offset.resize(board.size * board.size)
	get_viewport().size_changed.connect(_layout)
	_layout()
	_js("window.r32 && window.r32.onGodotReady()")


func _new_round() -> void:
	# Practice: grilla nueva por partida. Con ?seed=, la primera es la pedida.
	var seed_value := seed_base if games_played == 0 else Mulberry32.derive(seed_base, games_played)
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
	if screen == Screen.PLAYING:
		# BUG-004: con la página oculta el navegador no da cuadros, así que no alcanza con
		# preguntar si está oculta: la página deja una marca al ocultarse y acá se lee.
		# Si igual llega un cuadro larguísimo, es que estuvo afuera: pausa sin descontar.
		var hid = _js("window.r32 ? window.r32.consumeHidden() : 0")  # booleanos llegan como 0 o 1
		if real_delta > AWAY_S or (hid != null and bool(hid)):
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
	games_played += 1
	_play("fin")
	_haptic("heavy")
	if round_.score > best_score:
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
		Screen.START, Screen.RESULT:
			# BUG-001: el resultado queda a la vista un momento antes de poder saltearlo.
			if screen == Screen.RESULT and result_age < RESULT_GUARD_S:
				return
			if _button_rect().has_point(pos):
				_play("boton")
				if screen == Screen.RESULT:
					_new_round()
					_layout()
				screen = Screen.PLAYING
				queue_redraw()
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
	match screen:
		Screen.START:
			_draw_start()
		Screen.PAUSED:
			_draw_cover("Paused", "Tap to continue")
		Screen.RESULT:
			_draw_result()


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


## Rectángulo del botón de las pantallas de inicio y resultado (lo usan el dibujo y el toque).
func _button_rect() -> Rect2:
	var r := _overlay_rect()
	var bsz := Vector2(col_w * 0.6, 52.0 * px)
	var center := Vector2(r.get_center().x, r.position.y + r.size.y * 0.78)
	return Rect2(center - bsz * 0.5, bsz)


func _draw_button(label: String) -> void:
	var rect := _button_rect()
	var ready := not (screen == Screen.RESULT and result_age < RESULT_GUARD_S)
	var sb := StyleBoxFlat.new()
	sb.bg_color = c("justo") if ready else c("justo").darkened(0.45)
	sb.set_corner_radius_all(int(14.0 * px))
	draw_style_box(sb, rect)
	_text(font_ui, label, rect.get_center() + Vector2(0, 7.0 * px), 20.0 * px, c("numero"))


func _overlay_rect() -> Rect2:
	return Rect2(Vector2(grid_origin.x, grid_origin.y), Vector2(grid_w, grid_w))


func _draw_start() -> void:
	var r := _overlay_rect()
	_draw_panel(r)
	var cx := r.get_center().x
	_text(font_ui, "SUM 32", Vector2(cx, r.position.y + r.size.y * 0.26), 40.0 * px, c("texto"))
	var secs := int(config.get("round_seconds", 60))
	var lines := ["Link neighbours that", "add up to %d." % board.target, "Longer chains score more.", "%d seconds." % secs]
	for k in lines.size():
		_text(font_ui, lines[k], Vector2(cx, r.position.y + r.size.y * (0.38 + k * 0.065)), 12.0 * px, c("texto_suave"))
	if best_score > 0:
		_text(font_ui, "Best: " + _fmt_score(best_score), Vector2(cx, r.position.y + r.size.y * 0.66), 14.0 * px, c("texto"))
	_draw_button("PLAY")


func _draw_cover(title: String, subtitle: String) -> void:
	var r := _overlay_rect()
	_draw_panel(r)  # tapa la grilla: pausar no sirve para pensar
	_text(font_ui, title, r.get_center() + Vector2(0, -6.0 * px), 26.0 * px, c("texto"))
	_text(font_ui, subtitle, r.get_center() + Vector2(0, 26.0 * px), 14.0 * px, c("texto_suave"))


func _draw_result() -> void:
	var r := _overlay_rect()
	_draw_panel(r)
	var cx := r.get_center().x
	_text(font_ui, "TIME'S UP", Vector2(cx, r.position.y + r.size.y * 0.17), 15.0 * px, c("texto_suave"))
	_text(font_num, _fmt_score(round_.score), Vector2(cx, r.position.y + r.size.y * 0.36), 44.0 * px, c("justo") if new_best else c("texto"))
	if new_best:
		_text(font_ui, "NEW BEST!", Vector2(cx, r.position.y + r.size.y * 0.46), 15.0 * px, c("justo"))
	else:
		_text(font_ui, "Best: " + _fmt_score(best_score), Vector2(cx, r.position.y + r.size.y * 0.46), 14.0 * px, c("texto_suave"))
	_text(font_ui, "Chains: %d   Longest: %d" % [round_.chains, round_.best_chain], Vector2(cx, r.position.y + r.size.y * 0.58), 14.0 * px, c("texto"))
	_draw_button("PLAY AGAIN")


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
