class_name DailyClient
extends RefCounted
## Cliente del Daily (TASK-059, DEC-052): estado del día, empezar un intento, mandar las
## jugadas (a mitad de partida y al final) y traer el ranking diario.
##
## No sabe de pantallas: la vista llama a update() en cada cuadro y lee los campos.
## La conexión es intercambiable: en la web es JsTransport (window.r32.net de la página);
## en las pruebas, una de mentira que responde lo que la prueba quiere.
## Una conexión tiene available() -> bool, request(id, method, path, body) y
## poll(id) -> Dictionary {"status": int, "body": Dictionary} o null si todavía no llegó.

const PARTIAL_EVERY_S := 3.0         # una jugada parcial cada 3 s como mucho
const FINAL_RETRY_S := [1.0, 2.0, 4.0, 8.0]

var transport: Object

# Estado de cada pedido: "", "pending", "ok", "error".
var day_state := ""
var start_state := ""
var run_state := ""      # el envío final
var board_state := ""

var day := {}            # respuesta de GET /daily
var run_id := ""
var seed := 0
var result := {}         # respuesta del POST /run final
var leaderboard := {}    # respuesta de GET /leaderboard
var error := ""          # último error que importa mostrar

var _seq := 0
var _waiting := {}       # id -> tipo de pedido
var _in_flight := false  # hay un /run en camino
var _last_partial_s := -1000.0
var _partial_moves: Array = []
var _queued_partial := false
var _final_moves: Array = []
var _final_wanted := false
var _final_tries := 0
var _retry_at := -1.0
var _now := 0.0


func _init(p_transport: Object = null) -> void:
	transport = p_transport


func available() -> bool:
	return transport != null and transport.available()


func attempts_left() -> int:
	return int(day.get("attempts_left", 0)) if day_state == "ok" else 0


func attempts_allowed() -> int:
	return int(day.get("attempts_allowed", 0))


func best_today() -> int:
	var b = day.get("best")
	return int(b.get("score", 0)) if b is Dictionary else 0


## Milisegundos hasta el próximo Daily, según la última respuesta y el tiempo que pasó.
func resets_in_ms(now_s: float) -> int:
	var at := float(day.get("_at_s", now_s))
	return maxi(0, int(day.get("resets_in_ms", 0)) - int((now_s - at) * 1000.0))


func refresh() -> void:
	if not available() or day_state == "pending":
		return
	day_state = "pending"
	_send("day", "GET", "/daily", null)


func start() -> void:
	if not available() or start_state == "pending":
		return
	start_state = "pending"
	run_id = ""
	result = {}
	run_state = ""
	error = ""
	_final_wanted = false
	_final_tries = 0
	_queued_partial = false
	_last_partial_s = -1000.0
	_send("start", "POST", "/daily/start", {})


func fetch_leaderboard() -> void:
	if not available() or board_state == "pending":
		return
	board_state = "pending"
	_send("board", "GET", "/leaderboard", null)


## Jugadas de la partida en curso. Las parciales salen cada PARTIAL_EVERY_S como mucho
## (si se abandona, queda lo último que llegó); la final siempre sale y se reintenta.
func push_moves(moves: Array, final: bool) -> void:
	if run_id == "":
		return
	if final:
		_final_moves = moves.duplicate(true)
		_final_wanted = true
		run_state = "pending"
		if not _in_flight:
			_send_run(true)
		return
	_partial_moves = moves.duplicate(true)
	if _in_flight or _now - _last_partial_s < PARTIAL_EVERY_S:
		_queued_partial = true
		return
	_send_run(false)


## Lee las respuestas que llegaron y hace los reintentos. now_s: reloj real en segundos.
func update(now_s: float) -> void:
	_now = now_s
	if transport == null:
		return
	for id in _waiting.keys():
		var got = transport.poll(id)
		if got == null:
			continue
		var kind: String = _waiting[id]
		_waiting.erase(id)
		_handle(kind, int(got.get("status", 0)), got.get("body", {}) if got.get("body") is Dictionary else {})
	if _in_flight:
		return
	if _final_wanted and run_state == "pending" and _retry_at >= 0.0 and now_s >= _retry_at:
		_retry_at = -1.0
		_send_run(true)
	elif _queued_partial and not _final_wanted and now_s - _last_partial_s >= PARTIAL_EVERY_S:
		_send_run(false)


func _send_run(final: bool) -> void:
	_in_flight = true
	if final:
		_final_tries += 1
		_send("final", "POST", "/run", {"run_id": run_id, "moves": _final_moves, "final": true})
	else:
		_queued_partial = false
		_last_partial_s = _now
		_send("partial", "POST", "/run", {"run_id": run_id, "moves": _partial_moves, "final": false})


func _send(kind: String, method: String, path: String, body: Variant) -> void:
	_seq += 1
	var id := "%s-%d" % [kind, _seq]
	_waiting[id] = kind
	transport.request(id, method, path, body)


func _handle(kind: String, status: int, body: Dictionary) -> void:
	var ok := status >= 200 and status < 300
	match kind:
		"day":
			day_state = "ok" if ok else "error"
			if ok:
				day = body
				day["_at_s"] = _now
		"start":
			if ok:
				start_state = "ok"
				run_id = str(body.get("run_id", ""))
				seed = int(body.get("seed", 0))
				day["attempts_left"] = int(body.get("attempts_left", 0))
				day["attempts_used"] = int(day.get("attempts_used", 0)) + 1
			else:
				start_state = "error"
				error = str(body.get("error", "network"))
				if error == "no_attempts":
					day["attempts_left"] = 0
		"board":
			board_state = "ok" if ok else "error"
			if ok:
				leaderboard = body
		"partial":
			_in_flight = false
			if status == 422 or status == 409 or status == 410:
				# La partida quedó rechazada o cerrada: la final va a decir lo mismo.
				error = str(body.get("error", "rejected"))
			if _final_wanted:
				_send_run(true)
		"final":
			_in_flight = false
			if ok:
				run_state = "ok"
				result = body
				_final_wanted = false
				if result.get("day_best") != null:
					var b = day.get("best")
					var best := int(b.get("score", 0)) if b is Dictionary else 0
					day["best"] = {"score": maxi(best, int(result["day_best"]))}
			elif (status == 0 or status >= 500) and _final_tries <= FINAL_RETRY_S.size():
				_retry_at = _now + float(FINAL_RETRY_S[_final_tries - 1])
			else:
				run_state = "error"
				_final_wanted = false
				error = str(body.get("error", "network"))
