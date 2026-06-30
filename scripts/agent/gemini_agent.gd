extends Node3D

## Agente virtual con cuerpo (esfera) que escucha el micrófono y responde con voz usando
## Gemini Live API. Es autónomo: al entrar al árbol abre el mic + WebSocket y empieza a
## conversar. Se coloca a mano dentro del hall que se quiera.
##
## Escena esperada (creada a mano en el editor):
##   GeminiAgent (este script)
##   ├── Body      (MeshInstance3D, SphereMesh + StandardMaterial3D con emisión)
##   ├── Voice     (AudioStreamPlayer3D, stream = AudioStreamGenerator @ 24000 Hz)
##   ├── MicSource (AudioStreamPlayer, stream = AudioStreamMicrophone, bus="Capture", autoplay)
##   └── Anim      (AnimationPlayer, vacío por ahora)

# Señales de estado del stream — para enganchar animaciones a futuro sin acoplarlas a Gemini.
signal speaking_started          # llegó el 1er chunk de voz del turno
signal speaking_stopped          # turnComplete o interrupted
signal audio_level(rms: float)   # RMS por chunk reproducido (pulso / lip-sync)

@export_group("Gemini")
## Diagnóstico: al conectar, manda un turno de texto para forzar una respuesta de voz.
## Sirve para verificar que la reproducción funciona aunque el mic falle. Apagar en producción.
@export var debug_text_on_connect := true
## API key. Si la dejás vacía, se usa AgentConfig.GEMINI_API_KEY (agent_config.gd, gitignoreado).
## ⚠️ Si la ponés acá queda guardada en el .tscn de la escena: NO commitees esa escena con la key.
@export var api_key_override: String = ""
## Modelo Live con salida de audio. Confirmar el nombre vigente en la doc de Gemini.
@export var model := "models/gemini-3.1-flash-live-preview"
@export_multiline var system_instruction := \
	"Eres el guía virtual de un museo. Hablas en español, con respuestas breves, " + \
	"cálidas y claras. Ayudas al visitante a entender las obras y el recorrido."

@export_group("Nodos")
## Asignalos en el Inspector. Si quedan vacíos, se buscan por nombre bajo este nodo.
@export var body: MeshInstance3D
@export var voice: AudioStreamPlayer3D
@export var mic_source: AudioStreamPlayer

const CAPTURE_BUS := "Capture"

# Guard de instancia única: solo el primer agente abre sesión Live (evita N sesiones
# simultáneas si la esfera está dentro de un .tscn que se instancia varias veces).
static var _active: Node = null

var _client: GeminiLiveClient
var _capture: AudioEffectCapture
var _playback: AudioStreamGeneratorPlayback
var _out_queue := PackedVector2Array()   # frames de voz pendientes de reproducir
var _mix_rate := 48000
var _speaking := false
var _level := 0.0
var _base_emission := 1.0
var _waiting_permission := false
var _dbg_t := 0.0
var _dbg_mic_frames := 0
var _dbg_sent := 0
var _dbg_rms_max := 0.0


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	# Solo un agente activo a la vez.
	if _active != null and _active != self:
		push_warning("[GeminiAgent] Ya hay un agente activo — este queda inactivo (no abre otra sesión Live).")
		set_process(false)
		return
	_active = self

	print("[GeminiAgent] _ready() — iniciando agente")
	_resolve_nodes()

	var mat := body.get_active_material(0)
	if mat is StandardMaterial3D:
		_base_emission = (mat as StandardMaterial3D).emission_energy_multiplier

	# En Android (Quest), RECORD_AUDIO es permiso "peligroso": hay que pedirlo en runtime.
	# Si no está concedido, esperamos a que el usuario lo acepte antes de abrir el mic.
	if OS.get_name() == "Android" and not _has_record_permission():
		print("[GeminiAgent] solicitando permiso de micrófono (RECORD_AUDIO)…")
		OS.request_permission("RECORD_AUDIO")
		_waiting_permission = true
		return

	_start_session()


## Arranca mic, reproducción y conexión. Se llama una vez que hay permiso de micrófono.
func _start_session() -> void:
	_mix_rate = int(AudioServer.get_mix_rate())
	print("[GeminiAgent] mix_rate=%d Hz  enable_input=%s  input_device=%s" % [
		_mix_rate,
		str(ProjectSettings.get_setting("audio/driver/enable_input", false)),
		AudioServer.input_device])
	_setup_capture_bus()

	voice.play()
	_playback = voice.get_stream_playback() as AudioStreamGeneratorPlayback
	if _playback == null:
		push_error("[GeminiAgent] 'Voice' no tiene un AudioStreamGenerator como Stream — no se podrá oír la voz.")

	# Forzar por código que MicSource capture el micrófono y salga al bus Capture,
	# sin depender de cómo quedó configurado en el editor.
	if not (mic_source.stream is AudioStreamMicrophone):
		print("[GeminiAgent] MicSource.stream no era AudioStreamMicrophone — lo asigno por código")
		mic_source.stream = AudioStreamMicrophone.new()
	mic_source.bus = CAPTURE_BUS
	mic_source.play()
	print("[GeminiAgent] MicSource: stream=%s  bus=%s  playing=%s  autoplay=%s" % [
		mic_source.stream.get_class(), mic_source.bus,
		str(mic_source.playing), str(mic_source.autoplay)])

	var key := api_key_override if not api_key_override.is_empty() else AgentConfig.GEMINI_API_KEY
	if key.is_empty():
		push_error("[GeminiAgent] Sin API key: poné api_key_override en el Inspector o GEMINI_API_KEY en agent_config.gd.")
		return

	_client = GeminiLiveClient.new()
	add_child(_client)
	_client.audio_received.connect(_on_audio_received)
	_client.turn_complete.connect(_on_turn_complete)
	_client.interrupted.connect(_on_interrupted)
	_client.session_ready.connect(_on_session_ready)
	_client.error.connect(func(m: String): push_warning("[GeminiAgent] " + m))
	_client.start(key, model, system_instruction)


