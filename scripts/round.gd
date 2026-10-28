class_name Round
extends RefCounted
## Reglas de una partida de Sum 32 (GDD, sección Puntaje), sin dibujo ni input.
## Todo en enteros y milisegundos: el servidor de H2 repite esta cuenta con la
## lista de jugadas para validar el puntaje.

var board: Board
var limit_ms: int          # duración actual, crece con el tiempo extra
var elapsed_ms: int = 0
var score: int = 0
var chains: int = 0
var best_chain: int = 0
var combo_tenths: int = 10  # x1 = 10, x1,5 = 15
var last_clear_ms: int = -1
var moves: Array = []       # [{"cells": [...], "t": ms}], para el servidor

var points_factor: int
var combo_window_ms: int
var combo_step: int
var combo_max: int
var long_len: int
var long_bonus_ms: int


func _init(config: Dictionary, p_board: Board) -> void:
	board = p_board
	limit_ms = int(config.get("round_seconds", 60)) * 1000
	points_factor = int(config.get("points_factor", 10))
	combo_window_ms = int(config.get("combo_window_s", 3)) * 1000
	combo_step = int(config.get("combo_step_tenths", 5))
	combo_max = int(config.get("combo_max_tenths", 30))
	long_len = int(config.get("long_chain_len", 6))
	long_bonus_ms = int(config.get("long_chain_bonus_s", 2)) * 1000


func is_over() -> bool:
	return elapsed_ms >= limit_ms


func remaining_ms() -> int:
	return maxi(0, limit_ms - elapsed_ms)


## Avanza el reloj. No pasa del límite.
func advance(ms: int) -> void:
	elapsed_ms = mini(limit_ms, elapsed_ms + maxi(0, ms))


## Combo que tendría una cadena cerrada ahora (para mostrarlo antes de soltar).
func combo_if_closed_now() -> int:
	if last_clear_ms >= 0 and elapsed_ms - last_clear_ms <= combo_window_ms:
		return mini(combo_max, combo_tenths + combo_step)
	return 10


## El combo vigente se corta si pasó la ventana sin cerrar otra cadena.
func current_combo() -> int:
	if last_clear_ms >= 0 and elapsed_ms - last_clear_ms <= combo_window_ms:
		return combo_tenths
	return 10


## Cierra una cadena. Devuelve {} si no vale (inválida o partida terminada); si vale,
## {"points", "combo", "bonus_ms", "fall"}.
func close_chain(chain: PackedInt32Array) -> Dictionary:
	if is_over() or not board.is_valid_chain(chain):
		return {}
	var n := chain.size()
	combo_tenths = combo_if_closed_now()
	var points: int = points_factor * n * n * combo_tenths / 10
	var bonus := long_bonus_ms if n >= long_len else 0
	score += points
	chains += 1
	best_chain = maxi(best_chain, n)
	limit_ms += bonus
	last_clear_ms = elapsed_ms
	moves.append({"cells": Array(chain), "t": elapsed_ms})
	var fall := board.clear_chain(chain)
	return {"points": points, "combo": combo_tenths, "bonus_ms": bonus, "fall": fall}
