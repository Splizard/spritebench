package main

import (
	"math"

	"graphics.gd/classdb/Node"
	"graphics.gd/classdb/SceneTree"
	"graphics.gd/classdb/Sprite2D"
	"graphics.gd/classdb/Texture2D"
	"graphics.gd/variant/Angle"
	"graphics.gd/variant/Float"
	"graphics.gd/variant/Vector2"
)

type Sprite struct {
	Sprite2D.Extension[Sprite]

	angle      Angle.Radians
	speed      Float.X
	pos        Vector2.XY
	size2      Vector2.XY
	windowSize Vector2.XY
}

func NewSprite(texture Texture2D.Instance, fromNode Node.Instance) *Sprite {
	s := &Sprite{}
	s.angle = Angle.Radians(Float.RandomBetween(0, math.Pi*2))
	s.speed = Float.RandomBetween(100, 600)
	windowSize := SceneTree.Get(fromNode).Root().AsWindow().Size()
	s.pos = Vector2.New(windowSize.X/2, windowSize.Y/2)
	s.AsSprite2D().SetTexture(texture)
	s.AsNode2D().SetPosition(s.pos)
	s.size2 = Vector2.MulX(s.AsSprite2D().Texture().GetSize(), 0.5)
	s.windowSize = Vector2.New(windowSize.X, windowSize.Y)
	return s
}

func (s *Sprite) Process(delta Float.X) {
	s.pos = Vector2.Add(s.pos, Vector2.XY{
		X: Angle.Cos(s.angle) * s.speed * delta,
		Y: Angle.Sin(s.angle) * s.speed * delta,
	})
	s.AsNode2D().SetPosition(s.pos)
	if s.pos.X < s.size2.X || s.pos.X > Float.X(s.windowSize.X)-s.size2.X {
		s.angle = Angle.Pi - s.angle
	}
	if s.pos.Y < s.size2.Y || s.pos.Y > Float.X(s.windowSize.Y)-s.size2.Y {
		s.angle = -s.angle
	}
}
