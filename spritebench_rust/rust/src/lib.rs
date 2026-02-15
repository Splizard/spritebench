use godot::prelude::*;

pub mod sprite;
pub mod window;

struct SpritebenchExtension;

#[gdextension]
unsafe impl ExtensionLibrary for SpritebenchExtension {}
