"""Referencia de mulberry32 escrita como en JavaScript (Math.imul, >>> 0).
Genera los valores esperados que la prueba de Godot tiene que reproducir."""
import json, sys

M = 0xFFFFFFFF

def imul(a, b):
    return (a * b) & M

def mulberry32(seed):
    state = seed & M
    while True:
        state = (state + 0x6D2B79F5) & M
        t = imul(state ^ (state >> 15), 1 | state)
        t = ((t + imul(t ^ (t >> 7), 61 | t)) & M) ^ t
        yield (t ^ (t >> 14)) & M

def derive(seed, salt):
    h = (seed ^ imul(salt + 1, 0x9E3779B1)) & M
    h = imul(h ^ (h >> 16), 0x85EBCA6B)
    h = imul(h ^ (h >> 13), 0xC2B2AE35)
    return (h ^ (h >> 16)) & M

out = {"mulberry32": {}, "derive": []}
for seed in [0, 1, 32, 123456789, 0xFFFFFFFF]:
    g = mulberry32(seed)
    out["mulberry32"][str(seed)] = [next(g) for _ in range(8)]
for seed, salt in [(0, 0), (32, 5), (123456789, 1000), (0xFFFFFFFF, 3)]:
    out["derive"].append([seed, salt, derive(seed, salt)])
json.dump(out, sys.stdout, indent=1)
