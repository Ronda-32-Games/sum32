class_name Board
extends RefCounted
## Lógica pura de la grilla de Sum 32: sin dibujo ni input.
## Es la parte que el servidor va a repetir en JavaScript para validar partidas,
## así que todo es determinista a partir de la semilla.

var size: int
var target: int
var vmin: int
var vmax: int
var seed_value: int

## Valores de la grilla. Índice = fila * size + columna; la fila 0 es la de arriba.
var cells: PackedInt32Array = PackedInt32Array()
## Un generador por columna: lo que cae en una columna no depende del orden de las cadenas.
var column_rngs: Array = []
var shuffle_count: int = 0


func _init(config: Dictionary, p_seed: int) -> void:
	size = int(config.get("grid_size", 6))
	target = int(config.get("target_sum", 32))
	vmin = int(config.get("value_min", 3))
	vmax = int(config.get("value_max", 12))
	seed_value = p_seed & Mulberry32.MASK
	cells.resize(size * size)
	column_rngs.clear()
	for c in size:
		column_rngs.append(Mulberry32.new(Mulberry32.derive(seed_value, c)))
	for c in size:
		for r in size:
			cells[r * size + c] = _next_value(c)
	ensure_playable()


func _next_value(col: int) -> int:
	return (column_rngs[col] as Mulberry32).range_int(vmin, vmax)


func index(r: int, c: int) -> int:
	return r * size + c


func row_of(i: int) -> int:
	return i / size


func col_of(i: int) -> int:
	return i % size


func are_adjacent(a: int, b: int) -> bool:
	var dr: int = absi(row_of(a) - row_of(b))
	var dc: int = absi(col_of(a) - col_of(b))
	return dr + dc == 1


func chain_sum(chain: PackedInt32Array) -> int:
	var s := 0
	for i in chain:
		s += cells[i]
	return s


## Revisa que la cadena sea válida: casillas vecinas, sin repetir y suma exacta.
func is_valid_chain(chain: PackedInt32Array) -> bool:
	if chain.size() < 2:
		return false
	var seen := {}
	for k in chain.size():
		var i: int = chain[k]
		if i < 0 or i >= cells.size() or seen.has(i):
			return false
		seen[i] = true
		if k > 0 and not are_adjacent(chain[k - 1], i):
			return false
	return chain_sum(chain) == target


## Borra la cadena, hace caer las casillas y repone desde arriba.
## Devuelve, por casilla, cuántas filas cayó (para animar). Las nuevas caen desde fuera.
func clear_chain(chain: PackedInt32Array) -> PackedInt32Array:
	var removed := {}
	for i in chain:
		removed[i] = true
	var fall := PackedInt32Array()
	fall.resize(size * size)
	for c in size:
		# Casillas que quedan en la columna, de abajo hacia arriba.
		var kept: Array = []
		for r in range(size - 1, -1, -1):
			var i := index(r, c)
			if not removed.has(i):
				kept.append([cells[i], r])
		var write_r := size - 1
		for item in kept:
			cells[index(write_r, c)] = item[0]
			fall[index(write_r, c)] = write_r - int(item[1])
			write_r -= 1
		# Huecos de arriba: valores nuevos de la secuencia de la columna.
		# El primero que sale ocupa el hueco más bajo.
		var missing := write_r + 1
		while write_r >= 0:
			cells[index(write_r, c)] = _next_value(c)
			fall[index(write_r, c)] = missing
			write_r -= 1
	ensure_playable()
	return fall


## Busca una cadena válida cualquiera. Devuelve una vacía si no hay.
func find_any_chain() -> PackedInt32Array:
	for start in cells.size():
		var path := PackedInt32Array([start])
		var found := _dfs(path, cells[start])
		if found.size() > 0:
			return found
	return PackedInt32Array()


func _dfs(path: PackedInt32Array, total: int) -> PackedInt32Array:
	if total == target and path.size() >= 2:
		return path
	if total >= target:
		return PackedInt32Array()
	var last: int = path[path.size() - 1]
	var r := row_of(last)
	var c := col_of(last)
	for d in [[-1, 0], [1, 0], [0, -1], [0, 1]]:
		var nr: int = r + d[0]
		var nc: int = c + d[1]
		if nr < 0 or nr >= size or nc < 0 or nc >= size:
			continue
		var n := index(nr, nc)
		if path.has(n):
			continue
		var next_path := path.duplicate()
		next_path.append(n)
		var res := _dfs(next_path, total + cells[n])
		if res.size() > 0:
			return res
	return PackedInt32Array()


## Si no hay ninguna cadena posible, mezcla la grilla de forma determinista.
func ensure_playable() -> void:
	var tries := 0
	while find_any_chain().size() == 0 and tries < 20:
		shuffle_count += 1
		tries += 1
		var rng := Mulberry32.new(Mulberry32.derive(seed_value, 1000 + shuffle_count))
		for i in range(cells.size() - 1, 0, -1):
			var j := rng.next_u32() % (i + 1)
			var tmp := cells[i]
			cells[i] = cells[j]
			cells[j] = tmp
