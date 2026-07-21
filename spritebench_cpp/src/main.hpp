#pragma once

#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/classes/text_edit.hpp>
#include <vector>
#include "sprite.hpp"

using namespace godot;

// Sprites-at-target benchmark: find the largest sprite count this language
// sustains at the target frame rate: the display refresh rate on devices
// whose main loop is vsync-paced (Android/iOS), 60 fps when headless or the
// refresh rate is unknown. A window sustains the target only if its 1% low
// (99th-percentile frame time) holds 0.95×target, so frames that miss vsync
// fail the window even when the median pace is fine. Doubling/halving
// brackets the count, binary search refines it, and a best-of-3 verify
// re-measures at the answer, walking the count down until the median window
// passes. The result is one line:
// "<max_sprites> <target_fps> <fps_at_max>".
class Main : public Node2D {
	GDCLASS(Main, Node2D)

	const int GLOBAL_WARMUP = 100;
	const int WINDOW_WARMUP = 40;
	const int WINDOW_MEASURE = 120;
	const int START_COUNT = 20000;
	const int MIN_COUNT = 1250;
	const int MAX_COUNT = 2560000;
	const double SUSTAIN = 0.95;
	const int REFINE_ROUNDS = 6;
	const int LOW_INDEX = WINDOW_MEASURE * 99 / 100;
	static const int VERIFY_WINDOWS = 3;
	const int VERIFY_STEP = 16;

	std::vector<Sprite *> sprites;
	PackedFloat32Array times;
	double target = 60.0;
	int lo = 0;
	int hi = 0;
	int rounds = 0;
	bool verifying = false;
	double verify_fps[VERIFY_WINDOWS] = {};
	int verify_done = 0;
	int global_frame = 0;
	int window_frame = 0;

	void set_count(int n);
	void report(int count, double fps);

public:
	virtual void _ready() override;
	virtual void _process(double delta) override;

protected:
	static void _bind_methods();

};
