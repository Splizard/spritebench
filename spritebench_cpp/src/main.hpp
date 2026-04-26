#pragma once

#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/classes/text_edit.hpp>
#include "sprite.hpp"

using namespace godot;

class Main : public Node2D {
	GDCLASS(Main, Node2D)

	const int FRAME_COUNT = 1000;
	const int START_FRAME = 100;
	const int SPRITE_COUNT = 20000;

	PackedFloat32Array frame_times;
	int current_frame = 0;
	int frame_index = 0;

public:
	virtual void _ready() override;
	virtual void _process(double delta) override;

protected:
	static void _bind_methods();

};