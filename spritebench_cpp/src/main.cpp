#include "main.hpp"

void Main::_bind_methods() {}

void Main::_ready() {
	if (Engine::get_singleton()->is_editor_hint()) {
		set_process(false);
		return;
	}
	
	frame_times.resize(FRAME_COUNT);
	
	for (int index = 0; index < SPRITE_COUNT; index++) {
		add_child(memnew(Sprite));
	}
}

void Main::_process(double delta) {
	if (++current_frame >= START_FRAME) {
		if (frame_index == FRAME_COUNT) {
			for (Variant child : get_children()) {
				Node *child_node = Object::cast_to<Node>(child);
				child_node->queue_free();
			}

			TextEdit *edit = memnew(TextEdit);
			PackedStringArray str;
			str.resize(FRAME_COUNT);
			for (int index = 0; index < FRAME_COUNT; index++) {
				str[index] = String::num_real(frame_times[index]);
			}
			edit->set_text(String("\n").join(str));
			edit->set_size(get_window()->get_size());
			add_child(edit);
		} else if (frame_index < frame_times.size()) {
			frame_times[frame_index] = delta;
		}
		++frame_index;
	}
}