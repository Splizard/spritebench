class_name Sprite
extends Sprite2D

static var icon := preload("res://icon.svg")
static var size_2 := icon.get_size() / 2

var angle := randf_range(0, PI * 2)
var speed := randf_range(100, 600)
var pos := Vector2.ZERO
var window_size: Vector2

func _ready() -> void:
	texture = icon
	pos = Vector2(get_window().size) / 2
	position = pos
	window_size = Vector2(get_window().size)

func _process(delta: float) -> void:
	pos += Vector2(cos(angle), sin(angle)) * speed * delta
	position = pos

	if position.x < size_2.x or position.x > window_size.x - size_2.x:
		angle = PI - angle
	if position.y < size_2.y or position.y > window_size.y - size_2.y:
		angle = -angle
