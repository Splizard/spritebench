use godot::{classes::{TextEdit, Texture2D}, prelude::*};
use crate::sprite::BenchSprite;

const FRAME_COUNT: usize = 1_000;
const START_FRAME: i32 = 100;
const SPRITE_COUNT: usize = 20_000;

#[derive(GodotClass)]
#[class(base=Node2D)]
struct Main {
    frame_times: [f64; FRAME_COUNT],

    base: Base<Node2D>,
    current_frame: i32,
    frame_index: i32,
}

#[godot_api]
impl INode2D for Main {
    fn init(base: Base<Node2D>) -> Self {
        Self {
            frame_times: [0.0; FRAME_COUNT],
            base,
            current_frame: 0,
            frame_index: 0,
        }
    }

    fn ready(&mut self) {
        let window_size = self.base().get_window().unwrap().get_size();
        let icon: Gd<Texture2D> = load("res://icon.svg");
            
        for _ in 0..SPRITE_COUNT {
            let sprite = BenchSprite::create_sprite(window_size, icon.clone());
            self.base_mut().add_child(&sprite);
        }
    }

    fn process(&mut self, _delta: f64) {
        self.current_frame += 1;

        if self.current_frame >= START_FRAME {
            if self.frame_index == self.frame_times.len() as i32 {
                let children: Vec<Gd<Node>> = self.base().get_children().iter_shared().collect();
                for child in children {
                    self.base_mut().remove_child(&child);
                }
                let mut edit = TextEdit::new_alloc();
                let window_size = self.base().get_window().unwrap().get_size();
                edit.set_size(Vector2::new(window_size.x as f32, window_size.y as f32));
                let text = self.frame_times.iter().map(|t| t.to_string() + "\n").collect::<String>();
                edit.set_text(&text);
                self.base_mut().add_child(&edit);
            } else if self.frame_index < self.frame_times.len() as i32 {
                self.frame_times[self.frame_index as usize] = _delta;
            }

            self.frame_index += 1;  
        }
    }
}
