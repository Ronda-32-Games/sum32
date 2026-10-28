class_name Mulberry32
extends RefCounted
## Generador pseudoaleatorio de 32 bits (mulberry32), DEC-031.
## Tiene que dar exactamente los mismos números que la versión en JavaScript
## del servidor. Por eso no usa el aleatorio de Godot y trabaja con enteros
## enmascarados a 32 bits.

const MASK := 0xFFFFFFFF

var state: int = 0


func _init(seed_value: int = 0) -> void:
	state = seed_value & MASK


## Multiplicación de 32 bits como Math.imul de JavaScript (sin desbordar int64).
static func imul(a: int, b: int) -> int:
	a &= MASK
	b &= MASK
	var lo := a * (b & 0xFFFF)
	var hi := ((a * (b >> 16)) & 0xFFFF) << 16
	return (lo + hi) & MASK


## Siguiente número entero sin signo de 32 bits.
func next_u32() -> int:
	state = (state + 0x6D2B79F5) & MASK
	var t := imul(state ^ (state >> 15), 1 | state)
	t = ((t + imul(t ^ (t >> 7), 61 | t)) & MASK) ^ t
	return (t ^ (t >> 14)) & MASK


## Entero entre lo y hi, ambos incluidos.
func range_int(lo: int, hi: int) -> int:
	return lo + (next_u32() % (hi - lo + 1))


## Mezcla una semilla con un número (por ejemplo, la columna) para derivar otra semilla.
static func derive(seed_value: int, salt: int) -> int:
	var h := (seed_value ^ imul(salt + 1, 0x9E3779B1)) & MASK
	h = imul(h ^ (h >> 16), 0x85EBCA6B)
	h = imul(h ^ (h >> 13), 0xC2B2AE35)
	return (h ^ (h >> 16)) & MASK
