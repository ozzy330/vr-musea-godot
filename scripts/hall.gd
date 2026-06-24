extends Node3D

@export var door_a: Node3D
@export var door_a_blocker: Node3D

@export var door_b: Node3D
@export var door_b_blocker: Node3D

## Punto de entrada del hall (para alinearse al socket_out del túnel anterior).
@export var socket_in: Node3D

## Nodo del túnel que conecta este hall con el siguiente.
## Coloca la escena del túnel como hijo de este hall en el editor y asígnalo aquí.
## Debe tener el script tunnel.gd con socket_in y socket_out asignados.
## Dejar vacío en el último hall.
@export var tunnel: Node3D


# ── API para main.gd ──────────────────────────────────────────────────────────

## Devuelve el nodo socket_out del túnel, o null si este hall no tiene túnel.
## main.gd lo usa para saber dónde colocar el siguiente hall.
func get_tunnel_exit() -> Node3D:
	if tunnel == null:
		return null
	return tunnel.get("socket_out") as Node3D


# ── Setup (llamado por main.gd) ───────────────────────────────────────────────

func setup(data: Dictionary, state_a: String = "closed", state_b: String = "closed") -> void:
	_apply_door(door_a, door_a_blocker, state_a)
	_apply_door(door_b, door_b_blocker, state_b)
	_apply_slots(data.get("slots", []))


# ── Slots ─────────────────────────────────────────────────────────────────────

var _lienzo_map: Dictionary = {}

func _build_lienzo_map() -> void:
	_lienzo_map.clear()
	_collect_lienzos(self)

func _collect_lienzos(node: Node) -> void:
	for child in node.get_children():
		if child.has_method("load_asset"):
			_lienzo_map[Vector2i(child.wall, child.slot)] = child
		_collect_lienzos(child)

func _apply_slots(slots: Array) -> void:
	if _lienzo_map.is_empty():
		_build_lienzo_map()
	for s in slots:
		var wall_idx: int = s.get("wall", -1)
		var slot_idx: int = s.get("slot", -1)
		var asset = s.get("asset", {})
		if not asset is Dictionary or asset.is_empty() or wall_idx < 0 or slot_idx < 0:
			continue
		var key := Vector2i(wall_idx, slot_idx)
		if not _lienzo_map.has(key):
			push_warning("Hall '%s': no hay Lienzo en wall=%d slot=%d" % [name, wall_idx, slot_idx])
			continue
		_lienzo_map[key].load_asset(asset, s.get("title", ""))


# ── Doors ─────────────────────────────────────────────────────────────────────

func _apply_door(door: Node3D, blocker: Node3D, state: String) -> void:
	var blocked: bool = state == "closed" or state == ""
	if blocker:
		blocker.visible = blocked
		for shape in blocker.find_children("*", "CollisionShape3D", true, false):
			(shape as CollisionShape3D).disabled = not blocked
	if door:
		var door_mesh := door.get_node_or_null("Door")
		if door_mesh:
			door_mesh.visible = not blocked
