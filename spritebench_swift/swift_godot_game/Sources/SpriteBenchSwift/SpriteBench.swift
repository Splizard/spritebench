import SwiftGodot

@Godot
class SpriteBench: Node2D {
    private let frameCount = 1_000
    private let startFrame = 100
    private let spriteCount = 20_000

    private var frameTimes: [Double] = []
    private var currentFrame = 0
    private var frameIndex = 0
    private var windowSize: Vector2 = .zero

    override func _ready() {
        frameTimes = Array(repeating: 0.0, count: frameCount)

        guard let icon = GD.load(path: "res://icon.svg") as? Texture2D else {
            GD.pushWarning("Failed to load icon texture")
            return
        }

        // TODO: When running from the editor, getWindow().size and getViewportRect() return zero values.
        // There seems to be something wrong, but for now we use the project settings to get the viewport size.
        let vpw = Int(ProjectSettings.getSetting(name: "display/window/size/viewport_width", defaultValue: Variant(1920)))
        let vph = Int(ProjectSettings.getSetting(name: "display/window/size/viewport_height", defaultValue: Variant(1080)))
        windowSize = Vector2(x: Float(vpw ?? 1920), y: Float(vph ?? 1080))
        let halfSize = icon.getSize() / 2.0

        for _ in 0..<spriteCount {
            let sprite = Sprite()
            sprite.texture = icon
            sprite.halfSize = halfSize
            sprite.windowSize = windowSize
            sprite.pos = windowSize / 2.0
            sprite.position = sprite.pos
            addChild(node: sprite)
        }
    }

    override func _process(delta: Double) {
        currentFrame += 1

        if currentFrame >= startFrame {
            if frameIndex == frameCount {
                for child in getChildren() {
                    child?.queueFree()
                }

                let edit = TextEdit()
                var outText = ""
                outText.reserveCapacity(frameCount * 12)
                for t in frameTimes {
                    outText += "\(t)\n"
                }
                edit.text = outText
                edit.setSize(windowSize)
                addChild(node: edit)
            } else if frameIndex < frameCount {
                frameTimes[frameIndex] = delta
            }

            frameIndex += 1
        }
    }
}
