import Foundation
import SwiftGodot

@Godot
class Sprite: Sprite2D {
    var angle: Float = .random(in: 0...(Float.pi * 2))
    var speed: Float = .random(in: 100...600)
    var pos: Vector2 = .zero
    var windowSize: Vector2 = .zero
    var halfSize: Vector2 = .zero

    override func _process(delta: Double) {
        pos = pos + Vector2(x: cos(angle), y: sin(angle)) * Double(speed) * delta
        position = pos

        if pos.x < halfSize.x || pos.x > windowSize.x - halfSize.x {
            angle = Float.pi - angle
        }
        if pos.y < halfSize.y || pos.y > windowSize.y - halfSize.y {
            angle = -angle
        }
    }
}
