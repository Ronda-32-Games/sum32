extends Control
## Vista y control de H0: dibuja la grilla, maneja el arrastre y habla con la página
## (puente con Telegram y panel de medición). Toda la regla está en Board.

const CONFIG_PATH := "res://data/config.json"

# Colores provisorios hasta la paleta de Lía (TASK-021).
const COL_BG := Color("#15121f")
const COL_CELL := Color("#2a2540")
const COL_CELL_LOW := Color("#2b3550")
const COL_CELL_MID := Color("#2a2540")
const COL_CELL_HIGH := Color("#40284a")
const COL_TEXT := Color("#f3f0ff")
const COL_DIM := Color("#9a93b8")
const COL_CHAIN := Color("#8b5cf6")
const COL_OK := Color("#22c55e")
const COL_OVER := Color("#ef4444")

var config: Dictionary = {}
var board: Board
var font: Font

var chain := PackedInt32Array()
var dragging := false
var last_pointer := Vector2.ZERO
var chains_cleared := 0

# Geometría calculada en _layout().
var grid_origin := Vector2.ZERO
var cell_pitch := 100.0
var cell_size := 92.0
var top_inset := 0.0
## Columna central donde vive todo: en pantallas anchas el juego no se estira.
var col_x := 0.0
var col_w := 720.0

# Animación: desplazamiento vertical pendiente por casilla y destello de borrado.
var fall_offset := PackedFloat32Array()
var flash := {}  # índice -> segundos restantes
var success_pulse := 0.0

var frames := 0
var fps_timer := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)
	font = ThemeDB.fallback_font
	config = _load_config()
	var seed_value := int(Time.get_unix_time_from_system() * 1000.0) & Mulberry32.MASK
	# Para pruebas (Nahir): ?seed=123 en la dirección repite siempre la misma grilla.
	var url_seed = _js("new URLSearchParams(location.search).get('seed') || ''")
	if url_seed is String and (url_seed as String).is_valid_int():
		seed_value = int(url_seed) & Mulberry32.MASK
	board = Board.new(config, seed_value)
	fall_offset.resize(board.size * board.size)
	get_viewport().size_changed.connect(_layout)
	_layout()
	_js("window.r32 && window.r32.onGodotReady()")


func _load_config() -> Dictionary:
	var f := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if f == null:
		push_error("No se pudo abrir " + CONFIG_PATH)
		return {}
	var data = JSON.parse_string(f.get_as_text())
	return data if data is Dictionary else {}


func _js(code: String) -> Variant:
	if OS.has_feature("web"):
		return JavaScriptBridge.eval(code, true)
	return null


func _layout() -> void:
	var view := get_viewport_rect().size
	# Margen superior que pide Telegram (barra y botones), convertido a pixeles del juego.
	top_inset = 0.0
	var css_top = _js("window.r32 ? window.r32.topInsetCss() : 0")
	var css_h = _js("window.innerHeight || 0")
	if css_top != null and css_h != null and float(css_h) > 0.0:
		top_inset = float(css_top) * view.y / float(css_h)
	col_w = minf(view.x, (view.y - top_inset) * 0.6)
	col_x = (view.x - col_w) * 0.5
	var header_h := col_w * 0.42
	var avail_h := view.y - top_inset - header_h - col_w * 0.06
	var grid_w := minf(col_w * 0.9, avail_h)
	cell_pitch = grid_w / board.size
	cell_size = cell_pitch * 0.9
	var extra := maxf(0.0, avail_h - grid_w)
	grid_origin = Vector2((view.x - grid_w) * 0.5, top_inset + header_h + extra * 0.3)
	queue_redraw()


func _process(delta: float) -> void:
	frames += 1
	if frames == 2:
		_js("window.r32 && window.r32.onFirstFrame()")
	fps_timer += delta
	if fps_timer >= 0.5:
		fps_timer = 0.0
		_js("window.r32 && window.r32.reportFps(%d, %s)" % [Engine.get_frames_per_second(), "true" if dragging else "false"])
	var animating := false
	var speed := cell_pitch * 14.0 * delta
	for i in fall_offset.size():
		if fall_offset[i] > 0.0:
			fall_offset[i] = maxf(0.0, fall_offset[i] - speed)
			animating = true
	for k in flash.keys():
		flash[k] -= delta
		if flash[k] <= 0.0:
			flash.erase(k)
		animating = true
	if success_pulse > 0.0:
		success_pulse = maxf(0.0, success_pulse - delta)
		animating = true
	if animating:
		queue_redraw()


# --- Input -------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_begin(event.position)
		else:
			_end()
		accept_event()
	elif event is InputEventMouseMotion and dragging:
		_move(event.position)
		accept_event()


func _begin(pos: Vector2) -> void:
	var i := _cell_at(pos, 0.48)
	if i < 0:
		return
	dragging = true
	chain = PackedInt32Array([i])
	last_pointer = pos
	_haptic("light")
	queue_redraw()


func _move(pos: Vector2) -> void:
	# Recorre el trayecto en pasos chicos para no saltear casillas si el dedo va rápido.
	var dist := last_pointer.distance_to(pos)
	var steps := maxi(1, int(dist / (cell_pitch * 0.2)))
	for s in range(1, steps + 1):
		var p := last_pointer.lerp(pos, float(s) / steps)
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
		_haptic("light")
		queue_redraw()
		return
	if chain.has(i) or not board.are_adjacent(chain[n - 1], i):
		return  # diagonal, salto o casilla vieja: no hace nada
	chain.append(i)
	_haptic("light")
	queue_redraw()


