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
