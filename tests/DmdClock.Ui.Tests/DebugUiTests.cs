using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.Input;
using Avalonia.Themes.Fluent;
using DmdClock.App;
using DmdClock.App.Diagnostics;
using DmdClock.Core.Scn;
using DmdClock.Core.Screensaver;
using SkiaSharp;

[assembly: AvaloniaTestApplication(typeof(DmdClock.Core.Tests.Playback.DebugTestApp))]

namespace DmdClock.Core.Tests.Playback;

public class DebugTestApp : Application
{
    public override void Initialize() => Styles.Add(new FluentTheme());
    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<DebugTestApp>()
        .UseSkia().WithInterFont().UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false });
}

public class DebugUiTests
{
    private static MainWindow CreateWindow()
    {
        var window = new MainWindow(new ScreenSaverLaunchOptions(ScreenSaverLaunchMode.Normal, 0), initializeRuntime: false);
        window.Show();
        var scene = new ScnScene(1, [new(0, false, false, 100, false, 0, false, false, 0, 0, 0)],
            [new DmdFrame(128, 32, new byte[4096]), new DmdFrame(128, 32, Enumerable.Repeat((byte)15, 4096).ToArray())]);
        window.BeginScene(scene, "test.scn");
        window.ExecuteCommand(new("pause"));
        return window;
    }

    [AvaloniaFact]
    public void CaptureMatchesPausedFrameAndOptionalOverlayIsRestored()
    {
        var window = CreateWindow();
        try
        {
            var first = window.CaptureDisplay(false);
            using var dark = SKBitmap.Decode(first.Png);
            Assert.NotNull(dark);
            Assert.Equal(first.Width, dark.Width);
            Assert.Equal(first.Height, dark.Height);
            Assert.Equal(0, first.State.Scene!.Timing.FrameIndex);
            Assert.True(first.State.Scene.Timing.Paused);
            window.ExecuteCommand(new("step-forward"));
            var second = window.CaptureDisplay(false);
            using var light = SKBitmap.Decode(second.Png);
            Assert.Equal(1, second.State.Scene!.Timing.FrameIndex);
            Assert.NotEqual(first.Png, second.Png);
            Assert.True(light.Pixels.Average(pixel => (double)pixel.Red) > dark.Pixels.Average(pixel => (double)pixel.Red));
            var overlay = window.CaptureDisplay(true);
            Assert.NotEqual(second.Png, overlay.Png);
            if (Environment.GetEnvironmentVariable("DMD_TEST_ARTIFACTS") is { } artifacts)
            {
                Directory.CreateDirectory(artifacts);
                File.WriteAllBytes(Path.Combine(artifacts, "debug-capture.png"), overlay.Png);
                File.WriteAllText(Path.Combine(artifacts, "debug-capture.json"),
                    System.Text.Json.JsonSerializer.Serialize(overlay.State,
                        new System.Text.Json.JsonSerializerOptions(System.Text.Json.JsonSerializerDefaults.Web) { WriteIndented = true }));
            }
            Assert.False(window.FindControl<Border>("DebugOverlay")!.IsVisible);
            Assert.Equal(second.Png, window.CaptureDisplay(false).Png);
        }
        finally { window.Close(); }
    }

    [AvaloniaFact]
    public async Task CompletedResultsRemainUntilNextSceneAndSpeedCarriesAcrossScenes()
    {
        var window = CreateWindow();
        try
        {
            window.ExecuteCommand(new("resume"));
            await Task.Delay(250);
            window.Tick();
            // A stalled UI must still show the final frame for its full hold.
            Assert.Equal(1, window.Snapshot().Scene!.Timing.FrameIndex);
            Assert.False(window.Snapshot().Scene!.Timing.Completed);
            await Task.Delay(110);
            window.Tick();
            var done = window.Snapshot();
            Assert.Null(done.Scene);
            Assert.Equal("test.scn", done.LastSceneResult!.File);
            Assert.True(done.LastSceneResult.Timing.Completed);
            Assert.True(done.LastSceneResult.Timing.ActualDurationMs >= 200);
            window.ExecuteCommand(new("debug-enable"));
            window.ExecuteCommand(new("set-speed", .5));
            var scene = new ScnScene(1, [], [new DmdFrame(128, 32, new byte[4096])]);
            window.BeginScene(scene, "next.scn");
            var next = window.Snapshot();
            Assert.Null(next.LastSceneResult);
            Assert.Equal(.5, next.Scene!.Timing.Speed);
            Assert.Equal("Timing not set", next.Scene.Timing.TimingLabel);
            Assert.Equal(200, next.Scene.Timing.AdjustedDurationMs);
            Assert.Equal("Playing", next.Scene.Timing.Status);
            window.ExecuteCommand(new("restart"));
            Assert.Equal(.5, window.Snapshot().Speed);
        }
        finally { window.Close(); }
    }

    [AvaloniaFact]
    public void KeyboardControlsPauseStepAndClampDebugSpeed()
    {
        var window = CreateWindow();
        try
        {
            window.KeyPress(Key.Space, RawInputModifiers.None, PhysicalKey.None, null);
            Assert.False(window.Snapshot().Paused);
            window.KeyPress(Key.OemPeriod, RawInputModifiers.None, PhysicalKey.None, null);
            Assert.True(window.Snapshot().Paused);
            Assert.Equal(1, window.Snapshot().Scene!.Timing.FrameIndex);
            window.KeyPress(Key.OemComma, RawInputModifiers.None, PhysicalKey.None, null);
            Assert.Equal(0, window.Snapshot().Scene!.Timing.FrameIndex);
            Assert.Throws<InvalidOperationException>(() => window.ExecuteCommand(new("set-speed", .5)));
            window.ExecuteCommand(new("debug-enable"));
            window.KeyPress(Key.Down, RawInputModifiers.None, PhysicalKey.None, null);
            Assert.Equal(.9, window.Snapshot().Speed);
            window.KeyPress(Key.Up, RawInputModifiers.None, PhysicalKey.None, null);
            Assert.Equal(1, window.Snapshot().Speed);
            window.ExecuteCommand(new("set-speed", .1));
            window.KeyPress(Key.Down, RawInputModifiers.None, PhysicalKey.None, null);
            Assert.Equal(.1, window.Snapshot().Speed);
            window.ExecuteCommand(new("set-speed", 4));
            window.KeyPress(Key.Up, RawInputModifiers.None, PhysicalKey.None, null);
            Assert.Equal(4, window.Snapshot().Speed);
            window.ExecuteCommand(new("debug-disable"));
            Assert.Equal(1, window.Snapshot().Speed);
            Assert.False(window.Snapshot().DebugEnabled);
        }
        finally { window.Close(); }
    }
}
