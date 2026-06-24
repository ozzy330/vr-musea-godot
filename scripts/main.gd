@tool
extends Node3D

# Path to the world JSON — used as fallback when the server is unreachable.
@export_file("*.json") var world_json_path: String = "res://world.json"

@export_group("Server")
## Server base URL, e.g. "http://192.168.1.x:8080".
## When set:
##   - world JSON is fetched via HTTP (fallback to local on failure)
##   - asset paths (res://media/…) are remapped to HTTP URLs so lienzo.gd
##     downloads them at runtime instead of reading from res://.
## Leave empty for local-only development (res:// paths, no network).
@export var server_url: String = "":
	set(v):
		server_url = v.rstrip("/")
		update_configuration_warnings()
@export var endpoint_world:   String = "/world"
@export var endpoint_ready:   String = "/client/ready"
@export var endpoint_restart: String = "/client/restart"
@export var media_local_prefix: String = "res://media/"
@export var media_server_path:  String = "/media/"

@export_group("Layout")
@export var hall_scene: PackedScene:
	set(v):
		hall_scene = v
		update_configuration_warnings()
## Fallback cuando el hall no tiene túnel: distancia entre halls en el eje lineal.
@export var hall_spacing: float = 25.0:
	set(v):
		hall_spacing = v
		update_configuration_warnings()
## Fallback cuando el hall no tiene túnel: dirección del layout lineal.
@export var hall_layout_axis: Vector3 = Vector3(-1, 0, 0):
	set(v):
		hall_layout_axis = v
		update_configuration_warnings()

@export_group("Rendering / Quest")
@export var hall_visibility_distance: float = 30.0

var xr_interface: XRInterface
var _halls: Array[Node3D] = []
# Cada entrada: {"node": Node3D, "a": int, "b": int} donde a/b son los índices
# en _halls de los dos halls que el túnel conecta.
var _tunnels: Array = []
var _pending_assets: int = 0
var device_id: String = ""

const RESTART_BUTTON      := "ax_touch"
const RESTART_HOLD_SEC    := 5.0
const RESTART_POLL_SEC    := 5.0

var _restart_held: bool    = false
var _restart_elapsed: float = 0.0
var _restart_poll_t: float  = 0.0



# ── Editor warnings ────────────────────────────────────────────────────────────

func _get_configuration_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if hall_scene == null:
		w.append("hall_scene is required — assign a PackedScene in the Inspector.")
	if hall_spacing <= 0.0:
		w.append("hall_spacing must be greater than 0.")
	if hall_layout_axis == Vector3.ZERO:
		w.append("hall_layout_axis cannot be zero — se usa como fallback cuando el hall no tiene túnel.")
	if not server_url.is_empty() and not server_url.begins_with("http://") and not server_url.begins_with("https://"):
		w.append("server_url must start with http:// or https:// (current value: '%s')." % server_url)
	return w


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	assert(hall_scene != null, "Main: hall_scene is not set — assign it in the Inspector.")
	assert(hall_spacing > 0.0, "Main: hall_spacing must be greater than 0.")
	assert(hall_layout_axis != Vector3.ZERO, "Main: hall_layout_axis cannot be zero.")
	assert(server_url.is_empty() or server_url.begins_with("http://") or server_url.begins_with("https://"),
		"Main: server_url must start with http:// or https:// (current value: '%s')." % server_url)
	_init_device_id()
	_init_xr()
	_connect_controllers()
	$StartXR.xr_ended.connect(_on_xr_ended)
	$StartXR.xr_started.connect(_on_xr_started)
	_register_client()
	_fetch_world()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return

	if _restart_held:
		_restart_elapsed += delta
		if _restart_elapsed >= RESTART_HOLD_SEC:
			_trigger_restart()

	_restart_poll_t += delta
	if _restart_poll_t >= RESTART_POLL_SEC:
		_restart_poll_t = 0.0
		_poll_server_restart()

	if _halls.is_empty():
		return
	var vp := get_viewport()
	if vp == null:
		return
	var cam := vp.get_camera_3d()
	if cam == null:
		return
	var cam_pos := cam.global_position
	for hall in _halls:
		hall.visible = hall.global_position.distance_to(cam_pos) <= hall_visibility_distance
	# Un túnel sigue visible mientras alguno de los dos halls que conecta lo esté,
	# para que no quede un hueco al ocultarse el hall que lo contenía.
	for t in _tunnels:
		var b: int = t["b"]
		t["node"].visible = _halls[t["a"]].visible or (b < _halls.size() and _halls[b].visible)


