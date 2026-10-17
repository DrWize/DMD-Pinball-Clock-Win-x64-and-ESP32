using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Input.Platform;
using Avalonia.Layout;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using DmdClock.App.Diagnostics;
using DmdClock.Core.Playback;
using DmdClock.Core.Screensaver;

namespace DmdClock.App;

public partial class MainWindow
{
    private bool _debugEnabled;
    private double _debugSpeed = 1;
    private string? _scenePath;
    private SceneResult? _lastSceneResult;
    private DebugApiServer? _apiServer;
    private string _apiStatus = "Disabled";
    private readonly SemaphoreSlim _apiGate = new(1, 1);
    private static readonly JsonSerializerOptions DebugJson = new(JsonSerializerDefaults.Web) { WriteIndented = true };

    internal void BeginScene(DmdClock.Core.Scn.ScnScene scene, string path)
    {
        var now = PlaybackClock.Now;
        _scenePath = path;
        _lastSceneResult = null;
        _playback = new ScenePlaybackSession(scene, now);
        _playback.SetSpeed(_debugSpeed, now);
        _playback.Restart(now);
        if (_isPaused) _playback.Pause(now);
        _displayMode = DisplayMode.Animation;
        Display.Frame = RenderPlaybackFrame(DateTimeOffset.Now);
        _playback.NotifyFrameSubmitted(PlaybackClock.Now);
        RefreshDebugOverlay();
    }

    private SceneResult? CurrentSceneResult() => _playback is null || _scenePath is null ? null :
        new(Path.GetFileName(_scenePath), _playback.GetDiagnostics(PlaybackClock.Now));

    internal DebugState Snapshot() => new(1, _buildId, Guid.NewGuid(), DateTimeOffset.UtcNow,
        _displayMode.ToString().ToLowerInvariant(), _debugEnabled, _isPaused, _debugSpeed,
        CurrentSceneResult(), _lastSceneResult);

    private void RefreshDebugOverlay()
    {
        DebugOverlay.IsVisible = _debugEnabled;
        if (!_debugEnabled) return;
        var result = CurrentSceneResult() ?? _lastSceneResult;
        DebugText.Text = result is null ? $"Debug timing · No scene · {_debugSpeed:0.0}×" : FormatDebug(result);
    }

    private static string FormatDebug(SceneResult result)
    {
        var d = result.Timing;
        var source = d.TimingNotSet ? $"Timing not set · Fallback: {d.FallbackFps:0.##} FPS" :
            d.TimingAdjusted ? $"File: {d.FileFps:0.##} FPS · {d.TimingLabel}" : $"File: {d.FileFps:0.##} FPS";
        var rate = d.MeasuredFrameUpdatesPerSecond is { } fps ? fps.ToString("0.0", CultureInfo.InvariantCulture) : "—";
        var state = d.Completed ? "Completed" : d.Paused ? "Paused" : "Playing";
        var qualification = d.Status is "Manually stepped" or "Speed changed" ? " · " + d.Status : "";
        return $"{result.File} · Frame {(d.FrameIndex < 0 ? "blank" : (d.FrameIndex + 1).ToString())}/{d.TotalFrames} · {state}{qualification}\n" +
            $"{source} · Delay: {d.FrameDelayMs:0.##} ms · Speed: {d.Speed:0.0}×\n" +
            $"Target: {d.AdjustedTargetFps:0.##} FPS · Updates/s: {rate} · Skipped: {d.SkippedFrames}\n" +
            $"Expected: {d.ExpectedDurationMs / 1000:0.###} s · Adjusted: {d.AdjustedDurationMs / 1000:0.###} s\n" +
            $"Elapsed: {d.ElapsedMs / 1000:0.###} s" + (d.ActualDurationMs is { } actual ? $" · Actual: {actual / 1000:0.###} s" : "");
    }

    private void SetDebugEnabled(bool enabled)
    {
        if (!enabled && _debugSpeed != 1) SetDebugSpeed(1);
        _debugEnabled = enabled;
        DebugToggleMenuItem.Header = enabled ? "Disable debug timing" : "Enable debug timing";
        RefreshDebugOverlay();
    }

    private void SetDebugSpeed(double speed)
    {
        if (!_debugEnabled) throw new InvalidOperationException("Enable debug timing first.");
        if (!double.IsFinite(speed) || speed < .1 || speed > 4 || Math.Abs(speed * 10 - Math.Round(speed * 10)) > .000001)
            throw new ArgumentOutOfRangeException(nameof(speed));
        _playback?.SetSpeed(speed, PlaybackClock.Now);
        _debugSpeed = speed;
        RefreshDebugOverlay();
    }

