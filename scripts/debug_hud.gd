extends CanvasLayer

@export var fps_label: Label
@export var ip_label: Label
@export var url_label: Label
@export var device_id_label: Label
@export var poll_timer: Timer
@export var http: HTTPRequest

@export var show_on_start: bool = true

var _server_url: String = ""
var _polling: bool = false


func _ready() -> void:
	visible = show_on_start
	var main := get_tree().get_root().get_node_or_null("Main")
	if main and "server_url" in main:
		_server_url = main.server_url

	var addrs: Array = IP.get_local_addresses()
	var all_local: Array = addrs.filter(func(a: String) -> bool:
		return not a.begins_with("127.") and a != "::1" and not a.begins_with("fe80")
	)
	var ipv4: Array = all_local.filter(func(a: String) -> bool: return "." in a)
	var chosen: Array = ipv4 if not ipv4.is_empty() else all_local
	if ip_label:
		ip_label.text = "IP:  " + (chosen[0] if not chosen.is_empty() else "—")
	if url_label:
		url_label.text = "URL: " + (_server_url if not _server_url.is_empty() else "—")
	if http:
		http.request_completed.connect(_on_hud_state_received)
	if poll_timer and not _server_url.is_empty():
		poll_timer.timeout.connect(_poll_hud_state)
		poll_timer.start()
	_fit_panel()
	# Main._ready() corre después que DebugHud._ready() — esperamos un frame.
	await get_tree().process_frame
	_update_device_id_label()


func _update_device_id_label() -> void:
	var main := get_tree().get_root().get_node_or_null("Main")
	if main and "device_id" in main and device_id_label:
		device_id_label.text = "ID: " + main.device_id


func _fit_panel() -> void:
	await get_tree().process_frame
	var vbox := get_node_or_null("Panel/VBoxContainer") as VBoxContainer
	var panel := get_node_or_null("Panel") as Panel
	if vbox and panel:
		panel.size = vbox.get_combined_minimum_size() + Vector2(12.0, 8.0)


func _poll_hud_state() -> void:
	if _polling or not http:
		return
	_polling = true
	http.request(_server_url + "/client/hud")


func _on_hud_state_received(_result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	_polling = false
	if response_code != 200:
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if data is Dictionary and data.has("visible"):
		visible = bool(data["visible"])


func _process(_delta: float) -> void:
	if visible and fps_label:
		fps_label.text = "FPS: %d" % Engine.get_frames_per_second()
