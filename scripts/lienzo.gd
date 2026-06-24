@tool
extends Node3D

@export var imagen: Texture2D
@export var video:  VideoStream
@export var audio:  AudioStream

@export var title_label: Label3D

@export_group("Slot")
## Índice de pared (0-based) al que pertenece este lienzo.
@export_range(0, 1) var wall: int = 0
## Índice de posición (0-based) dentro de la pared.
@export_range(0, 2) var slot: int = 0

@export_group("Tamaño")
## Ancho del cuadro en metros.
@export_range(0.1, 10.0, 0.01, "suffix:m") var ancho: float = 1.865:
	set(v):
		ancho = v
		_apply_size()
## Alto del cuadro en metros.
@export_range(0.1, 10.0, 0.01, "suffix:m") var alto: float = 1.582:
	set(v):
		alto = v
		_apply_size()

signal asset_loaded

var _area: Area3D            = null
var _video_with_audio: bool = true   # false → VideoStreamPlayer muteado, AudioStreamPlayer3D activo
var _tmp_video_path:   String = ""   # user:// path of a cached HTTP video; cleaned on exit


# ── Editor warnings ────────────────────────────────────────────────────────────

func _get_configuration_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	var area := get_node_or_null("Area3D")
	if area == null:
		w.append("Needs an Area3D child to detect proximity (add one and adjust its CollisionShape3D here).")
	elif area.get_node_or_null("CollisionShape3D") == null:
		w.append("The Area3D child needs a CollisionShape3D child to define the trigger zone.")
	return w


# ── Title label ───────────────────────────────────────────────────────────────

func _create_title_label() -> void:
	if title_label:
		return
	var existing := get_node_or_null("TitleLabel")
	if existing is Label3D:
		title_label = existing as Label3D
		return
	var lbl := Label3D.new()
	lbl.name = "TitleLabel"
	lbl.pixel_size = 0.001
	lbl.font_size  = 80
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.billboard  = BaseMaterial3D.BILLBOARD_DISABLED
	lbl.position   = Vector3(0.0, -alto / 2.0 - 0.12, 0.01)
	add_child(lbl)
	title_label = lbl


# ── Size ───────────────────────────────────────────────────────────────────────

func _apply_size() -> void:
	var mi: MeshInstance3D = get_node_or_null("MeshInstance3D")
	if mi == null or not mi.mesh is QuadMesh:
		return
	var q: QuadMesh = mi.mesh.duplicate()
	q.size = Vector2(ancho, alto)
	mi.mesh = q
	mi.scale = Vector3.ONE


# ── Runtime ────────────────────────────────────────────────────────────────────

func _ready() -> void:
	child_entered_tree.connect(func(_n): update_configuration_warnings())
	child_exiting_tree.connect(func(_n): update_configuration_warnings())
	_apply_size()
	_create_title_label()

	if Engine.is_editor_hint():
		return

	$VideoStreamPlayer.visible = false

	_area = get_node_or_null("Area3D")
	if _area == null:
		push_warning("Lienzo '%s': no Area3D child found — proximity trigger disabled." % name)
	else:
		_area.body_entered.connect(_on_body_entered)
		_area.body_exited.connect(_on_body_exited)

	_setup_content()


func _exit_tree() -> void:
	# Clean up temp video cached to user:// (Quest local storage).
	if not _tmp_video_path.is_empty() and FileAccess.file_exists(_tmp_video_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_tmp_video_path))


# ── Content loading ────────────────────────────────────────────────────────────

