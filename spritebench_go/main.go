package main

import (
	"fmt"
	"os"
	"runtime/pprof"
	"sort"

	"graphics.gd/classdb"
	"graphics.gd/classdb/DisplayServer"
	"graphics.gd/classdb/Engine"
	"graphics.gd/classdb/FileAccess"
	"graphics.gd/classdb/Node2D"
	"graphics.gd/classdb/OS"
	"graphics.gd/classdb/Resource"
	"graphics.gd/classdb/SceneTree"
	"graphics.gd/classdb/TextEdit"
	"graphics.gd/classdb/Texture2D"
	"graphics.gd/startup"
	"graphics.gd/variant/Float"
	"graphics.gd/variant/Vector2"
)

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
const (
	GlobalWarmup  = 100
	WindowWarmup  = 40
	WindowMeasure = 120
	StartCount    = 20_000
	MinCount      = 1_250
	MaxCount      = 2_560_000
	Sustain       = 0.95
	RefineRounds  = 6
	LowIndex      = WindowMeasure * 99 / 100
	VerifyWindows = 3
	VerifyStep    = 16
)

type Main struct {
	Node2D.Extension[Main]

	sprites     []*Sprite
	times       []float64
	target      float64
	lo          int
	hi          int
	rounds      int
	verifying   bool
	verifyFps   []float64
	globalFrame int
	windowFrame int
	icon        Texture2D.Instance
	profileFile *os.File
}

func (m *Main) Ready() {
	m.times = make([]float64, WindowMeasure)
	m.icon = Resource.Load[Texture2D.Instance]("res://icon.svg")
	refresh := float64(DisplayServer.ScreenGetRefreshRate())
	if refresh > 0 {
		m.target = refresh
	} else {
		m.target = 60
	}
	m.setCount(StartCount)

	if os.Getenv("SPRITEBENCH_PROFILE") != "" {
		f, err := os.Create("profile.out")
		if err == nil {
			m.profileFile = f
			pprof.StartCPUProfile(f)
		}
	}
}

func (m *Main) setCount(n int) {
	for len(m.sprites) > n {
		s := m.sprites[len(m.sprites)-1]
		m.sprites = m.sprites[:len(m.sprites)-1]
		s.AsNode().QueueFree()
	}
	for len(m.sprites) < n {
		s := NewSprite(m.icon, m.AsNode())
		m.sprites = append(m.sprites, s)
		m.AsNode().AddChild(s.AsNode())
	}
	m.windowFrame = 0
}

func (m *Main) Process(delta Float.X) {
	m.globalFrame++
	if m.globalFrame <= GlobalWarmup {
		return
	}
	m.windowFrame++
	if m.windowFrame <= WindowWarmup {
		return
	}
	i := m.windowFrame - WindowWarmup - 1
	m.times[i] = float64(delta)
	if i < WindowMeasure-1 {
		return
	}

	sorted := append([]float64(nil), m.times...)
	sort.Float64s(sorted)
	fps := 1.0 / sorted[LowIndex]
	sustained := fps >= Sustain*m.target
	count := len(m.sprites)

	if m.verifying {
		m.verifyFps = append(m.verifyFps, fps)
		if len(m.verifyFps) < VerifyWindows {
			m.setCount(count)
			return
		}
		sort.Float64s(m.verifyFps)
		median := m.verifyFps[VerifyWindows/2]
		m.verifyFps = m.verifyFps[:0]
		if median >= Sustain*m.target {
			m.report(count, median)
		} else if count <= MinCount {
			m.report(0, median)
		} else {
			m.setCount(max(count-count/VerifyStep, MinCount))
		}
		return
	}
	if sustained {
		m.lo = count
	} else {
		m.hi = count
	}
	if !sustained && count <= MinCount {
		m.report(0, fps)
		return
	}
	if sustained && count >= MaxCount {
		m.verifying = true
		m.setCount(count)
		return
	}
	switch {
	case m.hi == 0:
		m.setCount(count * 2)
	case m.lo == 0:
		m.setCount(max(count/2, MinCount))
	default:
		m.rounds++
		if m.rounds > RefineRounds {
			m.verifying = true
			m.setCount(m.lo)
			return
		}
		m.setCount((m.lo + m.hi) / 2)
	}
}

func (m *Main) report(count int, fps float64) {
	if m.profileFile != nil {
		pprof.StopCPUProfile()
		m.profileFile.Close()
		m.profileFile = nil
	}

	line := fmt.Sprintf("%d %d %.2f\n", count, int(m.target+0.5), fps)

	if OS.HasFeature("ios") {
		// iOS os_log redacts dynamic strings as <private>, so console
		// scraping is useless. Write via Godot's FileAccess to user://
		// (maps to the app's Documents on iOS, same as the other
		// languages) and pull it off the device via AFC (see run-ios.sh).
		f := FileAccess.Open("user://spritebench_results.csv", FileAccess.Write)
		f.StoreString(line)
		f.Close()
		SceneTree.Get(m.AsNode()).Quit()
		return
	}

	if OS.HasFeature("web") || OS.HasFeature("android") {
		// Captured from the browser console / logcat by the automated
		// benchmark. Godot's print (not stdout, which Android drops).
		Engine.Println("SPRITEBENCH_RESULTS_BEGIN")
		Engine.Println(line[:len(line)-1])
		Engine.Println("SPRITEBENCH_RESULTS_END")
		SceneTree.Get(m.AsNode()).Quit()
		return
	}

	if output := os.Getenv("SPRITEBENCH_OUTPUT"); output != "" {
		os.WriteFile(output, []byte(line), 0o644)
		SceneTree.Get(m.AsNode()).Quit()
		return
	}

	edit := TextEdit.New()
	edit.SetText(line)
	windowSize := SceneTree.Get(m.AsNode()).Root().AsWindow().Size()
	edit.AsControl().SetSize(Vector2.XY{X: Float.X(windowSize.X), Y: Float.X(windowSize.Y)})
	m.AsNode().AddChild(edit.AsNode())
	m.AsNode().SetProcess(false)
}

func main() {
	classdb.Register[Main]()
	classdb.Register[Sprite]()

	startup.LoadingScene()
	startup.Scene()
}
