use std::f32::consts::PI;
use std::f32;

use godot::classes::{ISprite2D, Sprite2D, Texture2D};
use godot::prelude::*;

#[derive(GodotClass)]
#[class(no_init, base=Sprite2D)]
pub struct BenchSprite {
    angle: f32,
    speed: f32,
    pos: Vector2,
    window_size: Vector2i,
    size_2: Vector2,

    base: Base<Sprite2D>,
}

#[godot_api]
impl BenchSprite {
    #[func]
    pub fn create_sprite(window_size: Vector2i, texture: Gd<Texture2D>) -> Gd<Self> {
        let mut sprite = Gd::from_init_fn(|base| Self {
            angle: rand::random_range(0.0..PI * 2.0) as f32,
            speed: rand::random_range(100.0..600.0) as f32,
            pos: Vector2 {
                x: window_size.x as f32 / 2.0,
                y: window_size.y as f32 / 2.0,
            },
            window_size,
            size_2: texture.get_size() / 2.0,
            base,
        });

        sprite.set_texture(&texture);

        sprite
    }
}

#[godot_api]
impl ISprite2D for BenchSprite {
    fn process(&mut self, delta: f64) {
        self.pos += Vector2 {
            x: f32::cos(self.angle),
            y: f32::sin(self.angle),
        } * self.speed * (delta as f32);

        let pos = self.pos;
        self.base_mut().set_position(pos);

        if self.pos.x < self.size_2.x || self.pos.x > self.window_size.x as f32 - self.size_2.x {
            self.angle = PI - self.angle;
        }
        if self.pos.y < self.size_2.y || self.pos.y > self.window_size.y as f32 - self.size_2.y {
            self.angle = -self.angle;
        }
    }
}