## Carga imagen, video y/o audio desde un dict {imagen, video, audio, video_with_audio}.
## Acepta paths res:// (síncrono) o http:// (async via HTTPRequest).
## video_with_audio (bool, default true):
##   true  → VideoStreamPlayer suena normal, campo "audio" ignorado.
##   false → VideoStreamPlayer muteado, AudioStreamPlayer3D carga "audio" si existe.
func load_asset(asset: Dictionary, title: String = "") -> void:
	if title_label:
		title_label.text = title
	if asset.is_empty():
		return
	var video_path:  String = asset.get("video",            "")
	var imagen_path: String = asset.get("imagen",           "")
	var audio_path:  String = asset.get("audio",            "")
	_video_with_audio        = asset.get("video_with_audio", true)

	# needs_audio: true when a separate audio track is requested
	#   (image slot always yes; video slot only when video_with_audio = false)
	var needs_audio: bool = not audio_path.is_empty() \
		and (video_path.is_empty() or not _video_with_audio)

	if not video_path.is_empty():
		imagen = null
		if _is_http(video_path):
			_load_video_http(video_path)
		else:
			video = load(video_path)
			_setup_content()
			asset_loaded.emit.call_deferred(self)
	elif not imagen_path.is_empty():
		video = null
		if _is_http(imagen_path):
			_load_imagen_http(imagen_path)
		else:
			imagen = load(imagen_path)
			_setup_content()
			asset_loaded.emit.call_deferred(self)

	if needs_audio:
		if _is_http(audio_path):
			_load_audio_http(audio_path)
		else:
			audio = load(audio_path)
			# _setup_content already applied; just update the stream directly.
			if not Engine.is_editor_hint():
				$AudioStreamPlayer3D.stream = audio
	else:
		audio = null
		if not Engine.is_editor_hint():
			$AudioStreamPlayer3D.stream = null


# ── HTTP helpers ───────────────────────────────────────────────────────────────

static func _is_http(path: String) -> bool:
	return path.begins_with("http://") or path.begins_with("https://")


## Generic HTTP GET. Calls callback(body: PackedByteArray) on success.
func _http_get(url: String, callback: Callable) -> void:
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(
		func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
			http.queue_free()
			if result == HTTPRequest.RESULT_SUCCESS and code == 200:
				callback.call(body)
			else:
				push_warning("Lienzo '%s': HTTP failed for URL (result=%d code=%d)" % [name, result, code])
	)
	if http.request(url) != OK:
		push_warning("Lienzo '%s': could not start HTTPRequest for %s" % [name, url])
		http.queue_free()


func _load_imagen_http(url: String) -> void:
	_http_get(url, func(body: PackedByteArray) -> void:
		var img := Image.new()
		# Try JPG, then PNG (covers both common formats from the server).
		if img.load_jpg_from_buffer(body) != OK:
			if img.load_png_from_buffer(body) != OK:
				push_warning("Lienzo '%s': could not decode image from %s" % [name, url])
				asset_loaded.emit(self)
				return
		imagen = ImageTexture.create_from_image(img)
		_setup_content()
		asset_loaded.emit(self)
	)


func _load_audio_http(url: String) -> void:
	_http_get(url, func(body: PackedByteArray) -> void:
		audio = AudioStreamOggVorbis.load_from_buffer(body)
		if audio == null:
			push_warning("Lienzo '%s': could not decode OGG from %s" % [name, url])
			return
		$AudioStreamPlayer3D.stream = audio
	)


func _load_video_http(url: String) -> void:
	# VideoStreamPlayer requires a file path — download to user:// cache.
	_tmp_video_path = "user://tmp_video_%s.ogv" % url.md5_text()
	_http_get(url, func(body: PackedByteArray) -> void:
		var f := FileAccess.open(_tmp_video_path, FileAccess.WRITE)
		if f == null:
			push_warning("Lienzo '%s': cannot write temp video to %s" % [name, _tmp_video_path])
			asset_loaded.emit(self)
			return
		f.store_buffer(body)
		f.close()
		video = load(_tmp_video_path)
		_setup_content()
		asset_loaded.emit(self)
	)


# ── Display ────────────────────────────────────────────────────────────────────

func _setup_content() -> void:
	if Engine.is_editor_hint():
		return
	if video:
		$VideoStreamPlayer.stream = video
		$VideoStreamPlayer.play()
		$VideoStreamPlayer.paused = true
		$VideoStreamPlayer.volume = 1.0 if _video_with_audio else 0.0
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = $VideoStreamPlayer.get_video_texture()
		$MeshInstance3D.material_override = mat
	elif imagen:
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = imagen
		$MeshInstance3D.material_override = mat
	if audio:
		$AudioStreamPlayer3D.stream = audio


func _on_body_entered(body) -> void:
	if not (body.collision_layer & 2):
		return
	if video:
		$VideoStreamPlayer.paused = false
	if audio:
		$AudioStreamPlayer3D.play()


func _on_body_exited(body) -> void:
	if not (body.collision_layer & 2):
		return
	if video:
		$VideoStreamPlayer.stop()
		$VideoStreamPlayer.play()
		$VideoStreamPlayer.paused = true
	$AudioStreamPlayer3D.stop()
