extends Node2D

const frame_count := 1_000
const start_frame := 100

var frame_times := PackedFloat32Array()
var current_frame := 0
var frame_index := 0

func _ready() -> void:
	var count := 20_000
	
	for i in range(count):
		var sprite := Sprite.new()
		add_child(sprite)
		
	frame_times.resize(frame_count)

func _process(delta: float) -> void:
	current_frame += 1

	if current_frame >= start_frame:
		if frame_index == frame_times.size():
			for c in get_children(): c.queue_free()
			var edit := TextEdit.new()
			var s := PackedStringArray()
			for t in frame_times: s.append("%f" % t)
			edit.text = "\n".join(s)
			edit.size = get_window().size
			add_child(edit)
		elif frame_index < frame_times.size():
			frame_times[frame_index] = delta
		frame_index += 1
