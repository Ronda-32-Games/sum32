extends SceneTree
## Pruebas de H0. Se corren con:
##   godot --headless -s tests/run_tests.gd
## Revisa que el generador coincida con la referencia de JavaScript y que la grilla
## cumpla las reglas. Escribe tests/board_vectors.json para el servidor de H2.

var failures := 0


func _init() -> void:
	_test_rng()
	_test_board_rules()
	_test_playable_many_seeds()
	_test_round()
	_write_vectors()
	print("RESULT: ", "OK" if failures == 0 else "%d FAILURES" % failures)
	quit(1 if failures > 0 else 0)


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		print("FAIL: ", msg)


func _config() -> Dictionary:
	var f := FileAccess.open("res://data/config.json", FileAccess.READ)
	return JSON.parse_string(f.get_as_text())


func _test_rng() -> void:
	var f := FileAccess.open("res://tests/rng_expected.json", FileAccess.READ)
	var exp: Dictionary = JSON.parse_string(f.get_as_text())
	for seed_str in exp["mulberry32"].keys():
		var g := Mulberry32.new(int(seed_str))
		for v in exp["mulberry32"][seed_str]:
			var got := g.next_u32()
			check(got == int(v), "mulberry32(%s): esperado %d, salió %d" % [seed_str, int(v), got])
	for row in exp["derive"]:
		var got := Mulberry32.derive(int(row[0]), int(row[1]))
		check(got == int(row[2]), "derive(%s,%s): esperado %d, salió %d" % [row[0], row[1], int(row[2]), got])
	print("rng: listo")


func _test_board_rules() -> void:
	var cfg := _config()
	var a := Board.new(cfg, 32)
	var b := Board.new(cfg, 32)
	check(a.cells == b.cells, "misma semilla, misma grilla")
	for v in a.cells:
		check(v >= 3 and v <= 12, "valor fuera de rango: %d" % v)
	var chain := a.find_any_chain()
	check(chain.size() >= 2, "hay al menos una cadena")
	check(a.is_valid_chain(chain), "la cadena encontrada es válida")
	check(not a.is_valid_chain(PackedInt32Array([0])), "una sola casilla no vale")
	check(not a.is_valid_chain(PackedInt32Array([0, 7])), "diagonal no vale")
	check(not a.is_valid_chain(PackedInt32Array([0, 1, 0])), "repetir casilla no vale")
	var before := a.cells.size()
	a.clear_chain(chain)
	check(a.cells.size() == before, "la grilla mantiene el tamaño")
	for v in a.cells:
		check(v >= 3 and v <= 12, "valor repuesto fuera de rango: %d" % v)
	# Lo que cae en una columna no depende del orden en que se borran las cadenas.
	var c1 := Board.new(cfg, 77)
	var c2 := Board.new(cfg, 77)
	var x := c1.find_any_chain()
	c1.clear_chain(x)
	var y := c1.find_any_chain()
	c1.clear_chain(y)
	c2.clear_chain(x)
	var y2 := c2.find_any_chain()
	c2.clear_chain(y2)
	check(y == y2 and c1.cells == c2.cells, "reproducible jugando lo mismo")
	print("board: listo")


func _test_playable_many_seeds() -> void:
	var cfg := _config()
	var shuffles := 0
	for s in 300:
		var bd := Board.new(cfg, s * 7919 + 1)
		check(bd.find_any_chain().size() > 0, "semilla %d sin jugadas" % s)
		shuffles += bd.shuffle_count
		for k in 10:
			var ch := bd.find_any_chain()
			if ch.size() == 0:
				check(false, "semilla %d trabada tras %d cadenas" % [s, k])
				break
			bd.clear_chain(ch)
	print("playable: 300 semillas x 10 cadenas, mezclas totales: ", shuffles)


