using Godot;
using System;

public partial class Main : Node2D
{
	private const int FrameCount = 1_000;
	private const int StartFrame = 100;
	private const int SpriteCount = 20_000;

	private float[] _frameTimes = new float[FrameCount];
	private int _currentFrame = 0;
	private int _frameIndex = 0;

	// Called when the node enters the scene tree for the first time.
	public override void _Ready()
	{
		for (int i = 0; i < SpriteCount; i++)
		{
			AddChild(new Sprite());
		}
	}

	// Called every frame. 'delta' is the elapsed time since the previous frame.
	public override void _Process(double delta)
	{
		_currentFrame++;

		if (_currentFrame >= StartFrame)
		{
			if (_frameIndex == _frameTimes.Length)
			{
				foreach (var child in GetChildren())
				{
					child.QueueFree();
				}

				var edit = new TextEdit();
				string[] s = new string[_frameTimes.Length];
				for (int i = 0; i < _frameTimes.Length; i++)
				{
					s[i] = _frameTimes[i].ToString(System.Globalization.CultureInfo.InvariantCulture);
				}
				edit.Text = string.Join("\n", s);
				edit.Size = (Vector2)GetWindow().Size;
				AddChild(edit);
			}
			else if (_frameIndex < _frameTimes.Length)
			{
				_frameTimes[_frameIndex] = (float)delta;
			}
			_frameIndex++;
		}
	}
}