func _exit_tree() -> void:
	if _active == self:
		_active = null


func _has_record_permission() -> bool:
	for p in OS.get_granted_permissions():
		if p.ends_with("RECORD_AUDIO"):
			return true
	return false


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return

	# 0) Esperar a que el usuario conceda el permiso de micrófono (Android).
	if _waiting_permission:
		if _has_record_permission():
			_waiting_permission = false
			print("[GeminiAgent] permiso de micrófono concedido — arrancando sesión")
			_start_session()
		return

	# 1) Bombear el mic: leer lo capturado, resamplear a 16 kHz y enviar.
	if _capture and _client:
		var available := _capture.get_frames_available()
		if available > 0:
			var frames := _capture.get_buffer(available)
			var pcm := AudioUtils.frames_to_pcm16_16k(frames, _mix_rate)
			_client.send_audio_16k(pcm)
			_dbg_mic_frames += available
			_dbg_sent += pcm.size()
			_dbg_rms_max = maxf(_dbg_rms_max, AudioUtils.rms_pcm16(pcm))

	# Diagnóstico: una vez por segundo, reportar actividad de mic y estado del cliente.
	_dbg_t += delta
	if _dbg_t >= 1.0:
		_dbg_t = 0.0
		var ready := _client and _client.is_ready()
		print("[GeminiAgent] mic_frames/s=%d  enviados=%d bytes  rms=%.3f  cliente_listo=%s" % [
			_dbg_mic_frames, _dbg_sent, _dbg_rms_max, str(ready)])
		_dbg_mic_frames = 0
		_dbg_sent = 0
		_dbg_rms_max = 0.0

	# 2) Drenar la cola de voz hacia el generador según el espacio disponible.
	if _playback and _out_queue.size() > 0:
		var n := mini(_playback.get_frames_available(), _out_queue.size())
		for i in n:
			_playback.push_frame(_out_queue[i])
		if n > 0:
			_out_queue = _out_queue.slice(n)

	# 3) Feedback visual: el brillo de la esfera sigue el nivel de voz y decae.
	_level = lerpf(_level, 0.0, clampf(delta * 8.0, 0.0, 1.0))
	var mat := body.get_active_material(0)
	if mat is StandardMaterial3D:
		(mat as StandardMaterial3D).emission_energy_multiplier = _base_emission + _level * 4.0


# ── Resolución de nodos ──────────────────────────────────────────────────────────

func _resolve_nodes() -> void:
	if body == null:
		body = get_node_or_null("Body")
	if voice == null:
		voice = get_node_or_null("Voice")
	if mic_source == null:
		mic_source = get_node_or_null("MicSource")
	assert(body != null and voice != null and mic_source != null,
		"[GeminiAgent] Faltan nodos: asignalos en el Inspector o nombralos Body/Voice/MicSource.")


# ── Bus de captura del micrófono ────────────────────────────────────────────────

func _setup_capture_bus() -> void:
	var idx := AudioServer.get_bus_index(CAPTURE_BUS)
	if idx == -1:
		idx = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, CAPTURE_BUS)

	for i in AudioServer.get_bus_effect_count(idx):
		if AudioServer.get_bus_effect(idx, i) is AudioEffectCapture:
			_capture = AudioServer.get_bus_effect(idx, i) as AudioEffectCapture
			break
	if _capture == null:
		_capture = AudioEffectCapture.new()
		AudioServer.add_bus_effect(idx, _capture)

	# Capturar SIN atenuar: ni mute ni volumen bajo. Resulta que mutear corta el efecto en
	# Android, y bajar el volumen del bus puede silenciar lo que el efecto captura (según el
	# orden volumen↔efecto). 0 dB garantiza que la captura reciba la señal completa del mic.
	# (El posible eco se resuelve aparte, sin tocar la captura.)
	AudioServer.set_bus_mute(idx, false)
	AudioServer.set_bus_volume_db(idx, 0.0)
	print("[GeminiAgent] bus '%s' idx=%d efectos=%d  input_devices=%s" % [
		CAPTURE_BUS, idx, AudioServer.get_bus_effect_count(idx),
		str(AudioServer.get_input_device_list())])


# ── Voz entrante de Gemini ───────────────────────────────────────────────────────

func _on_session_ready() -> void:
	print("[GeminiAgent] sesión lista, escuchando…")
	if debug_text_on_connect:
		print("[GeminiAgent] (diagnóstico) mando turno de texto para forzar respuesta de voz")
		_client.send_text_turn("Hola, preséntate en una sola frase como guía del museo.")


func _on_audio_received(pcm: PackedByteArray) -> void:
	if not _speaking:
		_speaking = true
		print("[GeminiAgent] recibiendo voz de Gemini…")
		speaking_started.emit()
	_out_queue.append_array(AudioUtils.pcm16_to_frames(pcm))
	var rms := AudioUtils.rms_pcm16(pcm)
	_level = maxf(_level, rms)
	audio_level.emit(rms)


func _on_turn_complete() -> void:
	print("[GeminiAgent] turno completo")
	if _speaking:
		_speaking = false
		speaking_stopped.emit()


func _on_interrupted() -> void:
	# Barge-in: el visitante interrumpió → descartar lo que quedaba por reproducir.
	_out_queue.clear()
	if _speaking:
		_speaking = false
		speaking_stopped.emit()
