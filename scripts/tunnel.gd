@tool
extends Node3D

## Nodo dentro del túnel que se alinea al door_b del hall anterior.
@export var socket_in:  Node3D
## Nodo dentro del túnel que define dónde va el door_a del siguiente hall.
@export var socket_out: Node3D


func _get_configuration_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if socket_in == null:
		w.append("socket_in no está asignado — asigna el nodo de entrada del túnel.")
	if socket_out == null:
		w.append("socket_out no está asignado — asigna el nodo de salida del túnel.")
	return w
