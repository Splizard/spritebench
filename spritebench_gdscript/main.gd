extends Node2D

# Sprites-at-target benchmark: find the largest sprite count this language
# sustains at the target frame rate: the display refresh rate on devices
# whose main loop is vsync-paced (Android/iOS), 60 fps when headless or the
# refresh rate is unknown. A window sustains the target only if its 1% low
# (99th-percentile frame time) holds 0.95×target, so frames that miss vsync
# fail the window even when the median pace is fine. Doubling/halving
# brackets the count, binary search refines it, and a best-of-3 verify
# re-measures at the answer, walking the count down until the median window
# passes. The result is one line:
# "<max_sprites> <target_fps> <fps_at_max>".

const global_warmup := 100
const window_warmup := 40
const window_measure := 120
const start_count := 20_000
const min_count := 1_250
const max_count := 2_560_000
const sustain := 0.95
const refine_rounds := 6
const low_index := window_measure * 99 / 100
const verify_windows := 3
const verify_step := 16

var sprites: Array[Node] = []
var times := PackedFloat32Array()
var target := 60.0
var lo := 0
var hi := 0
var rounds := 0
var verifying := false
var verify_fps: Array[float] = []
var global_frame := 0
var window_frame := 0

func _ready() -> void:
	times.resize(window_measure)
	var refresh := DisplayServer.screen_get_refresh_rate()
	target = refresh if refresh > 0 else 60.0
	_set_count(start_count)

func _set_count(n: int) -> void:
	while sprites.size() > n:
		sprites.pop_back().queue_free()
	while sprites.size() < n:
		var sprite := Sprite.new()
		sprites.append(sprite)
		add_child(sprite)
	window_frame = 0

func _process(delta: float) -> void:
	global_frame += 1
	if global_frame <= global_warmup:
		return
	window_frame += 1
	if window_frame <= window_warmup:
		return
	var i := window_frame - window_warmup - 1
	times[i] = delta
	if i < window_measure - 1:
		return

	var sorted := times.duplicate()
	sorted.sort()
	var fps := 1.0 / sorted[low_index]
	var sustained := fps >= sustain * target
	var count := sprites.size()

	if verifying:
		verify_fps.append(fps)
		if verify_fps.size() < verify_windows:
			_set_count(count)
			return
		verify_fps.sort()
		var median: float = verify_fps[verify_windows / 2]
		verify_fps.clear()
		if median >= sustain * target:
			_report(count, median)
		elif count <= min_count:
			_report(0, median)
		else:
			_set_count(maxi(count - count / verify_step, min_count))
		return
	if sustained:
		lo = count
	else:
		hi = count
	if not sustained and count <= min_count:
		_report(0, fps)
		return
	if sustained and count >= max_count:
		verifying = true
		_set_count(count)
		return
	if hi == 0:
		_set_count(count * 2)
	elif lo == 0:
		_set_count(maxi(count / 2, min_count))
	else:
		rounds += 1
		if rounds > refine_rounds:
			verifying = true
			_set_count(lo)
			return
		_set_count((lo + hi) / 2)

func _report(count: int, fps: float) -> void:
	var line := "%d %d %.2f" % [count, roundi(target), fps]
	if OS.has_feature("ios"):
		# iOS os_log redacts dynamic strings as <private>, so console
		# scraping is useless. Write to the app sandbox instead and
		# pull it off the device via AFC (see run-ios.sh).
		var f := FileAccess.open("user://spritebench_results.csv", FileAccess.WRITE)
		f.store_string(line + "\n")
		f.close()
		get_tree().quit()
		return
	if OS.has_feature("web") or OS.has_feature("android"):
		# Captured from the browser console / logcat by the automated
		# benchmark.
		print("SPRITEBENCH_RESULTS_BEGIN")
		print(line)
		print("SPRITEBENCH_RESULTS_END")
		get_tree().quit()
		return
	var output_path := OS.get_environment("SPRITEBENCH_OUTPUT")
	if output_path != "":
		var f := FileAccess.open(output_path, FileAccess.WRITE)
		f.store_string(line + "\n")
		f.close()
		get_tree().quit()
		return
	var edit := TextEdit.new()
	edit.text = line
	edit.size = get_window().size
	add_child(edit)
	set_process(false)