# ── Controllers ───────────────────────────────────────────────────────────────

func _connect_controllers() -> void:
	for controller in [$Player/LeftHand, $Player/RightHand]:
		controller.button_pressed.connect(_on_button_pressed.bind(controller.name))
		controller.button_released.connect(_on_button_released.bind(controller.name))

func _on_xr_ended() -> void:
	print("XR tracking perdido — física del player pausada")
	var pb := $Player.find_child("XRToolsPlayerBody", true, false)
	if pb:
		pb.set_physics_process(false)


func _on_xr_started() -> void:
	print("XR tracking recuperado — física del player reanudada (velocity reset)")
	var pb := $Player.find_child("XRToolsPlayerBody", true, false)
	if pb:
		(pb as CharacterBody3D).velocity = Vector3.ZERO
		pb.set_physics_process(true)


func _on_button_pressed(button_name: String, controller_name: String) -> void:
	print("button_pressed — controller: %s  button: %s" % [controller_name, button_name])
	if button_name == RESTART_BUTTON:
		_restart_held = true

func _on_button_released(button_name: String, controller_name: String) -> void:
	print("button_released — controller: %s  button: %s" % [controller_name, button_name])
	if button_name == RESTART_BUTTON:
		_restart_held    = false
		_restart_elapsed = 0.0

func _trigger_restart() -> void:
	print("Restarting…")
	get_tree().reload_current_scene.call_deferred()

func _poll_server_restart() -> void:
	if server_url.is_empty():
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_restart_poll_response.bind(http))
	http.request(server_url + endpoint_restart)

func _on_restart_poll_response(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if data is Dictionary and data.get("restart", false):
		_trigger_restart()


# ── Device ID (ANDROID_ID) ────────────────────────────────────────────────────

func _init_device_id() -> void:
	device_id = OS.get_unique_id()
	if device_id.is_empty():
		device_id = "device_%s" % str(hash(OS.get_processor_count()) ^ hash(Time.get_ticks_msec()))
	print("Device ID: %s" % device_id)


func _register_client() -> void:
	if server_url.is_empty():
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r, _c, _h, _b): http.queue_free())
	var body := JSON.stringify({"device_id": device_id})
	http.request(server_url + "/client/register",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		body)


# ── XR ────────────────────────────────────────────────────────────────────────

func _init_xr() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		print("OpenXR initialized successfully")
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		get_viewport().use_xr = true
	else:
		print("OpenXR not initialized, please check if your headset is connected")


# ── World fetching ─────────────────────────────────────────────────────────────

func _fetch_world() -> void:
	if server_url.is_empty():
		_build_world_from_data(_load_json(world_json_path))
		return

	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_world_received.bind(http))
	var err := http.request(server_url + endpoint_world)
	if err != OK:
		push_warning("HTTPRequest failed to start — falling back to local JSON")
		http.queue_free()
		_build_world_from_data(_load_json(world_json_path), false)