func _test_round() -> void:
	var cfg := _config()
	var bd := Board.new(cfg, 32)
	var rd := Round.new(cfg, bd)
	check(rd.remaining_ms() == 60000, "la partida dura 60 s")
	# Puntaje: 10 x n^2 con combo x1.
	var ch := bd.find_any_chain()
	var n := ch.size()
	var r1 := rd.close_chain(ch)
	check(r1.get("points", -1) == 10 * n * n, "puntaje 10 x n^2 (n=%d)" % n)
	check(r1.get("combo", 0) == 10, "primera cadena con combo x1")
	# Combo: dentro de 3 s sube 0,5 por cadena hasta x3.
	var expected := [15, 20, 25, 30, 30]
	for k in expected.size():
		rd.advance(2000)
		var c2 := bd.find_any_chain()
		var m := c2.size()
		var r := rd.close_chain(c2)
		check(r.get("combo", 0) == expected[k], "combo esperado x%.1f" % (expected[k] / 10.0))
		check(r.get("points", -1) == 10 * m * m * expected[k] / 10, "puntaje con combo")
	# Pasados más de 3 s, vuelve a x1.
	rd.advance(3001)
	check(rd.current_combo() == 10, "el combo se corta a los 3 s")
	var r3 := rd.close_chain(bd.find_any_chain())
	check(r3.get("combo", 0) == 10, "después de cortarse, vuelve a x1")
	# Cadena inválida no cuenta.
	check(rd.close_chain(PackedInt32Array([0, 7])).is_empty(), "cadena inválida no puntúa")
	# Tiempo extra: cadena de 6 o más suma 2 s.
	var found := false
	for s in 400:
		var b2 := Board.new(cfg, 5000 + s)
		var long := _find_chain_min_len(b2, 6)
		if long.size() >= 6:
			var r2 := Round.new(cfg, b2)
			r2.advance(59900)
			var res := r2.close_chain(long)
			check(res.get("bonus_ms", 0) == 2000, "cadena de 6+ suma 2 s, aun a 0,1 s del final")
			check(r2.remaining_ms() == 2100, "quedan 2,1 s después del bonus")
			found = true
			break
	check(found, "se encontró una cadena de 6+ para probar el tiempo extra")
	# Terminada la partida, nada cuenta.
	var b3 := Board.new(cfg, 9)
	var r4 := Round.new(cfg, b3)
	r4.advance(60000)
	check(r4.is_over(), "a los 60 s termina")
	check(r4.close_chain(b3.find_any_chain()).is_empty(), "cadena después del final no cuenta")
	check(r4.moves.size() == 0, "sin jugadas registradas al final")
	print("round: listo")


## Busca una cadena válida de al menos min_len casillas (para probar el tiempo extra).
func _find_chain_min_len(bd: Board, min_len: int) -> PackedInt32Array:
	for start in bd.cells.size():
		var res := _dfs_len(bd, PackedInt32Array([start]), bd.cells[start], min_len)
		if res.size() > 0:
			return res
	return PackedInt32Array()


func _dfs_len(bd: Board, path: PackedInt32Array, total: int, min_len: int) -> PackedInt32Array:
	if total == bd.target:
		return path if path.size() >= min_len else PackedInt32Array()
	if total > bd.target:
		return PackedInt32Array()
	var last: int = path[path.size() - 1]
	for d in [-bd.size, bd.size, -1, 1]:
		var nxt: int = last + d
		if nxt < 0 or nxt >= bd.cells.size() or path.has(nxt):
			continue
		if (d == -1 or d == 1) and bd.row_of(nxt) != bd.row_of(last):
			continue
		var p2 := path.duplicate()
		p2.append(nxt)
		var res := _dfs_len(bd, p2, total + bd.cells[nxt], min_len)
		if res.size() > 0:
			return res
	return PackedInt32Array()


func _write_vectors() -> void:
	var cfg := _config()
	var out := []
	for s in [0, 1, 32, 2026, 123456789]:
		var bd := Board.new(cfg, s)
		var entry := {"seed": s, "grid": Array(bd.cells), "moves": []}
		for k in 3:
			var ch := bd.find_any_chain()
			bd.clear_chain(ch)
			entry["moves"].append({"chain": Array(ch), "grid_after": Array(bd.cells)})
		out.append(entry)
	var f := FileAccess.open("res://tests/board_vectors.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(out, " "))
	print("vectores: tests/board_vectors.json")
