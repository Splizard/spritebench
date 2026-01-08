using Godot;
using System;

public partial class Sprite : Sprite2D
{
	private static readonly Texture2D Icon = GD.Load<Texture2D>("res://icon.svg");
	private static readonly Vector2 Size2 = Icon.GetSize() / 2;

	private float _angle = (float)GD.RandRange(0, Mathf.Tau);
	private float _speed = (float)GD.RandRange(100, 600);
	private Vector2 _pos;
	private Vector2 _windowSize;

	public override void _Ready()
	{
		Texture = Icon;
		Position = (Vector2)GetWindow().Size / 2;
		_pos = Position;
		_windowSize = (Vector2)GetWindow().Size;
	}

	public override void _Process(double delta)
	{
		_pos += new Vector2(Mathf.Cos(_angle), Mathf.Sin(_angle)) * _speed * (float)delta;
		Position = _pos;

		if (Position.X < Size2.X || Position.X > _windowSize.X - Size2.X)
		{
			_angle = Mathf.Pi - _angle;
		}
		if (Position.Y < Size2.Y || Position.Y > _windowSize.Y - Size2.Y)
		{
			_angle = -_angle;
		}
	}
}
