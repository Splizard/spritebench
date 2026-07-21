import Foundation
import SwiftGodot

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
@Godot
class SpriteBench: Node2D {
    private let globalWarmup = 100
    private let windowWarmup = 40
    private let windowMeasure = 120
    private let startCount = 20_000
    private let minCount = 1_250
    private let maxCount = 2_560_000
    private let sustain = 0.95
    private let refineRounds = 6
    private let verifyWindows = 3
    private let verifyStep = 16

    private var sprites: [Sprite] = []
    private var times: [Double] = []
    private var target = 60.0
    private var lo = 0
    private var hi = 0
    private var rounds = 0
    private var verifying = false
    private var verifyFps: [Double] = []
    private var globalFrame = 0
    private var windowFrame = 0

    private var icon: Texture2D?
    private var halfSize: Vector2 = .zero
    private var windowSize: Vector2 = .zero

    override func _ready() {
        times = Array(repeating: 0.0, count: windowMeasure)

        guard let icon = GD.load(path: "res://icon.svg") as? Texture2D else {
            GD.pushWarning("Failed to load icon texture")
            return
        }
        self.icon = icon

        // TODO: When running from the editor, getWindow().size and getViewportRect() return zero values.
        // There seems to be something wrong, but for now we use the project settings to get the viewport size.
        let vpw = Int(ProjectSettings.getSetting(name: "display/window/size/viewport_width", defaultValue: Variant(1920)))
        let vph = Int(ProjectSettings.getSetting(name: "display/window/size/viewport_height", defaultValue: Variant(1080)))
        windowSize = Vector2(x: Float(vpw ?? 1920), y: Float(vph ?? 1080))
        halfSize = icon.getSize() / 2.0

        let refresh = DisplayServer.screenGetRefreshRate()
        target = refresh > 0 ? refresh : 60.0
        setCount(startCount)
    }

    private func makeSprite() -> Sprite {
        let sprite = Sprite()
        sprite.texture = icon
        sprite.halfSize = halfSize
        sprite.windowSize = windowSize
        sprite.pos = windowSize / 2.0
        sprite.position = sprite.pos
        return sprite
    }

    private func setCount(_ n: Int) {
        while sprites.count > n {
            sprites.removeLast().queueFree()
        }
        while sprites.count < n {
            let sprite = makeSprite()
            sprites.append(sprite)
            addChild(node: sprite)
        }
        windowFrame = 0
    }

    override func _process(delta: Double) {
        globalFrame += 1
        if globalFrame <= globalWarmup {
            return
        }
        windowFrame += 1
        if windowFrame <= windowWarmup {
            return
        }
        let i = windowFrame - windowWarmup - 1
        times[i] = delta
        if i < windowMeasure - 1 {
            return
        }

        let sorted = times.sorted()
        let fps = 1.0 / sorted[windowMeasure * 99 / 100]
        let sustained = fps >= sustain * target
        let count = sprites.count

        if verifying {
            verifyFps.append(fps)
            if verifyFps.count < verifyWindows {
                setCount(count)
                return
            }
            verifyFps.sort()
            let median = verifyFps[verifyWindows / 2]
            verifyFps.removeAll(keepingCapacity: true)
            if median >= sustain * target {
                report(count: count, fps: median)
            } else if count <= minCount {
                report(count: 0, fps: median)
            } else {
                setCount(max(count - count / verifyStep, minCount))
            }
            return
        }
        if sustained {
            lo = count
        } else {
            hi = count
        }
        if !sustained && count <= minCount {
            report(count: 0, fps: fps)
            return
        }
        if sustained && count >= maxCount {
            verifying = true
            setCount(count)
            return
        }
        if hi == 0 {
            setCount(count * 2)
        } else if lo == 0 {
            setCount(max(count / 2, minCount))
        } else {
            rounds += 1
            if rounds > refineRounds {
                verifying = true
                setCount(lo)
                return
            }
            setCount((lo + hi) / 2)
        }
    }

    private func report(count: Int, fps: Double) {
        let line = "\(count) \(Int(target.rounded())) \(String(format: "%.2f", fps))"

        if OS.hasFeature(tagName: "ios") {
            // iOS os_log redacts dynamic strings as <private>, so
            // console scraping is useless. Write to the app sandbox
            // (user data dir) and pull it off the device via AFC.
            let path = ProjectSettings.globalizePath("user://spritebench_results.csv")
            try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            getTree()?.quit()
            return
        }

        if OS.hasFeature(tagName: "web") || OS.hasFeature(tagName: "android") {
            // Captured from the console / device log by the automated
            // benchmark.
            GD.print(arg1: Variant("SPRITEBENCH_RESULTS_BEGIN"))
            GD.print(arg1: Variant(line))
            GD.print(arg1: Variant("SPRITEBENCH_RESULTS_END"))
            getTree()?.quit()
            return
        }

        if let outputPath = ProcessInfo.processInfo.environment["SPRITEBENCH_OUTPUT"],
           !outputPath.isEmpty {
            try? (line + "\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
            getTree()?.quit()
            return
        }

        let edit = TextEdit()
        edit.text = line
        edit.setSize(windowSize)
        addChild(node: edit)
        setProcess(enable: false)
    }
}
