#include "sprite.hpp"

void Sprite::_bind_methods() {}

void Sprite::_ready() {
	if (Engine::get_singleton()->is_editor_hint()) {
		set_process(false);
		return;
	}

	icon = ResourceLoader::get_singleton()->load("res://icon.svg");
	set_texture(icon);
	size2 = icon->get_size() / 2;
	
	Ref<RandomNumberGenerator> rng = memnew(RandomNumberGenerator);
	rng->randomize();
	angle = rng->randf_range(0.0, Math_TAU);
	speed = rng->randf_range(100.0, 600.0);

	window_size = get_window()->get_size();
	position = window_size / 2;
	set_position(position);
}

void Sprite::_process(double delta) {
	position += Vector2(Math::cos(angle), Math::sin(angle)) * speed * delta;
	set_position(position);
	
	angle = (position.x < size2.x || position.x > window_size.x - size2.x) ? Math_PI - angle : angle;
	angle = (position.y < size2.y || position.y > window_size.y - size2.y) ? -angle : angle;
}