func _end() -> void:
	if not dragging:
		return
	dragging = false
	if board.is_valid_chain(chain):
		for i in chain:
			flash[i] = 0.18
		var fall := board.clear_chain(chain)
		for i in fall.size():
			fall_offset[i] = fall[i] * cell_pitch
		chains_cleared += 1
		success_pulse = 0.35
		_haptic("success")
	chain = PackedInt32Array()
	queue_redraw()


func _haptic(kind: String) -> void:
	_js("window.r32 && window.r32.haptic('%s')" % kind)


func _cell_at(pos: Vector2, radius_ratio: float) -> int:
	var local := pos - grid_origin
	var c := int(floor(local.x / cell_pitch))
	var r := int(floor(local.y / cell_pitch))
	if c < 0 or r < 0 or c >= board.size or r >= board.size:
		return -1
	var center := grid_origin + Vector2((c + 0.5) * cell_pitch, (r + 0.5) * cell_pitch)
	if pos.distance_to(center) > cell_pitch * radius_ratio:
		return -1  # solo cuenta el centro de la casilla: evita diagonales accidentales
	return board.index(r, c)


# --- Dibujo ------------------------------------------------------------------

func _draw() -> void:
	var view := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, view), COL_BG)
	_draw_header(view)
	_draw_grid()
	_draw_chain_line()


func _draw_header(view: Vector2) -> void:
	var cx := col_x + col_w * 0.5
	var y0 := top_inset + col_w * 0.07
	_text_centered("SUM 32 · H0 TEST", Vector2(cx, y0), int(col_w * 0.035), COL_DIM)
	var s := board.chain_sum(chain) if chain.size() > 0 else 0
	var state := "idle"
	if chain.size() > 0:
		state = "ok" if s == board.target else ("over" if s > board.target else "building")
	var box_w := col_w * 0.36
	var box_h := col_w * 0.17
	var box := Rect2(Vector2(cx - box_w * 0.5, y0 + col_w * 0.04), Vector2(box_w, box_h))
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_CELL
	sb.set_corner_radius_all(int(box_h * 0.25))
	# Tres estados que no dependen solo del color: el borde cambia de grosor y la marca de texto.
	match state:
		"ok":
			sb.border_color = COL_OK
			sb.set_border_width_all(int(box_h * 0.09))
		"over":
			sb.border_color = COL_OVER
			sb.set_border_width_all(int(box_h * 0.05))
		_:
			sb.border_color = COL_DIM
			sb.set_border_width_all(2)
	if success_pulse > 0.0:
		sb.bg_color = COL_CELL.lerp(COL_OK, success_pulse * 1.5)
	draw_style_box(sb, box)
	var label := "—" if state == "idle" else str(s)
	if state == "ok":
		label = "32 !"
	elif state == "over":
		label = str(s) + " ×"
	var col := COL_TEXT
	if state == "ok":
		col = COL_OK
	elif state == "over":
		col = COL_OVER
	_text_centered(label, box.get_center() + Vector2(0, box_h * 0.18), int(box_h * 0.55), col)
	_text_centered("Chains: %d" % chains_cleared, Vector2(cx, box.end.y + col_w * 0.07), int(col_w * 0.035), COL_DIM)


func _draw_grid() -> void:
	var font_size := int(cell_size * 0.46)
	for r in board.size:
		for c in board.size:
			var i := board.index(r, c)
			var pos := grid_origin + Vector2(c * cell_pitch, r * cell_pitch - fall_offset[i])
			pos += Vector2.ONE * (cell_pitch - cell_size) * 0.5
			if pos.y < grid_origin.y - cell_pitch * 0.25:
				continue  # todavía cayendo desde fuera de la grilla: no tapa el cartel
			var rect := Rect2(pos, Vector2(cell_size, cell_size))
			var v: int = board.cells[i]
			var sb := StyleBoxFlat.new()
			sb.set_corner_radius_all(int(cell_size * 0.18))
			sb.bg_color = COL_CELL_LOW if v <= 5 else (COL_CELL_MID if v <= 9 else COL_CELL_HIGH)
			if chain.has(i):
				sb.bg_color = COL_CHAIN
				sb.border_color = COL_TEXT
				sb.set_border_width_all(int(cell_size * 0.05))
			if flash.has(i):
				sb.bg_color = COL_OK
			draw_style_box(sb, rect)
			_text_centered(str(v), rect.get_center() + Vector2(0, font_size * 0.36), font_size, COL_TEXT)


func _draw_chain_line() -> void:
	if chain.size() < 2:
		return
	var pts := PackedVector2Array()
	for i in chain:
		pts.append(grid_origin + Vector2((board.col_of(i) + 0.5) * cell_pitch, (board.row_of(i) + 0.5) * cell_pitch))
	var col := COL_TEXT
	col.a = 0.55
	draw_polyline(pts, col, cell_size * 0.08, true)


func _text_centered(text: String, center_baseline: Vector2, size_px: int, color: Color) -> void:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x
	draw_string(font, center_baseline - Vector2(w * 0.5, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px, color)
