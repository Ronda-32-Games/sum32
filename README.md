# Sum 32

Link numbers that add up to 32. A quick competitive game for Telegram by Ronda 32.

Play (when published): https://t.me/ronda32games_bot/sum32

## Para el equipo

- **Motor:** Godot 4.7.2, export web sin hilos, renderer Compatibility.
- **Estado:** H0, prueba de carga (DEC-030). Grilla, arrastre, suma en vivo, borrado en 32 y caída. Sin puntaje, reloj ni servidor.
- **Publicación:** cada cambio en `main` corre las pruebas, exporta y publica en https://ronda-32-games.github.io/sum32/ (`.github/workflows/deploy.yml`).

| Carpeta | Qué tiene |
| --- | --- |
| `scripts/rng.gd` | Generador mulberry32 de 32 bits (DEC-031); igual que en JavaScript |
| `scripts/board.gd` | Reglas de la grilla, sin dibujo; es lo que el servidor va a repetir |
| `scripts/game_view.gd` | Dibujo, arrastre y puente con la página |
| `data/config.json` | Parámetros de balance del GDD; se tocan acá, no en el código |
| `web/shell.html` | Página de arranque: Telegram, pantalla de carga y panel de medición |
| `tests/` | Pruebas (`godot --headless -s tests/run_tests.gd`) y vectores para el servidor |

**Para probar:** el botón **ms** abajo a la izquierda abre el panel de medición. Con `?seed=32` al final de la dirección, la grilla se repite siempre igual.

Los tokens de los bots nunca van a este repo.