    private void RestartDebugScene()
    {
        if (_playback is null && _lastSceneResult is not null && _scenePath is not null)
            _playback = new ScenePlaybackSession(LoadPlaybackScene(_scenePath).Scene, PlaybackClock.Now);
        if (_playback is null) throw new InvalidOperationException("No scene to restart.");
        var now = PlaybackClock.Now;
        _playback.SetSpeed(_debugSpeed, now);
        _playback.Restart(now);
        if (_isPaused) _playback.Pause(now);
        _lastSceneResult = null;
        _displayMode = DisplayMode.Animation;
        Display.Frame = RenderPlaybackFrame(DateTimeOffset.Now);
        RefreshDebugOverlay();
    }

    internal DebugState ExecuteCommand(PlaybackCommand command)
    {
        switch (command.Action)
        {
            case "load-scene": LoadApiScene(command.ScenePath); break;
            case "debug-enable": SetDebugEnabled(true); break;
            case "debug-disable": SetDebugEnabled(false); break;
            case "set-speed": SetDebugSpeed(command.Speed ?? throw new ArgumentException("Speed required.")); break;
            case "pause": if (!_isPaused) TogglePause(); break;
            case "resume": if (_isPaused) TogglePause(); break;
            case "step-back":
            case "step-forward":
                if (_playback is null) throw new InvalidOperationException("No active scene.");
                MoveFrame(command.Action == "step-forward" ? 1 : -1); break;
            case "restart": RestartDebugScene(); break;
            default: throw new ArgumentException("Unknown playback action.");
        }
        RefreshDebugOverlay();
        return Snapshot();
    }

    private void LoadApiScene(string? relativePath)
    {
        if (string.IsNullOrWhiteSpace(relativePath)) throw new ArgumentException("Scene path required.");
        if (_libraryRoot is null) throw new InvalidOperationException("No scene library loaded.");
        // Only scenes already indexed in this library are selectable through the API.
        var item = _catalogItems.FirstOrDefault(item => item.LibraryItem.IsValid &&
            string.Equals(item.LibraryItem.RelativePath.Replace('\\', '/'), relativePath.Replace('\\', '/'),
                StringComparison.OrdinalIgnoreCase));
        if (item is null) throw new ArgumentException("Scene is not in the current library.");
        var path = Path.Combine(_libraryRoot, item.LibraryItem.RelativePath.Replace('/', Path.DirectorySeparatorChar));
        var (scene, metadata) = LoadPlaybackScene(path, item.LibraryItem.RelativePath);
        CancelInformationDisplay();
        _animationsRemainingInCycle = 0;
        _nextAnimationAtUtc = null;
        SetStatus(metadata.DisplayName);
        BeginScene(scene, path);
        LogDisplayedAnimation(path, scene.Frames.Count, metadata);
    }

    internal PngCapture CaptureDisplay(bool includeDebug)
    {
        // No await or playback advance between snapshot and rendering: all run on the UI thread.
        var state = Snapshot();
        var overlays = new[] { AnimationInfoOverlay, StartupBrandOverlay, UpdateAvailableOverlay, DebugOverlay };
        var visibility = overlays.Select(overlay => overlay.IsVisible).ToArray();
        try
        {
            foreach (var overlay in overlays) overlay.IsVisible = false;
            if (includeDebug)
            {
                var scene = state.Scene ?? state.LastSceneResult;
                DebugText.Text = scene is null ? "Debug timing · No scene" : FormatDebug(scene);
                DebugOverlay.IsVisible = true;
            }
            CaptureSurface.UpdateLayout();
            var scale = RenderScaling;
            var size = new PixelSize(Math.Max(1, (int)Math.Ceiling(CaptureSurface.Bounds.Width * scale)),
                Math.Max(1, (int)Math.Ceiling(CaptureSurface.Bounds.Height * scale)));
            if ((long)size.Width * size.Height > 16_000_000) throw new InvalidOperationException("Display too large to capture.");
            using var bitmap = new RenderTargetBitmap(size, new Vector(96 * scale, 96 * scale));
            bitmap.Render(CaptureSurface);
            using var stream = new MemoryStream();
            bitmap.Save(stream, PngBitmapEncoderOptions.Default);
            return new(state, stream.ToArray(), size.Width, size.Height);
        }
        finally
        {
            for (var index = 0; index < overlays.Length; index++) overlays[index].IsVisible = visibility[index];
            CaptureSurface.UpdateLayout();
        }
    }

    private async Task StopApiAsync()
    {
        await _apiGate.WaitAsync();
        try
        {
            if (_apiServer is { } server) { _apiServer = null; await server.DisposeAsync(); }
            _apiStatus = "Disabled";
        }
        finally { _apiGate.Release(); }
    }

