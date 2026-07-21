#include "main.hpp"

#include <godot_cpp/classes/display_server.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <algorithm>

void Main::_bind_methods() {}

void Main::_ready() {
	if (Engine::get_singleton()->is_editor_hint()) {
		set_process(false);
		return;
	}

	times.resize(WINDOW_MEASURE);
	double refresh = DisplayServer::get_singleton()->screen_get_refresh_rate();
	target = refresh > 0 ? refresh : 60.0;
	set_count(START_COUNT);
}

void Main::set_count(int n) {
	while ((int)sprites.size() > n) {
		sprites.back()->queue_free();
		sprites.pop_back();
	}
	while ((int)sprites.size() < n) {
		Sprite *sprite = memnew(Sprite);
		sprites.push_back(sprite);
		add_child(sprite);
	}
	window_frame = 0;
}

void Main::_process(double delta) {
	if (++global_frame <= GLOBAL_WARMUP) {
		return;
	}
	if (++window_frame <= WINDOW_WARMUP) {
		return;
	}
	int i = window_frame - WINDOW_WARMUP - 1;
	times[i] = delta;
	if (i < WINDOW_MEASURE - 1) {
		return;
	}

	PackedFloat32Array sorted = times.duplicate();
	sorted.sort();
	double fps = 1.0 / sorted[LOW_INDEX];
	bool sustained = fps >= SUSTAIN * target;
	int count = (int)sprites.size();

	if (verifying) {
		verify_fps[verify_done++] = fps;
		if (verify_done < VERIFY_WINDOWS) {
			set_count(count);
			return;
		}
		std::sort(verify_fps, verify_fps + VERIFY_WINDOWS);
		double median = verify_fps[VERIFY_WINDOWS / 2];
		verify_done = 0;
		if (median >= SUSTAIN * target) {
			report(count, median);
		} else if (count <= MIN_COUNT) {
			report(0, median);
		} else {
			set_count(MAX(count - count / VERIFY_STEP, MIN_COUNT));
		}
		return;
	}
	if (sustained) {
		lo = count;
	} else {
		hi = count;
	}
	if (!sustained && count <= MIN_COUNT) {
		report(0, fps);
		return;
	}
	if (sustained && count >= MAX_COUNT) {
		verifying = true;
		set_count(count);
		return;
	}
	if (hi == 0) {
		set_count(count * 2);
	} else if (lo == 0) {
		set_count(MAX(count / 2, MIN_COUNT));
	} else {
		if (++rounds > REFINE_ROUNDS) {
			verifying = true;
			set_count(lo);
			return;
		}
		set_count((lo + hi) / 2);
	}
}

void Main::report(int count, double fps) {
	String line = String::num_int64(count) + " " + String::num_int64((int64_t)(target + 0.5))
		+ " " + String::num(fps, 2);

	if (OS::get_singleton()->has_feature("ios")) {
		// iOS os_log redacts dynamic strings as <private>, so console
		// scraping is useless. Write to the app sandbox and pull it
		// off the device via AFC (see run-ios.sh).
		Ref<FileAccess> file = FileAccess::open("user://spritebench_results.csv", FileAccess::WRITE);
		file->store_string(line + "\n");
		file->close();
		get_tree()->quit();
		return;
	}

	if (OS::get_singleton()->has_feature("web") || OS::get_singleton()->has_feature("android")) {
		// Captured from the browser console / logcat by the automated
		// benchmark.
		UtilityFunctions::print(String("SPRITEBENCH_RESULTS_BEGIN"));
		UtilityFunctions::print(line);
		UtilityFunctions::print(String("SPRITEBENCH_RESULTS_END"));
		get_tree()->quit();
		return;
	}

	String output_path = OS::get_singleton()->get_environment("SPRITEBENCH_OUTPUT");
	if (!output_path.is_empty()) {
		Ref<FileAccess> file = FileAccess::open(output_path, FileAccess::WRITE);
		file->store_string(line + "\n");
		file->close();
		get_tree()->quit();
		return;
	}

	TextEdit *edit = memnew(TextEdit);
	edit->set_text(line);
	edit->set_size(get_window()->get_size());
	add_child(edit);
	set_process(false);
}
