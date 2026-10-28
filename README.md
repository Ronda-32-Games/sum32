# Sum 32

Link numbers that add up to 32. A quick competitive game for Telegram by Ronda 32.

Play (when published): https://t.me/ronda32games_bot/sum32

## Para el equipo

- **Motor:** Godot 4.7.2, export web sin hilos, renderer Compatibility.
- **Estado:** H1, núcleo jugable en modo Practice: partida de 60 s, puntaje 10 × n², combo de 3 s hasta x3, tiempo extra en cadenas de 6+, pausa con la grilla tapada, resultado y récord en el dispositivo. Arte y sonido v1 de Lía. Todavía sin servidor (H2).
- **Publicación:** cada cambio en `main` corre las pruebas, exporta y publica en https://ronda-32-games.github.io/sum32/ (`.github/workflows/deploy.yml`).

| Carpeta | Qué tiene |
| --- | --- |
| `scripts/rng.gd` | Generador mulberry32 de 32 bits (DEC-031); igual que en JavaScript |
| `scripts/board.gd` | Reglas de la grilla, sin dibujo; es lo que el servidor va a repetir |
| `scripts/round.gd` | Reglas de la partida: reloj, puntaje, combo, tiempo extra y registro de jugadas |
| `assets/` | Arte y sonido de Lía (ver `assets/LEEME.md`) |
| `scripts/game_view.gd` | Dibujo, arrastre y puente con la página |
| `data/config.json` | Parámetros de balance del GDD; se tocan acá, no en el código |
| `web/shell.html` | Página de arranque: Telegram, pantalla de carga y panel de medición |
| `tests/` | Pruebas (`godot --headless -s tests/run_tests.gd`) y vectores para el servidor |

**Para probar:** el botón **ms** abajo a la izquierda abre el panel de medición. Parámetros al final de la dirección, combinables con `&`:

- `?seed=32`: la primera grilla sale siempre igual.
- `?round=5`: la partida dura 5 segundos.
- `?slow=10`: todo corre 10 veces más lento, para revisar animaciones.

Los tokens de los bots nunca van a este repo.
