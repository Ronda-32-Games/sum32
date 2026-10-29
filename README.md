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
| `tests/` | Pruebas de reglas, de la vista y de navegador, y vectores para el servidor |
| `server/` | Servidor (H2): Cloudflare Worker + D1. Reglas en JavaScript, firma de Telegram, Daily, partida verificada y ranking diario |

**Modo de prueba (TASK-036).** El jugador común no ve nada de esto. Se activa con parámetros:

| Dónde | Cómo | Ejemplo |
| --- | --- | --- |
| Telegram | `startapp` con palabras separadas por `_` | `t.me/ronda32games_bot/sum32?startapp=test_seed32_round5` |
| Navegador | Parámetros en la dirección | `ronda-32-games.github.io/sum32/?seed=32&round=5` |

- `test`: modo de prueba sin cambiar el juego; muestra el botón **ms** (panel de medición).
- `seed32` o `?seed=32`: la primera grilla sale siempre igual.
- `round5` o `?round=5`: la partida dura 5 segundos.
- `slow10` o `?slow=10`: todo corre 10 veces más lento, para revisar animaciones.
- `cold` o `?cold=1`: fuerza a bajar el motor de internet (medición en frío, también en iPhone).

Cualquiera de estos activa el modo de prueba: aparece la marca TEST en rojo abajo. Con seed, round o slow la partida no guarda récord.

**Pruebas:**

```
godot --headless -s tests/run_tests.gd        # reglas (grilla, generador, partida)
godot --headless -s tests/run_view_tests.gd   # vista: toques, pausa, resultado
python tests/web/test_shell.py build/web      # navegador: página, panel, modo de prueba (necesita la build)
```

Las tres corren en cada publicación; si alguna falla, no se publica.

**Servidor (`server/`).** Rehace cada partida con las mismas reglas que Godot y guarda el puntaje que da él, no el que dice el teléfono. `tests/round_vectors.json` lo escribe Godot y el servidor tiene que dar lo mismo.

```
cd server && npm test    # reglas en JavaScript contra los vectores de Godot y la API con una base local (Node 22)
```

| Endpoint | Qué hace |
| --- | --- |
| `POST /session` | Valida la firma de Telegram, guarda al jugador y devuelve el estado del Daily |
| `GET /daily` | Día (UTC), intentos que quedan y mejor puntaje del día |
| `POST /daily/start` | Gasta un intento y recién ahí da la semilla del día |
| `POST /run` | Recibe las jugadas (parciales o finales), rehace la partida y guarda el puntaje |
| `GET /leaderboard` | Ranking diario: los 50 primeros y tu puesto |
| `DELETE /me` | Borra todo lo de quien pide, en todas las tablas |
| `GET /stats/<informe>.csv` | Planillas para Power BI; solo con `Authorization: Bearer <STATS_TOKEN>` |

Todo pedido salvo `/stats` lleva `Authorization: tma <initData>`. Los secretos `BOT_TOKEN`, `DAILY_SECRET` y `STATS_TOKEN` se cargan en el panel de Cloudflare, nunca acá. 
**Analítica (DEC-053, DEC-054).** Cada partida guarda modo, día, puntaje, cadenas, duración del juego (`duration_ms`), tiempo real (`wall_ms`) y `clean` (1 si el servidor rehizo la partida entera y dio igual). `activity` tiene una fila por jugador y día activo; `events` una por jugador, día y evento, con un contador. Los dos arrancan apagados: se prenden con `EVENTS_ENABLED = "true"` cuando la página de privacidad esté publicada. Informes (`retention`, `funnel`, `retry`, `runs`, `players`; `?from=` y `?to=` acotan por día): salen sin nombres ni números de Telegram, cada jugador es un código de 12 letras. Los días son UTC y la retención día 1 y 7 cuenta quién volvió justo ese día. Para ver cómo salen sin datos reales: `cd server && node scripts/demo.js ../demo-out`, que simula dos semanas con jugadores de mentira.

`.github/workflows/server.yml` corre las pruebas y publica el Worker cuando están las claves de Cloudflare en los secretos del repo.

Los tokens de los bots nunca van a este repo.
