using Godot;
using System;
using System.Collections.Generic;

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
public partial class Main : Node2D
{
	private const int GlobalWarmup = 100;
	private const int WindowWarmup = 40;
	private const int WindowMeasure = 120;
	private const int StartCount = 20_000;
	private const int MinCount = 1_250;
	private const int MaxCount = 2_560_000;
	private const double Sustain = 0.95;
	private const int RefineRounds = 6;
	private const int LowIndex = WindowMeasure * 99 / 100;
	private const int VerifyWindows = 3;
	private const int VerifyStep = 16;

	private readonly List<Sprite> _sprites = new List<Sprite>();
	private readonly double[] _times = new double[WindowMeasure];
	private double _target = 60.0;
	private int _lo = 0;
	private int _hi = 0;
	private int _rounds = 0;
	private bool _verifying = false;
	private readonly List<double> _verifyFps = new List<double>();
	private int _globalFrame = 0;
	private int _windowFrame = 0;

	public override void _Ready()
	{
		double refresh = DisplayServer.ScreenGetRefreshRate();
		_target = refresh > 0 ? refresh : 60.0;
		SetCount(StartCount);
	}

	private void SetCount(int n)
	{
		while (_sprites.Count > n)
		{
			var sprite = _sprites[_sprites.Count - 1];
			_sprites.RemoveAt(_sprites.Count - 1);
			sprite.QueueFree();
		}
		while (_sprites.Count < n)
		{
			var sprite = new Sprite();
			_sprites.Add(sprite);
			AddChild(sprite);
		}
		_windowFrame = 0;
	}

	public override void _Process(double delta)
	{
		if (++_globalFrame <= GlobalWarmup)
		{
			return;
		}
		if (++_windowFrame <= WindowWarmup)
		{
			return;
		}
		int i = _windowFrame - WindowWarmup - 1;
		_times[i] = delta;
		if (i < WindowMeasure - 1)
		{
			return;
		}

		double[] sorted = (double[])_times.Clone();
		Array.Sort(sorted);
		double fps = 1.0 / sorted[LowIndex];
		bool sustained = fps >= Sustain * _target;
		int count = _sprites.Count;

		if (_verifying)
		{
			_verifyFps.Add(fps);
			if (_verifyFps.Count < VerifyWindows)
			{
				SetCount(count);
				return;
			}
			_verifyFps.Sort();
			double median = _verifyFps[VerifyWindows / 2];
			_verifyFps.Clear();
			if (median >= Sustain * _target)
			{
				Report(count, median);
			}
			else if (count <= MinCount)
			{
				Report(0, median);
			}
			else
			{
				SetCount(Math.Max(count - count / VerifyStep, MinCount));
			}
			return;
		}
		if (sustained)
		{
			_lo = count;
		}
		else
		{
			_hi = count;
		}
		if (!sustained && count <= MinCount)
		{
			Report(0, fps);
			return;
		}
		if (sustained && count >= MaxCount)
		{
			_verifying = true;
			SetCount(count);
			return;
		}
		if (_hi == 0)
		{
			SetCount(count * 2);
		}
		else if (_lo == 0)
		{
			SetCount(Math.Max(count / 2, MinCount));
		}
		else
		{
			if (++_rounds > RefineRounds)
			{
				_verifying = true;
				SetCount(_lo);
				return;
			}
			SetCount((_lo + _hi) / 2);
		}
	}

	private void Report(int count, double fps)
	{
		string line = string.Format(System.Globalization.CultureInfo.InvariantCulture,
			"{0} {1} {2:F2}", count, (int)Math.Round(_target), fps);

		if (OS.HasFeature("ios"))
		{
			// iOS os_log redacts dynamic strings as <private>, so
			// console scraping is useless. Write to the app sandbox
			// (user data dir) and pull it off the device via AFC.
			System.IO.File.WriteAllText(
				ProjectSettings.GlobalizePath("user://spritebench_results.csv"),
				line + "\n");
			GetTree().Quit();
			return;
		}

		if (OS.HasFeature("web") || OS.HasFeature("android"))
		{
			// Captured from the browser console / logcat by the
			// automated benchmark.
			GD.Print("SPRITEBENCH_RESULTS_BEGIN");
			GD.Print(line);
			GD.Print("SPRITEBENCH_RESULTS_END");
			GetTree().Quit();
			return;
		}

		string outputPath = OS.GetEnvironment("SPRITEBENCH_OUTPUT");
		if (!string.IsNullOrEmpty(outputPath))
		{
			System.IO.File.WriteAllText(outputPath, line + "\n");
			GetTree().Quit();
			return;
		}

		var edit = new TextEdit();
		edit.Text = line;
		edit.Size = (Vector2)GetWindow().Size;
		AddChild(edit);
		SetProcess(false);
	}
}