func _on_world_received(result: int, response_code: int, _headers: PackedStringArray,
		body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_warning("Server unreachable (result=%d code=%d) — fallback local" % [result, response_code])
		_build_world_from_data(_load_json(world_json_path), false)
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if data == null or not data is Dictionary:
		push_warning("Invalid JSON from server — fallback local")
		_build_world_from_data(_load_json(world_json_path), false)
		return
	print("World loaded from server (%d halls)" % data.get("halls", []).size())
	_build_world_from_data(data, true)


# ── World building ─────────────────────────────────────────────────────────────

## Remaps a single asset dict: media_local_prefix → server_url + media_server_path
func _remap_asset(asset) -> Dictionary:
	if not asset is Dictionary or server_url.is_empty():
		return asset if asset is Dictionary else {}
	var out: Dictionary = asset.duplicate()
	for key in ["imagen", "video", "audio"]:
		if out.has(key) and (out[key] as String).begins_with(media_local_prefix):
			out[key] = (out[key] as String).replace(media_local_prefix, server_url + media_server_path)
	return out


func _remap_slots(slots: Array) -> Array:
	var out: Array = []
	for s in slots:
		var r: Dictionary = s.duplicate()
		if r.has("asset"):
			r["asset"] = _remap_asset(r["asset"])
		out.append(r)
	return out


## Fallback lineal: siguiente posición a hall_spacing metros en hall_layout_axis.
func _linear_next(hall: Node3D) -> Transform3D:
	return Transform3D(hall.global_transform.basis,
		hall.global_transform.origin + hall_layout_axis * hall_spacing)


func _build_world_from_data(world: Dictionary, remap_assets: bool = true) -> void:
	if world.is_empty():
		return

	var halls_list: Array = world.get("halls", [])
	if halls_list.is_empty():
		push_error("RoomManager: 'halls' array is empty or missing")
		return

	var count := halls_list.size()
	# Transform mundial donde debe quedar el door_a del próximo hall.
	var next_entry := Transform3D.IDENTITY

	for i in range(count):
		var data: Dictionary = halls_list[i].duplicate(true)

		# Remap asset paths to HTTP URLs only when data came from the server.
		# Fallback (local world.json) keeps res:// paths so images load from disk.
		if remap_assets and not server_url.is_empty() and data.has("slots"):
			data["slots"] = _remap_slots(data["slots"])

		var hall_id: String = data.get("hallId", "hall_%d" % i)
		var hall: Node3D = hall_scene.instantiate()
		add_child(hall)
		hall.name = hall_id

		# ── Posición del hall ───────────────────────────────────────────────
		# Cada hall (salvo el primero) se ancla al socket_out del túnel anterior
		# replicando la relación validada en test_halls.tscn: rotación 180° en Y
		# y offset de 9 m en X, expresados en el espacio local del socket_out.
		# Se coloca la RAÍZ del hall (no socket_in), igual que en esa escena.
		if i > 0:
			var offset := Transform3D(Basis(Quaternion(Vector3.UP, PI)), Vector3(9, 0, 1.15))
			hall.global_transform = next_entry * offset
		# El primer hall queda en el origen (Transform3D.IDENTITY por defecto).

		# door_in: pared al inicio (primer hall); abierto en todos los demás.
		var state_in: String = "closed" if i == 0 else "open"

		# door_out: open whenever there is a next hall; closed at the dead end.
		var state_out: String
		if i < count - 1:
			state_out = halls_list[i + 1].get("hallId", "hall_%d" % (i + 1))
		else:
			state_out = "closed"

		hall.setup(data, state_out, state_in)
		_halls.append(hall)

		# ── Calcular dónde va el siguiente hall ─────────────────────────────
		# El hall instancia y posiciona su propio túnel en _ready().
		# Solo preguntamos dónde quedó el socket_out para encadenar el siguiente.
		var exit_node: Node3D = hall.get_tunnel_exit() if hall.has_method("get_tunnel_exit") else null
		if exit_node != null:
			next_entry = exit_node.global_transform
		else:
			next_entry = _linear_next(hall)

	# Desacoplar cada túnel de su hall: lo reparentamos a Main conservando su
	# transform mundial. Así su visibilidad no depende del hall que lo contiene
	# y podemos mantenerlo visible mientras cualquiera de los dos halls que
	# conecta lo esté (evita el hueco al ocultarse el hall anterior).
	for i in range(_halls.size()):
		var tnl: Node3D = _halls[i].get("tunnel")
		if tnl == null:
			continue
		tnl.reparent(self, true)
		_tunnels.append({"node": tnl, "a": i, "b": i + 1})

	# Contar lienzos con assets y suscribirse a su señal.
	for hall in _halls:
		for node in hall.find_children("*", "", true, false):
			if node.has_signal("asset_loaded"):
				_pending_assets += 1
				node.asset_loaded.connect(_on_asset_loaded)
	if _pending_assets == 0:
		_on_all_assets_ready()


func _on_asset_loaded(_lienzo: Node3D) -> void:
	_pending_assets -= 1
	if _pending_assets == 0:
		_on_all_assets_ready()


func _on_all_assets_ready() -> void:
	print("Godot: todos los assets cargados")
	if server_url.is_empty():
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r, _c, _h, _b): http.queue_free())
	http.request(server_url + endpoint_ready, [], HTTPClient.METHOD_POST, "")


# ── JSON loader ────────────────────────────────────────────────────────────────

func _load_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("RoomManager: cannot open '%s'" % path)
		return {}
	var result = JSON.parse_string(file.get_as_text())
	if result == null or not result is Dictionary:
		push_error("RoomManager: invalid JSON in '%s'" % path)
		return {}
	return result
