use godot::{classes::{DisplayServer, TextEdit, Texture2D}, prelude::*};
use crate::sprite::BenchSprite;

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
const GLOBAL_WARMUP: i32 = 600;
const WINDOW_WARMUP: i32 = 40;
const WINDOW_MEASURE: usize = 120;
const START_COUNT: usize = 20_000;
const MIN_COUNT: usize = 1_250;
const MAX_COUNT: usize = 2_560_000;
const SUSTAIN: f64 = 0.95;
const REFINE_ROUNDS: i32 = 6;
const CONFIRM_FAILS: i32 = 2;
const LOW_INDEX: usize = WINDOW_MEASURE * 99 / 100;
const VERIFY_WINDOWS: usize = 3;
const VERIFY_STEP: usize = 16;

#[derive(GodotClass)]
#[class(base=Node2D)]
struct Main {
    sprites: Vec<Gd<BenchSprite>>,
    times: [f64; WINDOW_MEASURE],
    target: f64,
    lo: usize,
    hi: usize,
    rounds: i32,
    fails: i32,
    verifying: bool,
    verify_fps: Vec<f64>,
    global_frame: i32,
    window_frame: i32,
    icon: Option<Gd<Texture2D>>,
    window_size: Vector2i,

    base: Base<Node2D>,
}

#[godot_api]
impl INode2D for Main {
    fn init(base: Base<Node2D>) -> Self {
        Self {
            sprites: Vec::new(),
            times: [0.0; WINDOW_MEASURE],
            target: 60.0,
            lo: 0,
            hi: 0,
            rounds: 0,
            fails: 0,
            verifying: false,
            verify_fps: Vec::new(),
            global_frame: 0,
            window_frame: 0,
            icon: None,
            window_size: Vector2i::ZERO,
            base,
        }
    }

    fn ready(&mut self) {
        self.window_size = self.base().get_window().unwrap().get_size();
        self.icon = Some(load("res://icon.svg"));
        let refresh = DisplayServer::singleton().screen_get_refresh_rate() as f64;
        self.target = if refresh > 0.0 { refresh } else { 60.0 };
        self.set_count(START_COUNT);
    }

    fn process(&mut self, delta: f64) {
        self.global_frame += 1;
        if self.global_frame <= GLOBAL_WARMUP {
            return;
        }
        self.window_frame += 1;
        if self.window_frame <= WINDOW_WARMUP {
            return;
        }
        let i = (self.window_frame - WINDOW_WARMUP - 1) as usize;
        self.times[i] = delta;
        if i < WINDOW_MEASURE - 1 {
            return;
        }

        let mut sorted = self.times;
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let fps = 1.0 / sorted[LOW_INDEX];
        let sustained = fps >= SUSTAIN * self.target;
        let count = self.sprites.len();

        if self.verifying {
            self.verify_fps.push(fps);
            if self.verify_fps.len() < VERIFY_WINDOWS {
                self.set_count(count);
                return;
            }
            self.verify_fps.sort_by(|a, b| a.partial_cmp(b).unwrap());
            let median = self.verify_fps[VERIFY_WINDOWS / 2];
            self.verify_fps.clear();
            if median >= SUSTAIN * self.target {
                self.report(count, median);
            } else if count <= MIN_COUNT {
                self.report(0, median);
            } else {
                self.set_count((count - count / VERIFY_STEP).max(MIN_COUNT));
            }
            return;
        }
        if sustained {
            self.fails = 0;
            self.lo = count;
        } else if self.fails + 1 < CONFIRM_FAILS {
            // One bad window must not pin the ceiling. Once hi is set the search
            // can never rise above it again, so a single startup hitch, scheduler
            // hiccup or thermal blip permanently confines the run to a count the
            // machine beats comfortably -- and the verify pass, which only
            // re-checks lo, cannot detect it. Re-measure the same count and
            // believe the failure only if it repeats.
            self.fails += 1;
            self.set_count(count);
            return;
        } else {
            self.fails = 0;
            self.hi = count;
        }
        if !sustained && count <= MIN_COUNT {
            self.report(0, fps);
            return;
        }
        if sustained && count >= MAX_COUNT {
            self.verifying = true;
            self.set_count(count);
            return;
        }
        if self.hi == 0 {
            self.set_count(count * 2);
        } else if self.lo == 0 {
            self.set_count((count / 2).max(MIN_COUNT));
        } else {
            self.rounds += 1;
            if self.rounds > REFINE_ROUNDS {
                self.verifying = true;
                let lo = self.lo;
                self.set_count(lo);
                return;
            }
            let mid = (self.lo + self.hi) / 2;
            self.set_count(mid);
        }
    }
}

impl Main {
    fn set_count(&mut self, n: usize) {
        while self.sprites.len() > n {
            let mut sprite = self.sprites.pop().unwrap();
            sprite.queue_free();
        }
        while self.sprites.len() < n {
            let sprite = BenchSprite::create_sprite(self.window_size, self.icon.clone().unwrap());
            self.base_mut().add_child(&sprite);
            self.sprites.push(sprite);
        }
        self.window_frame = 0;
    }

    fn report(&mut self, count: usize, fps: f64) {
        let line = format!("{} {} {:.2}\n", count, self.target.round() as i64, fps);

        if godot::classes::Os::singleton().has_feature("ios") {
            // iOS os_log redacts dynamic strings as <private>, so console
            // scraping is useless. Write to the app sandbox (user data dir)
            // and pull it off the device via AFC.
            let dir = godot::classes::Os::singleton().get_user_data_dir();
            std::fs::write(format!("{dir}/spritebench_results.csv"), &line).ok();
            self.base_mut().get_tree().unwrap().quit();
            return;
        }

        if ["web", "android"].iter().any(|f| godot::classes::Os::singleton().has_feature(*f)) {
            // Captured from the browser console / logcat by the automated
            // benchmark.
            godot_print!("SPRITEBENCH_RESULTS_BEGIN");
            godot_print!("{}", line.trim_end());
            godot_print!("SPRITEBENCH_RESULTS_END");
            self.base_mut().get_tree().unwrap().quit();
            return;
        }

        if let Ok(output_path) = std::env::var("SPRITEBENCH_OUTPUT") {
            if !output_path.is_empty() {
                std::fs::write(&output_path, &line).expect("failed to write benchmark output");
                self.base_mut().get_tree().unwrap().quit();
                return;
            }
        }

        let mut edit = TextEdit::new_alloc();
        let window_size = self.base().get_window().unwrap().get_size();
        edit.set_size(Vector2::new(window_size.x as f32, window_size.y as f32));
        edit.set_text(&line);
        self.base_mut().add_child(&edit);
        self.base_mut().set_process(false);
    }
}
