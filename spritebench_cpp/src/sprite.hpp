#pragma once

#include <godot_cpp/classes/sprite2d.hpp>
#include <godot_cpp/classes/random_number_generator.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/window.hpp>
#include <godot_cpp/classes/engine.hpp>

using namespace godot;

class Sprite : public Sprite2D {
	GDCLASS(Sprite, Sprite2D)

	Ref<Texture2D> icon;
	Vector2 size2;

	float angle;
	float speed;
	Vector2 position;
	Vector2 window_size;

public:
	virtual void _ready() override;
	virtual void _process(double delta) override;

protected:
	static void _bind_methods();

};