    private async Task ConfigureApiAsync()
    {
        await _apiGate.WaitAsync();
        try
        {
            if (_apiServer is { } old) { _apiServer = null; await old.DisposeAsync(); }
            _apiStatus = "Disabled";
            if (!_settings.ApiEnabled || _launchOptions.Mode != ScreenSaverLaunchMode.Normal) return;
            if (string.IsNullOrWhiteSpace(_settings.ApiToken))
            {
                _settings = _settings with { ApiToken = NewApiToken() };
                await _settingsStore.SaveAtomicAsync(_settings, _settingsPath);
            }
            var server = new DebugApiServer(_settings.ApiPort, _settings.ApiToken!,
                async () => await Dispatcher.UIThread.InvokeAsync(Snapshot),
                async command => await Dispatcher.UIThread.InvokeAsync(() => ExecuteCommand(command)),
                async includeDebug => await Dispatcher.UIThread.InvokeAsync(() => CaptureDisplay(includeDebug)));
            try
            {
                await server.StartAsync();
                _apiServer = server;
                _apiStatus = $"Listening on LAN · http://{System.Net.Dns.GetHostName()}:{_settings.ApiPort}";
            }
            catch (Exception exception) when (exception is IOException or System.Net.Sockets.SocketException)
            {
                await server.DisposeAsync();
                _apiStatus = $"Unable to listen on port {_settings.ApiPort}: {exception.Message}";
                SetStatus(_apiStatus);
            }
        }
        finally { _apiGate.Release(); }
    }

    private static string NewApiToken() => Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
    private void DebugToggle_Click(object? sender, RoutedEventArgs e) => SetDebugEnabled(!_debugEnabled);
    private void DebugSlower_Click(object? sender, RoutedEventArgs e) { if (_debugEnabled) SetDebugSpeed(Math.Round(Math.Max(.1, _debugSpeed - .1), 1)); }
    private void DebugFaster_Click(object? sender, RoutedEventArgs e) { if (_debugEnabled) SetDebugSpeed(Math.Round(Math.Min(4, _debugSpeed + .1), 1)); }
    private void DebugReset_Click(object? sender, RoutedEventArgs e) { if (_debugEnabled) SetDebugSpeed(1); }
    private void DebugRestart_Click(object? sender, RoutedEventArgs e) { if (_playback is not null || _lastSceneResult is not null) RestartDebugScene(); }
    private async void DebugCopy_Click(object? sender, RoutedEventArgs e)
    {
        if (Clipboard is { } clipboard) await clipboard.SetTextAsync(JsonSerializer.Serialize(Snapshot(), DebugJson));
    }

    private async void ApiSettings_Click(object? sender, RoutedEventArgs e)
    {
        var dialog = new Window { Title = "LAN API settings", Width = 540, Height = 350, CanResize = false };
        var enabled = new CheckBox { Content = "Enable authenticated LAN API", IsChecked = _settings.ApiEnabled };
        var port = new NumericUpDown { Minimum = 1024, Maximum = 65535, Value = _settings.ApiPort, Increment = 1, FormatString = "0" };
        var status = new TextBlock { Text = _apiStatus, TextWrapping = Avalonia.Media.TextWrapping.Wrap };
        var copy = new Button { Content = "Copy API token" };
        var regenerate = new Button { Content = "Generate new token" };
        var token = _settings.ApiToken ?? NewApiToken();
        copy.Click += async (_, _) => { if (Clipboard is { } clipboard) await clipboard.SetTextAsync(token); };
        regenerate.Click += (_, _) => { token = NewApiToken(); status.Text = "New token generated. Save to activate it."; };
        var save = new Button { Content = "Save" };
        save.Click += async (_, _) =>
        {
            save.IsEnabled = false;
            try
            {
                _settings = _settings with { ApiEnabled = enabled.IsChecked == true, ApiPort = (int)(port.Value ?? 17891), ApiToken = token };
                await _settingsStore.SaveAtomicAsync(_settings, _settingsPath);
                await ConfigureApiAsync();
                status.Text = _apiStatus;
            }
            finally { save.IsEnabled = true; }
        };
        dialog.Content = new StackPanel { Margin = new Thickness(16), Spacing = 10, Children =
        {
            enabled, new TextBlock { Text = "Port (HTTP)" }, port, status,
            new TextBlock { Text = "Bearer token required for every request. Use a trusted LAN.\nNo firewall rules are added automatically." },
            new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { copy, regenerate } }, save
        } };
        await dialog.ShowDialog(this);
    }
}
