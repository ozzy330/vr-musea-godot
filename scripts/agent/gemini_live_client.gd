class_name GeminiLiveClient
extends Node

## Capa WebSocket + protocolo de Gemini Live API (BidiGenerateContent), agnóstica del
## audio de Godot. Solo habla JSON sobre WebSocketPeer y emite señales con bytes PCM.
##
## Protocolo (resumen):
##   1. Al abrir el socket → enviar mensaje "setup" (modelo, modalidad AUDIO, instrucción).
##   2. El server responde "setupComplete" → a partir de ahí se puede mandar audio.
##   3. Mic → "realtimeInput.audio" (PCM16 16 kHz base64), de forma continua (VAD server-side).
##   4. Respuesta → "serverContent.modelTurn.parts[].inlineData" (PCM16 24 kHz base64).
##      "turnComplete" = fin del turno; "interrupted" = el usuario interrumpió (barge-in).

signal session_ready                       # llegó setupComplete: ya se puede enviar audio
signal audio_received(pcm: PackedByteArray) # un chunk de voz del modelo (PCM16 24 kHz mono)
signal turn_complete
signal interrupted
signal error(msg: String)

const HOST := "generativelanguage.googleapis.com"
const PATH := "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

var _socket := WebSocketPeer.new()
var _model := ""
var _system_instruction := ""
var _setup_sent := false
var _session_ready := false
var _was_open := false
var _last_state := -1


func start(api_key: String, model: String, system_instruction: String) -> void:
	_model = model
	_system_instruction = system_instruction
	var url := "wss://%s%s?key=%s" % [HOST, PATH, api_key]
	print("[GeminiLive] conectando a %s (modelo=%s, key=%d chars)" % [HOST, model, api_key.length()])
	var err := _socket.connect_to_url(url)
	if err != OK:
		error.emit("connect_to_url falló: %d" % err)
		set_process(false)


func is_ready() -> bool:
	return _session_ready and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN


## Envía un bloque de mic ya convertido a PCM16 mono @ 16 kHz.
func send_audio_16k(pcm: PackedByteArray) -> void:
	if not is_ready() or pcm.is_empty():
		return
	var msg := {
		"realtimeInput": {
			"audio": {
				"mimeType": "audio/pcm;rate=16000",
				"data": Marshalls.raw_to_base64(pcm),
			}
		}
	}
	_socket.send_text(JSON.stringify(msg))


## Envía un turno de texto del usuario y cierra el turno (fuerza respuesta del modelo).
func send_text_turn(text: String) -> void:
	if not is_ready():
		return
	var msg := {
		"clientContent": {
			"turns": [{"role": "user", "parts": [{"text": text}]}],
			"turnComplete": true,
		}
	}
	_socket.send_text(JSON.stringify(msg))


func close() -> void:
	_socket.close()


func _process(_delta: float) -> void:
	_socket.poll()
	var state := _socket.get_ready_state()
	if state != _last_state:
		_last_state = state
		var names := {0: "CONNECTING", 1: "OPEN", 2: "CLOSING", 3: "CLOSED"}
		print("[GeminiLive] socket → %s" % names.get(state, str(state)))
	match state:
		WebSocketPeer.STATE_OPEN:
			_was_open = true
			if not _setup_sent:
				_send_setup()
				_setup_sent = true
			while _socket.get_available_packet_count() > 0:
				_handle_packet(_socket.get_packet())
		WebSocketPeer.STATE_CLOSED:
			if _was_open:
				_was_open = false
				error.emit("socket cerrado (code=%d): %s" % [
					_socket.get_close_code(), _socket.get_close_reason()])
			set_process(false)


func _send_setup() -> void:
	print("[GeminiLive] enviando setup…")
	var msg := {
		"setup": {
			"model": _model,
			"generationConfig": {"responseModalities": ["AUDIO"]},
			"systemInstruction": {"parts": [{"text": _system_instruction}]},
		}
	}
	_socket.send_text(JSON.stringify(msg))


func _handle_packet(pkt: PackedByteArray) -> void:
	var txt := pkt.get_string_from_utf8()
	var data: Variant = JSON.parse_string(txt)
	if not data is Dictionary:
		print("[GeminiLive] ← (no-dict) %s" % txt.substr(0, 200))
		return

	# Log de estructura (sin volcar el base64 gigante del audio).
	print("[GeminiLive] ← keys=%s" % str((data as Dictionary).keys()))

	if data.has("setupComplete"):
		_session_ready = true
		session_ready.emit()
		return

	if not data.has("serverContent"):
		return
	var sc: Dictionary = data["serverContent"]

	if sc.get("interrupted", false):
		interrupted.emit()

	if sc.has("modelTurn"):
		var n_audio := 0
		for part in sc["modelTurn"].get("parts", []):
			if part is Dictionary and part.has("inlineData"):
				var b64: String = part["inlineData"].get("data", "")
				if b64 != "":
					n_audio += 1
					audio_received.emit(Marshalls.base64_to_raw(b64))
		print("[GeminiLive]   modelTurn: %d parts, %d con audio" % [
			sc["modelTurn"].get("parts", []).size(), n_audio])

	if sc.get("turnComplete", false):
		print("[GeminiLive]   turnComplete")
		turn_complete.emit()
