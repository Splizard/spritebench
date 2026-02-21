package main

import (
	"strconv"
	"strings"

	"graphics.gd/classdb"
	"graphics.gd/classdb/Node2D"
	"graphics.gd/classdb/Resource"
	"graphics.gd/classdb/SceneTree"
	"graphics.gd/classdb/TextEdit"
	"graphics.gd/classdb/Texture2D"
	"graphics.gd/startup"
	"graphics.gd/variant/Float"
	"graphics.gd/variant/Vector2"
)

type Main struct {
	Node2D.Extension[Main]

	currentFrame int
	frameIndex   int
	frameTimes   []Float.X
}

const StartFrame = 100
const FrameCount = 1000

func (m *Main) Ready() {
	count := 20_000

	icon := Resource.Load[Texture2D.Instance]("res://icon.svg")

	for range count {
		m.AsNode().AddChild(NewSprite(icon, m.AsNode()).AsNode())
	}

	m.frameTimes = make([]Float.X, FrameCount)
}

func (m *Main) Process(delta Float.X) {
	m.currentFrame++

	if m.currentFrame >= StartFrame {
		if m.frameIndex == len(m.frameTimes) {
			for _, c := range m.AsNode().GetChildren() {
				c.AsNode().QueueFree()
			}

			edit := TextEdit.New()
			var sb strings.Builder
			for t := range m.frameTimes {
				sb.WriteString(strconv.FormatFloat(float64(m.frameTimes[t]), 'f', 6, 64))
				sb.WriteString("\n")
			}
			edit.SetText(sb.String())
			windowSize := SceneTree.Get(m.AsNode()).Root().AsWindow().Size()
			edit.AsControl().SetSize(Vector2.XY{X: Float.X(windowSize.X), Y: Float.X(windowSize.Y)})
			m.AsNode().AddChild(edit.AsNode())
		} else if m.frameIndex < len(m.frameTimes) {
			m.frameTimes[m.frameIndex] = delta
		}

		m.frameIndex++
	}
}

func main() {
	classdb.Register[Main]()
	classdb.Register[Sprite]()

	startup.LoadingScene()
	startup.Scene()
}
