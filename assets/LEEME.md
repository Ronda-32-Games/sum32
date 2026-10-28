# Sum 32 · arte y sonido v1 (Lía, 27/10/2026)

Paquete para que Bruno integre en el repo `sum32`. Todo es propio o con licencia libre.

| Carpeta | Qué hay | Peso | Límite de Bruno |
| --- | --- | --- | --- |
| casillas/ | 5 estados en SVG y una hoja PNG 1280x256 (cada estado 256x256, en orden normal, cadena, justo, pasado, saliendo). Sin número: el número lo dibuja Godot con la fuente | 31 KB (PNG) | 200 KB |
| fuentes/ | MartianMono-Bold-Sum32.ttf (cifras y símbolos del juego) y MartianMono-Medium-UI.ttf (textos de interfaz), con OFL.txt | 23 KB | 1 fuente, 2 pesos |
| efectos/ | particula_32 y anillo_256, en blanco para teñir con modulate | 7 KB | 150 KB |
| sonidos/ | 10 efectos y 1 loop de música, OGG mono 22,05 kHz, con sonidos.json (cuándo suena y volumen) y synth.py (cómo se generaron) | 88 KB | 300 KB |
| paleta.json | Colores con nombre por uso | 1 KB | — |
| preview/ | Hoja de dirección visual, solo referencia, no va a la build | — | — |

Fondo: color liso Tinta (#151A2D), 0 KB.

## Licencias
- Martian Mono: SIL Open Font License 1.1, The Martian Mono Project Authors. Subconjuntos de la fuente original; uso comercial permitido; OFL.txt viaja con los archivos.
- Casillas, efectos, avatar y sonidos: hechos por Ronda 32, CC0 1.0.
