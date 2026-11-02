class_name JsTransport
extends RefCounted
## Conexión del Daily en la web: usa window.r32.net de la página (web/shell.html), que hace
## los fetch con la firma de Telegram. JavaScriptBridge no espera promesas, así que la
## página guarda cada respuesta y Godot la pregunta en cada cuadro (poll).


func available() -> bool:
	if not OS.has_feature("web"):
		return false
	var v = JavaScriptBridge.eval("!!(window.r32 && window.r32.net && window.r32.net.available)", true)
	return v != null and bool(v)


func request(id: String, method: String, path: String, body: Variant) -> void:
	var b := "null" if body == null else JSON.stringify(body)
	JavaScriptBridge.eval("window.r32.net.request(%s, %s, %s, %s)" % [JSON.stringify(id), JSON.stringify(method), JSON.stringify(path), b], true)


func poll(id: String) -> Variant:
	var raw = JavaScriptBridge.eval("window.r32.net.poll(%s)" % JSON.stringify(id), true)
	if not (raw is String):
		return null
	var parsed = JSON.parse_string(raw)
	return parsed if parsed is Dictionary else {"status": 0, "body": {"error": "bad_reply"}}
