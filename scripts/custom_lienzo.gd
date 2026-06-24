@tool
extends Node3D

@export_group("Slot")
@export_range(0, 1) var wall: int = 0:
	set(v): wall = v; _sync()
@export_range(0, 2) var slot: int = 0:
	set(v): slot = v; _sync()

@export_group("Tamaño")
@export_range(0.1, 10.0, 0.01, "suffix:m") var ancho: float = 0.71:
	set(v): ancho = v; _sync()
@export_range(0.1, 10.0, 0.01, "suffix:m") var alto: float = 0.4:
	set(v): alto = v; _sync()

@export_group("Contenido")
@export var imagen: Texture2D:
	set(v): imagen = v; _sync()
@export var video: VideoStream:
	set(v): video = v; _sync()
@export var audio: AudioStream:
	set(v): audio = v; _sync()
@export var title_label: Label3D:
	set(v): title_label = v; _sync()

signal asset_loaded(lienzo)


func _ready() -> void:
	_sync()
	var lienzo := get_node_or_null("Lienzo")
	if lienzo and lienzo.has_signal("asset_loaded"):
		lienzo.asset_loaded.connect(asset_loaded.emit)


func load_asset(asset: Dictionary, title: String = "") -> void:
	get_node("Lienzo").load_asset(asset, title)


func _sync() -> void:
	var lienzo := get_node_or_null("Lienzo")
	if lienzo == null:
		return
	lienzo.wall  = wall
	lienzo.slot  = slot
	lienzo.ancho = ancho
	lienzo.alto  = alto
	lienzo.imagen       = imagen
	lienzo.video        = video
	lienzo.audio        = audio
	lienzo.title_label  = title_label
