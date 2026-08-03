using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using DmdClock.Core;
using DmdClock.App.Logging;
using DmdClock.App.Localization;
using DmdClock.App.Rendering;
using DmdClock.App.Screensaver;
using DmdClock.Core.Clock;
using DmdClock.Core.Library;
using DmdClock.Core.Playback;
using DmdClock.Core.Rendering;
using DmdClock.Core.Scn;
using DmdClock.Core.Settings;
using DmdClock.Core.Screensaver;
using DmdClock.Core.Update;

namespace DmdClock.App;

public partial class MainWindow : Window
{
    private static readonly TimeSpan AnimationInformationDuration = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan StartupBrandDuration = TimeSpan.FromSeconds(4);
    private static readonly TimeSpan MouseCursorHideDelay = TimeSpan.FromSeconds(5);
    private const double DefaultWindowWidth = 1024;
    private const double DefaultWindowHeight = 256;
    private const string HelpGitHubUrl = "https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32";
    private const string LatestReleaseUrl = "https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/releases/latest";
    private readonly DispatcherTimer _displayTimer;
    private readonly DispatcherTimer _cursorHideTimer;
    private readonly Cursor _hiddenCursor = new(StandardCursorType.None);
    private readonly AnimationLibraryScanner _libraryScanner = new();
    private readonly AnimationLibraryStore _libraryStore = new();
    private readonly SceneMetadataStore _metadataStore = new();
    private readonly AnimationSelectionStore _selectionStore = new();
    private readonly SemaphoreSlim _scanGate = new(1, 1);
    private readonly string _indexPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DmdClock", "library-index.json");
    private readonly AppFileLogger _log = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DmdClock", "logs", "dmdclock.log"));
    private readonly DmdClockSettingsStore _settingsStore = new();
    private readonly string _settingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DmdClock", "settings.json");
    private readonly string _selectionPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DmdClock", "library-selections.json");
    private readonly List<AnimationLibraryItem> _playableItems = [];
    private readonly List<AnimationCatalogItem> _catalogItems = [];
    private readonly Dictionary<MenuItem, string?> _clockFontItems = [];
    private readonly Dictionary<MenuItem, string?> _dateFontItems = [];
    private readonly Stopwatch _effectClock = Stopwatch.StartNew();
    private readonly DateTimeOffset _startedUtc = DateTimeOffset.UtcNow;
    private readonly string _buildId = GetBuildId();
    private readonly ScreenSaverLaunchOptions _launchOptions;
    private ScenePlaybackSession? _playback;
    private AnimationLibraryIndex? _libraryIndex;
    private SceneMetadataCatalog _sceneMetadata = SceneMetadataCatalog.Empty;
    private FileSystemWatcher? _libraryWatcher;
    private FileSystemWatcher? _selectionWatcher;
    private CancellationTokenSource? _rescanCancellation;
    private CancellationTokenSource? _selectionReloadCancellation;
    private CancellationTokenSource? _informationCancellation;
    private readonly CancellationTokenSource _startupBrandCancellation = new();
    private readonly CancellationTokenSource _updateCheckCancellation = new();
    private DisplayMode _displayMode = DisplayMode.Time;
    private WindowState _windowStateBeforeFullscreen = WindowState.Normal;
    private DateTimeOffset _lastClockRender = DateTimeOffset.MinValue;
    private DateTimeOffset _clockUntilUtc = DateTimeOffset.MinValue;
    private DateTimeOffset? _nextAnimationAtUtc;
    private string? _libraryRoot;
    private int _libraryPosition = -1;
    private bool _isPaused;
    private bool _randomMode;
    private bool _automaticStartInProgress;
    private bool _startupBrandVisible = true;
    private bool _exitRequestedByMenu;
    private int _animationsRemainingInCycle;
    private string? _status;
    private string? _lastLoggedDisplay;
    private DmdClockSettings _settings = DmdClockSettings.Default;
    private AnimationSelectionDocument _selectionDocument = AnimationSelectionDocument.Empty;
    private Point? _screenSaverMouseOrigin;
    private bool _pointerIsOverWindow;

    public MainWindow() : this(new ScreenSaverLaunchOptions(ScreenSaverLaunchMode.Normal, 0)) { }

    internal MainWindow(ScreenSaverLaunchOptions launchOptions)
    {
        _launchOptions = launchOptions;
        InitializeComponent();
        ConfigureColorSwatches();
        ConfigureLaunchMode();
        LogStartup();
        _displayTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
        _displayTimer.Tick += (_, _) => Tick();
        _cursorHideTimer = new DispatcherTimer { Interval = MouseCursorHideDelay };
        _cursorHideTimer.Tick += (_, _) => HideInactiveCursor();
        Show(DisplayMode.Time);
        _displayTimer.Start();
        Opened += OnOpened;
        Closed += OnClosed;
        Dispatcher.UIThread.Post(() => _ = InitializeDefaultLibraryAsync());
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);

        if (_launchOptions.Mode == ScreenSaverLaunchMode.Fullscreen)
        {
            Close();
            e.Handled = true;
            return;
        }
        if (_launchOptions.Mode == ScreenSaverLaunchMode.Preview) return;

        if (e.Key == Key.O && e.KeyModifiers == KeyModifiers.Control)
            _ = OpenSceneAsync();
        else if (e.Key == Key.O && e.KeyModifiers == (KeyModifiers.Control | KeyModifiers.Shift))
            _ = ChooseFolderAsync();
        else if (e.Key == Key.R && e.KeyModifiers == (KeyModifiers.Control | KeyModifiers.Shift))
            _ = OpenSceneReviewerAsync();
        else
        {
            switch (e.Key)
            {
                case Key.Space: TogglePause(); break;
                case Key.T: Show(DisplayMode.Time); break;
                case Key.D: Show(DisplayMode.Date); break;
                case Key.I: ToggleAnimationInformation(); break;
                case Key.F11: ToggleFullscreen(); break;
                case Key.OemPlus:
                case Key.Add: AdjustDisplaySize(5); break;
                case Key.OemMinus:
                case Key.Subtract: AdjustDisplaySize(-5); break;
                case Key.D0:
                case Key.NumPad0: ResetDisplaySize(); break;
                case Key.F5: _ = ScanLibraryAsync(startPlayback: false); break;
                case Key.Right: MoveFrame(1); break;
                case Key.Left: MoveFrame(-1); break;
                case Key.N: _ = PlayLibraryOffsetAsync(1); break;
                case Key.P: _ = PlayLibraryOffsetAsync(-1); break;
                case Key.Escape when WindowState == WindowState.FullScreen:
                    LeaveFullscreen();
                    break;
                default: return;
            }
        }

        e.Handled = true;
    }

    private void Tick()
    {
        if (_launchOptions.Mode == ScreenSaverLaunchMode.Preview &&
            !ScreenSaverPreviewHost.ParentExists(_launchOptions.PreviewParent))
        {
            Close();
            return;
        }
        if (_isPaused) return;
        var now = DateTimeOffset.UtcNow;
        Display.SetEffectTime(_effectClock.ElapsedMilliseconds);

        if (_displayMode == DisplayMode.Animation && _playback is not null)
        {
            var changed = _playback.Advance(now);
            var localNow = DateTimeOffset.Now;
            if (changed || localNow.Second != _lastClockRender.Second || localNow.Minute != _lastClockRender.Minute)
            {
                _lastClockRender = localNow;
                Display.Frame = RenderPlaybackFrame(localNow);
            }
            if (_playback.IsComplete) HandlePlaybackCompleted();
            return;
        }

        if (_displayMode == DisplayMode.Animation) return;

        if (now.Second != _lastClockRender.Second || now.Minute != _lastClockRender.Minute)
            UpdateClockOrDate();

        if (_nextAnimationAtUtc is not null)
        {
            if (now >= _nextAnimationAtUtc && !_automaticStartInProgress)
            {
                _nextAnimationAtUtc = null;
                _automaticStartInProgress = true;
                _ = ContinueAutomaticCycleAsync();
            }
            return;
        }

        if (_displayMode == DisplayMode.Time && _settings.AutomaticCycle && _playableItems.Count > 0 &&
            now >= _clockUntilUtc && !_automaticStartInProgress)
        {
            _automaticStartInProgress = true;
            _ = BeginAutomaticCycleAsync();
        }
    }

    private async Task OpenSceneAsync()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Öppna DotClk-animation",
            AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType("DotClk scene") { Patterns = ["*.scn"] }]
        });
        var path = files.FirstOrDefault()?.TryGetLocalPath();
        if (path is not null) await LoadAndPlayAsync(path);
    }

    private async Task ChooseFolderAsync()
    {
        var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions
        {
            Title = "Välj animationsmapp",
            AllowMultiple = false
        });
        var path = folders.FirstOrDefault()?.TryGetLocalPath();
        if (path is null) return;

        _libraryRoot = Path.GetFullPath(path);
        _settings = (_settings with { AnimationDirectory = _libraryRoot }).Normalize();
        SaveSettings();
        await ScanLibraryAsync(startPlayback: true);
        StartLibraryWatcher();
    }

    private async Task DownloadScenesAsync()
    {
        var destination = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DmdClock", "Scenes", "DotClk");
        var dialog = new SceneDownloadWindow(
            destination,
            L("downloadScenesTitle"),
            L("downloadScenesDescription"),
            L("viewSceneSource"),
            L("download"),
            L("cancel"));
        var result = await dialog.ShowDialog<ScenePackInstallResult?>(this);
        if (result is null) return;

        _libraryRoot = result.DestinationDirectory;
        _settings = (_settings with { AnimationDirectory = _libraryRoot }).Normalize();
        SaveSettings();
        await ScanLibraryAsync(startPlayback: true);
        StartLibraryWatcher();
        SetStatus(string.Format(
            System.Globalization.CultureInfo.CurrentCulture,
            L("scenesInstalled"),
            result.SceneCount));
        await _log.WriteAsync(DateTimeOffset.UtcNow,
            $"scenes.download status=success count={result.SceneCount} bytes={result.DownloadedBytes} " +
            $"root=\"{SanitizeLogValue(result.DestinationDirectory)}\" source=\"{ScenePackDownloader.SourceUrl}\"");
    }

    private async Task ScanLibraryAsync(bool startPlayback)
    {
        if (_libraryRoot is null) return;
        await _scanGate.WaitAsync();
        var scanStartedUtc = DateTimeOffset.UtcNow;
        Exception? scanError = null;
        await _log.WriteAsync(scanStartedUtc, $"scan.start root=\"{_libraryRoot}\" startUtc={scanStartedUtc:O}");
        SetStatus("Skannar bibliotek…");
        try
        {
            await LoadSceneMetadataAsync();
            var stored = await _libraryStore.LoadAsync(_indexPath);
            var previous = stored is not null &&
                           string.Equals(stored.RootPath, _libraryRoot, StringComparison.OrdinalIgnoreCase)
                ? stored
                : _libraryIndex;
            _libraryIndex = await Task.Run(() => _libraryScanner.ScanAsync(_libraryRoot, previous));
            await _libraryStore.SaveAtomicAsync(_libraryIndex, _indexPath);

            _catalogItems.Clear();
            _catalogItems.AddRange(AnimationSelectionResolver.BuildCatalog(
                _libraryIndex.Items, _sceneMetadata));
            RebuildPlayableItems();

            var broken = _libraryIndex.Items.Count(static item => !item.IsValid);
            var warned = _libraryIndex.Items.Count(static item =>
                item.IsValid && (item.Warnings?.Count ?? 0) > 0);
            foreach (var item in _libraryIndex.Items)
            {
                foreach (var warning in item.Warnings ?? [])
                {
                    await _log.WriteAsync(DateTimeOffset.UtcNow,
                        $"scan.file status=warned path=\"{SanitizeLogValue(item.RelativePath)}\" " +
                        $"code=\"{SanitizeLogValue(warning.Code)}\" " +
                        $"reason=\"{SanitizeLogValue(warning.Message)}\"");
                }

                if (!item.IsValid)
                {
                    await _log.WriteAsync(DateTimeOffset.UtcNow,
                        $"scan.file status=rejected path=\"{SanitizeLogValue(item.RelativePath)}\" " +
                        $"reason=\"{SanitizeLogValue(item.Error ?? "Unknown SCN error.")}\"");
                }
            }

            SetStatus(
                $"{_playableItems.Count} animationer" +
                (warned > 0 ? $", {warned} varningar" : string.Empty) +
                (broken > 0 ? $", {broken} fel" : string.Empty));
            if (startPlayback && _playableItems.Count > 0) await PlayLibraryOffsetAsync(1);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            scanError = exception;
            SetStatus($"Biblioteksfel: {exception.Message}");
        }
        catch (Exception exception)
        {
            scanError = exception;
            throw;
        }
        finally
        {
            var scanEndedUtc = DateTimeOffset.UtcNow;
            var duration = scanEndedUtc - scanStartedUtc;
            var total = _libraryIndex?.Items.Count ?? 0;
            var valid = _libraryIndex?.Items.Count(static item => item.IsValid) ?? 0;
            var warned = _libraryIndex?.Items.Count(static item =>
                item.IsValid && (item.Warnings?.Count ?? 0) > 0) ?? 0;
            var accepted = valid - warned;
            var rejected = total - valid;
            var status = scanError is null ? "success" : "failed";
            var error = scanError is null ? string.Empty : $" error=\"{SanitizeLogValue(scanError.Message)}\"";
            await _log.WriteAsync(scanEndedUtc,
                $"scan.end status={status} root=\"{_libraryRoot}\" startUtc={scanStartedUtc:O} " +
                $"endUtc={scanEndedUtc:O} durationMs={duration.TotalMilliseconds:F0} " +
                $"files={total} accepted={accepted} warned={warned} rejected={rejected} " +
                $"valid={valid} failures={rejected}{error}");
            _scanGate.Release();
        }
    }

    private async Task LoadAndPlayAsync(string path, string? relativePath = null)
    {
        CancelInformationDisplay();
        try
        {
            var scene = await Task.Run(() => ScnReader.Read(path));
            var metadata = ResolveSceneMetadata(path, relativePath);
            SetStatus(metadata.DisplayName);

            var now = DateTimeOffset.UtcNow;
            _playback = new ScenePlaybackSession(scene, now);
            if (_isPaused) _playback.Pause(now);
            _displayMode = DisplayMode.Animation;
            Display.Frame = RenderPlaybackFrame(DateTimeOffset.Now);
            LogDisplayedAnimation(path, scene.Frames.Count, metadata);

            if (_settings.ShowAnimationInfo ?? true)
            {
                var sequence = metadata.Title ?? Path.GetFileNameWithoutExtension(metadata.FileName);
                var cancellation = new CancellationTokenSource();
                _informationCancellation = cancellation;
                AnimationGameText.Text = metadata.Game ?? "Okänt spel";
                AnimationSequenceText.Text = sequence;
                AnimationInfoOverlay.IsVisible = true;
                LogDisplayedInformation(path, metadata, sequence);
                try
                {
                    await Task.Delay(AnimationInformationDuration, cancellation.Token);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                finally
                {
                    if (ReferenceEquals(_informationCancellation, cancellation))
                    {
                        _informationCancellation = null;
                        AnimationInfoOverlay.IsVisible = false;
                    }
                    cancellation.Dispose();
                }
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            SetStatus($"Kan inte spela {Path.GetFileName(path)}: {exception.Message}");
            Show(DisplayMode.Time);
        }
    }

    private async Task PlayLibraryOffsetAsync(int offset, bool automatic = false)
    {
        if (_libraryRoot is null || _playableItems.Count == 0) return;
        if (!automatic)
        {
            _animationsRemainingInCycle = 0;
            _nextAnimationAtUtc = null;
        }
        if (_randomMode && offset > 0)
            _libraryPosition = Random.Shared.Next(_playableItems.Count);
        else
            _libraryPosition = (_libraryPosition + offset + _playableItems.Count) % _playableItems.Count;

        var item = _playableItems[_libraryPosition];
        await LoadAndPlayAsync(
            Path.Combine(_libraryRoot, item.RelativePath.Replace('/', Path.DirectorySeparatorChar)),
            item.RelativePath);
    }

    private void MoveFrame(int offset)
    {
        if (_playback is null) return;
        var now = DateTimeOffset.UtcNow;
        if (offset > 0) _playback.MoveNext(now); else _playback.MovePrevious(now);
        if (_isPaused) _playback.Pause(now);
        _displayMode = DisplayMode.Animation;
        Display.Frame = RenderPlaybackFrame(DateTimeOffset.Now);
    }

    private void TogglePause()
    {
        _isPaused = !_isPaused;
        if (_isPaused) _effectClock.Stop(); else _effectClock.Start();
        var now = DateTimeOffset.UtcNow;
        if (_playback is not null)
        {
            if (_isPaused) _playback.Pause(now); else _playback.Resume(now);
        }
        UpdateTitle();
    }

    private void Show(DisplayMode mode)
    {
        CancelInformationDisplay();
        _displayMode = mode;
        _playback = null;
        _animationsRemainingInCycle = 0;
        _nextAnimationAtUtc = null;
        if (mode == DisplayMode.Time)
            _clockUntilUtc = DateTimeOffset.UtcNow.AddSeconds(_settings.ClockDisplaySeconds);
        UpdateClockOrDate();
        LogDisplayedMode(mode);
    }

    private void UpdateClockOrDate()
    {
        var now = DateTimeOffset.Now;
        _lastClockRender = now;
        Display.Frame = _displayMode == DisplayMode.Date ? CreateDateFrame(now) : CreateClockFrame(now);
    }

    private DmdFrame RenderPlaybackFrame(DateTimeOffset now)
    {
        var playback = _playback ?? throw new InvalidOperationException("No scene is currently playing.");
        var storyboard = playback.Storyboard;
        var clock = storyboard.ClockStyle == 1
            ? ClockFrameFactory.CreateCompactTime(now, storyboard.CustomX, storyboard.CustomY, _settings.ClockFormat == "12")
            : CreateClockFrame(now);
        return DmdFrameCompositor.Compose(playback.CurrentFrame, clock, playback.ClockAbove);
    }

    private DmdFrame CreateClockFrame(DateTimeOffset now)
    {
        var fallback = () => ClockFrameFactory.Create(now, _settings.ClockFormat == "12", _settings.ShowSeconds ?? true);
        var format = _settings.ClockFormat == "12"
            ? ((_settings.ShowSeconds ?? true) ? "hh:mm:ss tt" : "hh:mm tt")
            : ((_settings.ShowSeconds ?? true) ? "HH:mm:ss" : "HH:mm");
        return CreateFontFrame(now.ToString(format, System.Globalization.CultureInfo.InvariantCulture),
            _settings.ClockFontFile, fallback);
    }

    private DmdFrame CreateDateFrame(DateTimeOffset now)
    {
        var format = _settings.DateFormat ?? "yyyy-MM-dd";
        return CreateFontFrame(now.ToString(format, System.Globalization.CultureInfo.InvariantCulture), _settings.DateFontFile,
            () => ClockFrameFactory.CreateDate(now, format));
    }

    private static DmdFrame CreateFontFrame(string text, string? relativeFontFile, Func<DmdFrame> fallback)
    {
        if (relativeFontFile is not null && EmbeddedDotClkFonts.IsEmbedded(relativeFontFile))
        {
            try { return EmbeddedDotClkFonts.Create(text, relativeFontFile); }
            catch (Exception exception) when (exception is InvalidDataException or InvalidOperationException or ArgumentException)
            {
                return fallback();
            }
        }

        var fontPath = ResolveFontPath(relativeFontFile);
        if (fontPath is null) return fallback();
        try { return OpenTypeDmdFrameFactory.Create(text, fontPath); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or
                                          ArgumentException or InvalidOperationException or TypeInitializationException)
        {
            return fallback();
        }
    }

    private void ToggleFullscreen()
    {
        if (WindowState == WindowState.FullScreen)
            LeaveFullscreen();
        else
        {
            _windowStateBeforeFullscreen = WindowState;
            WindowState = WindowState.FullScreen;
            ApplyDisplaySize();
        }
    }

    private void LeaveFullscreen()
    {
        WindowState = _windowStateBeforeFullscreen;
        ApplyDisplaySize();
    }

    private void AdjustDisplaySize(int deltaPercent)
    {
        if (WindowState == WindowState.FullScreen)
            _settings = (_settings with
            {
                FullscreenZoomPercent = (_settings.FullscreenZoomPercent ?? 100) + deltaPercent
            }).Normalize();
        else
            _settings = (_settings with
            {
                WindowScalePercent = (_settings.WindowScalePercent ?? 100) + deltaPercent
            }).Normalize();
        ApplyDisplaySize();
        ApplySettingsToMenu();
        SaveSettings();
        LogDisplaySize();
    }

    private void ResetDisplaySize()
    {
        _settings = WindowState == WindowState.FullScreen
            ? (_settings with { FullscreenZoomPercent = 100 }).Normalize()
            : (_settings with { WindowScalePercent = 100 }).Normalize();
        ApplyDisplaySize();
        ApplySettingsToMenu();
        SaveSettings();
        LogDisplaySize();
    }

    private void ApplyDisplaySize()
    {
        if (_launchOptions.Mode == ScreenSaverLaunchMode.Preview)
        {
            Display.Zoom = 1d;
            return;
        }
        if (WindowState == WindowState.FullScreen)
        {
            Display.Zoom = (_settings.FullscreenZoomPercent ?? 100) / 100d;
            return;
        }

        Display.Zoom = 1d;
        var scale = (_settings.WindowScalePercent ?? 100) / 100d;
        Width = DefaultWindowWidth * scale;
        Height = DefaultWindowHeight * scale;
    }

    private void LogDisplaySize()
    {
        var fullscreen = WindowState == WindowState.FullScreen;
        var percent = fullscreen ? _settings.FullscreenZoomPercent : _settings.WindowScalePercent;
        SetStatus($"{L("displaySize")}: {percent} %");
        _ = _log.WriteAsync(DateTimeOffset.UtcNow,
            $"display.scale mode={(fullscreen ? "fullscreen" : "window")} percent={percent}");
    }

    private void StartLibraryWatcher()
    {
        _libraryWatcher?.Dispose();
        if (_libraryRoot is null) return;
        _libraryWatcher = new FileSystemWatcher(_libraryRoot)
        {
            IncludeSubdirectories = true,
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size,
            EnableRaisingEvents = true
        };
        _libraryWatcher.Created += LibraryChanged;
        _libraryWatcher.Changed += LibraryChanged;
        _libraryWatcher.Deleted += LibraryChanged;
        _libraryWatcher.Renamed += LibraryChanged;
        _libraryWatcher.Error += (_, _) => ScheduleRescan();
    }

    private void StartSelectionWatcher()
    {
        _selectionWatcher?.Dispose();
        var directory = Path.GetDirectoryName(_selectionPath);
        if (directory is null) return;
        Directory.CreateDirectory(directory);
        _selectionWatcher = new FileSystemWatcher(directory, Path.GetFileName(_selectionPath))
        {
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size,
            EnableRaisingEvents = true
        };
        _selectionWatcher.Created += SelectionChanged;
        _selectionWatcher.Changed += SelectionChanged;
        _selectionWatcher.Renamed += SelectionChanged;
        _selectionWatcher.Error += (_, _) => ScheduleSelectionReload();
    }

    private void SelectionChanged(object sender, FileSystemEventArgs e) =>
        ScheduleSelectionReload();

    private void ScheduleSelectionReload()
    {
        var cancellation = new CancellationTokenSource();
        var previous = Interlocked.Exchange(ref _selectionReloadCancellation, cancellation);
        previous?.Cancel();
        _ = DebouncedSelectionReloadAsync(cancellation.Token);
    }

    private async Task DebouncedSelectionReloadAsync(CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(250, cancellationToken);
            var document = await _selectionStore.LoadAsync(_selectionPath, cancellationToken);
            Dispatcher.UIThread.Post(() =>
            {
                _selectionDocument = document;
                RebuildPlayableItems();
            });
        }
        catch (OperationCanceledException) { }
    }

    private void RebuildPlayableItems()
    {
        var currentId = _libraryPosition >= 0 && _libraryPosition < _playableItems.Count
            ? _playableItems[_libraryPosition].Id
            : null;
        _playableItems.Clear();
        _playableItems.AddRange(AnimationSelectionResolver.ResolvePlayable(
            _catalogItems, _selectionDocument));
        var validCount = _catalogItems.Count(static item => item.LibraryItem.IsValid);
        StartupAnimationCountText.Text = validCount == 0
            ? L("startupNoAnimations")
            : $"{_playableItems.Count:N0} allowed of {validCount:N0} animations";
        _libraryPosition = currentId is null
            ? -1
            : _playableItems.FindIndex(item => item.Id == currentId);
        if (_libraryPosition < -1) _libraryPosition = -1;
    }

    private void LibraryChanged(object sender, FileSystemEventArgs e)
    {
        if (string.Equals(Path.GetExtension(e.FullPath), ".scn", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(Path.GetFileName(e.FullPath), SceneMetadataStore.DefaultFileName, StringComparison.OrdinalIgnoreCase))
            ScheduleRescan();
    }

    private void ScheduleRescan()
    {
        var cancellation = new CancellationTokenSource();
        var previous = Interlocked.Exchange(ref _rescanCancellation, cancellation);
        previous?.Cancel();
        _ = DebouncedRescanAsync(cancellation.Token);
    }

    private async Task DebouncedRescanAsync(CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(750, cancellationToken);
            Dispatcher.UIThread.Post(() => _ = ScanLibraryAsync(startPlayback: false));
        }
        catch (OperationCanceledException) { }
    }

    private void SetStatus(string status)
    {
        _status = status;
        UpdateTitle();
    }

    private void UpdateTitle() => Title = "DMD Clock" +
        (_isPaused ? " — Pausad" : string.Empty) +
        (_status is null ? string.Empty : $" — {_status}");

    private static string SanitizeLogValue(string value) => value
        .Replace('\\', '/')
        .Replace('"', '\'')
        .Replace('\r', ' ')
        .Replace('\n', ' ');

    private void LogDisplayedMode(DisplayMode mode)
    {
        if (_startupBrandVisible) return;
        var type = mode == DisplayMode.Date ? "date" : "clock";
        LogDisplayChange(type, $"display.show type={type}");
    }

    private void LogDisplayedAnimation(string path, int frameCount, ResolvedSceneMetadata metadata)
    {
        var fullPath = Path.GetFullPath(path);
        var game = metadata.Game is null ? string.Empty : $" game=\"{SanitizeLogValue(metadata.Game)}\"";
        var title = metadata.Title is null ? string.Empty : $" title=\"{SanitizeLogValue(metadata.Title)}\"";
        var manufacturer = metadata.Manufacturer is null
            ? string.Empty
            : $" manufacturer=\"{SanitizeLogValue(metadata.Manufacturer)}\"";
        var year = metadata.Year is null ? string.Empty : $" year={metadata.Year}";
        LogDisplayChange($"animation:{fullPath}",
            $"display.show type=animation path=\"{SanitizeLogValue(fullPath)}\" " +
            $"file=\"{SanitizeLogValue(metadata.FileName)}\"{game}{title}{manufacturer}{year} frames={frameCount}");
    }

    private void LogDisplayedInformation(string path, ResolvedSceneMetadata metadata, string sequence)
    {
        var fullPath = Path.GetFullPath(path);
        var game = metadata.Game ?? "Okänt spel";
        LogDisplayChange($"information:{fullPath}",
            $"display.show type=information path=\"{SanitizeLogValue(fullPath)}\" " +
            $"file=\"{SanitizeLogValue(metadata.FileName)}\" game=\"{SanitizeLogValue(game)}\" " +
            $"sequence=\"{SanitizeLogValue(sequence)}\" durationMs={AnimationInformationDuration.TotalMilliseconds:F0}");
    }

    private ResolvedSceneMetadata ResolveSceneMetadata(string fullPath, string? relativePath)
    {
        if (relativePath is not null) return _sceneMetadata.Resolve(relativePath);
        if (_libraryRoot is not null)
        {
            var candidate = Path.GetRelativePath(_libraryRoot, fullPath);
            if (!candidate.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal) && candidate != "..")
                return _sceneMetadata.Resolve(candidate);
        }
        return SceneMetadataCatalog.Empty.Resolve(Path.GetFileName(fullPath));
    }

    private async Task LoadSceneMetadataAsync()
    {
        if (_libraryRoot is null) return;
        var path = Path.Combine(_libraryRoot, SceneMetadataStore.DefaultFileName);
        try
        {
            _sceneMetadata = await _metadataStore.LoadAsync(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or
                                          System.Text.Json.JsonException or ArgumentException)
        {
            _sceneMetadata = SceneMetadataCatalog.Empty;
            await _log.WriteAsync(DateTimeOffset.UtcNow,
                $"metadata.load status=failed path=\"{SanitizeLogValue(path)}\" " +
                $"error=\"{SanitizeLogValue(exception.Message)}\"");
        }
    }

    private void LogDisplayChange(string key, string message)
    {
        if (string.Equals(_lastLoggedDisplay, key, StringComparison.Ordinal)) return;
        _lastLoggedDisplay = key;
        _ = _log.WriteAsync(DateTimeOffset.UtcNow, message);
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        _displayTimer.Stop();
        _cursorHideTimer.Stop();
        Cursor = null;
        _hiddenCursor.Dispose();
        _startupBrandCancellation.Cancel();
        _startupBrandCancellation.Dispose();
        _updateCheckCancellation.Cancel();
        _updateCheckCancellation.Dispose();
        CancelInformationDisplay();
        _libraryWatcher?.Dispose();
        _selectionWatcher?.Dispose();
        _rescanCancellation?.Cancel();
        _rescanCancellation?.Dispose();
        _selectionReloadCancellation?.Cancel();
        _selectionReloadCancellation?.Dispose();
        var endedUtc = DateTimeOffset.UtcNow;
        var reason = _exitRequestedByMenu ? "menu" : "window";
        _log.WriteAsync(endedUtc,
                $"app.exit graceful=true reason={reason} build=\"{SanitizeLogValue(_buildId)}\" " +
                $"startedUtc={_startedUtc:O} endUtc={endedUtc:O} uptimeMs={(endedUtc - _startedUtc).TotalMilliseconds:F0}")
            .GetAwaiter().GetResult();
    }

    private void LogStartup()
    {
        var assemblyVersion = Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "unknown";
        _log.WriteAsync(_startedUtc,
                $"app.start build=\"{SanitizeLogValue(_buildId)}\" version={assemblyVersion} " +
                $"mode={_launchOptions.Mode.ToString().ToLowerInvariant()} " +
                $"pid={Environment.ProcessId} runtime=\"{SanitizeLogValue(RuntimeInformation.FrameworkDescription)}\" " +
                $"os=\"{SanitizeLogValue(RuntimeInformation.OSDescription)}\" startUtc={_startedUtc:O} " +
                $"basePath=\"{SanitizeLogValue(AppContext.BaseDirectory)}\"")
            .GetAwaiter().GetResult();
    }

    private static string GetBuildId() =>
        Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()
            ?.InformationalVersion ?? "unknown";

    private void OnOpened(object? sender, EventArgs e)
    {
        Opened -= OnOpened;
        if (_launchOptions.Mode == ScreenSaverLaunchMode.Preview &&
            !ScreenSaverPreviewHost.Attach(this, _launchOptions.PreviewParent))
        {
            Close();
            return;
        }
        LogDisplayChange("brand:alien-tech",
            $"display.show type=brand name=\"Alien Tech\" durationMs={StartupBrandDuration.TotalMilliseconds:F0}");
        StartupBuildText.Text = $"Build {_buildId} · checking for updates";
        if (_launchOptions.Mode == ScreenSaverLaunchMode.Normal)
            _ = CheckForUpdateAsync(_updateCheckCancellation.Token);
        _ = HideStartupBrandAsync(_startupBrandCancellation.Token);
    }

    private async Task CheckForUpdateAsync(CancellationToken cancellationToken)
    {
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(5));
            using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
            var result = await new ReleaseUpdateChecker(client)
                .CheckAsync(_buildId, timeout.Token);
            if (result?.UpdateAvailable == true)
            {
                StartupBuildText.Text =
                    $"Build {_buildId} · {result.LatestVersion} is available";
                UpdateAvailableText.Text =
                    $"DMDClock {result.LatestVersion} is available · click to download";
                UpdateAvailableOverlay.IsVisible = true;
            }
            else
            {
                StartupBuildText.Text = $"Build {_buildId} · up to date";
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception error)
        {
            StartupBuildText.Text = $"Build {_buildId}";
            await _log.WriteAsync(
                DateTimeOffset.UtcNow,
                $"update.check unavailable error=\"{SanitizeLogValue(error.Message)}\"");
        }
    }

    private void UpdateAvailable_PointerPressed(
        object? sender,
        PointerPressedEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo(LatestReleaseUrl)
            {
                UseShellExecute = true
            });
            e.Handled = true;
        }
        catch (Exception error)
        {
            SetStatus($"Could not open the latest release: {error.Message}");
        }
    }

    private async Task HideStartupBrandAsync(CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(StartupBrandDuration, cancellationToken);
            _startupBrandVisible = false;
            StartupBrandOverlay.IsVisible = false;
            if (_displayMode is DisplayMode.Time or DisplayMode.Date)
                LogDisplayedMode(_displayMode);
        }
        catch (OperationCanceledException) { }
    }

    private async Task InitializeDefaultLibraryAsync()
    {
        _settings = await _settingsStore.LoadAsync(_settingsPath);
        _selectionDocument = await _selectionStore.LoadAsync(_selectionPath);
        LoadLocalization(_settings.Language ?? "en");
        StartupAnimationCountText.Text = L("startupLoading");
        ApplyMenuTranslations(MainContextMenu.Items);
        PopulateFontMenus();
        _randomMode = _settings.RandomPlayback;
        ApplySettingsToMenu();
        ApplyDisplaySize();
        Show(DisplayMode.Time);
        _libraryRoot = ResolveScenesDirectory(_settings.AnimationDirectory);
        await ScanLibraryAsync(startPlayback: false);
        StartLibraryWatcher();
        StartSelectionWatcher();
        if (_launchOptions.Mode == ScreenSaverLaunchMode.Reviewer)
            await OpenSceneReviewerAsync();
    }

    private async Task OpenSceneReviewerAsync()
    {
        if (_launchOptions.Mode is ScreenSaverLaunchMode.Fullscreen or ScreenSaverLaunchMode.Preview)
            return;
        if (_libraryRoot is null || _libraryIndex is null)
        {
            SetStatus("Scan the scene library before opening the reviewer.");
            return;
        }
        if (_catalogItems.Count == 0)
        {
            SetStatus("No valid scenes are available to review.");
            return;
        }

        var reviewer = new SceneReviewerWindow(
            _libraryRoot,
            _catalogItems.ToArray(),
            _selectionStore,
            _selectionPath,
            _selectionDocument,
            _settings);
        await reviewer.ShowDialog(this);
        _selectionDocument = await _selectionStore.LoadAsync(_selectionPath);
        RebuildPlayableItems();
        SetStatus($"{_playableItems.Count:N0} scenes allowed for playback");
    }

    private async Task BeginAutomaticCycleAsync()
    {
        try
        {
            _animationsRemainingInCycle = _settings.AnimationsPerCycle;
            await PlayNextAutomaticAnimationAsync();
        }
        finally
        {
            _automaticStartInProgress = false;
        }
    }

    private async Task PlayNextAutomaticAnimationAsync()
    {
        if (_animationsRemainingInCycle <= 0)
        {
            Show(DisplayMode.Time);
            return;
        }

        _animationsRemainingInCycle--;
        await PlayLibraryOffsetAsync(1, automatic: true);
    }

    private async Task ContinueAutomaticCycleAsync()
    {
        try
        {
            await PlayNextAutomaticAnimationAsync();
        }
        finally
        {
            _automaticStartInProgress = false;
        }
    }

    private void HandlePlaybackCompleted()
    {
        _playback = null;
        if (_animationsRemainingInCycle > 0)
        {
            if (_settings.AnimationGapSeconds == 0)
                _ = PlayNextAutomaticAnimationAsync();
            else
            {
                _displayMode = DisplayMode.Time;
                _nextAnimationAtUtc = DateTimeOffset.UtcNow.AddSeconds(_settings.AnimationGapSeconds);
                UpdateClockOrDate();
                LogDisplayedMode(DisplayMode.Time);
                SetStatus($"Nästa animation om {_settings.AnimationGapSeconds} sekunder");
            }
        }
        else
            Show(DisplayMode.Time);
    }

    private void ApplySettingsToMenu()
    {
        RandomMenuItem.Header = Check(_settings.RandomPlayback, L("random"));
        AutomaticCycleMenuItem.Header = Check(_settings.AutomaticCycle, L("automatic"));
        var preset = _settings.ColorPreset ?? DmdColorPreset.Orange;
        var customSolid = !string.IsNullOrWhiteSpace(_settings.ForegroundColor);
        AppearanceOrangeMenuItem.Header = Check(!customSolid && preset == DmdColorPreset.Orange, L("orange"));
        AppearanceAmberMenuItem.Header = Check(!customSolid && preset == DmdColorPreset.Amber, L("goldenAmber"));
        AppearanceRedMenuItem.Header = Check(!customSolid && preset == DmdColorPreset.Red, L("pinballRed"));
        AppearanceGreenMenuItem.Header = Check(!customSolid && preset == DmdColorPreset.Green, L("arcadeGreen"));
        AppearanceBlueMenuItem.Header = Check(!customSolid && preset == DmdColorPreset.Blue, L("electricBlue"));
        AppearanceCyanMenuItem.Header = Check(!customSolid && preset == DmdColorPreset.Cyan, L("iceCyan"));
        AppearanceMagentaMenuItem.Header = Check(!customSolid && preset == DmdColorPreset.Magenta, L("hotMagenta"));
        AppearanceMonochromeMenuItem.Header = Check(!customSolid && preset == DmdColorPreset.Monochrome, L("warmWhite"));
        BasicCustomMenuItem.Header = Check(customSolid, $"{L("custom")}: {_settings.ForegroundColor ?? string.Empty}");
        AppearanceNeonSunsetMenuItem.Header = Check(preset == DmdColorPreset.NeonSunset, L("neonSunset"));
        AppearanceCyberOceanMenuItem.Header = Check(preset == DmdColorPreset.CyberOcean, L("cyberOcean"));
        AppearanceToxicArcadeMenuItem.Header = Check(preset == DmdColorPreset.ToxicArcade, L("toxicArcade"));
        AppearanceVaporwaveMenuItem.Header = Check(preset == DmdColorPreset.Vaporwave, L("vaporwave"));
        AppearanceAuroraMenuItem.Header = Check(preset == DmdColorPreset.Aurora, L("aurora"));
        AppearanceFirestormMenuItem.Header = Check(preset == DmdColorPreset.Firestorm, L("firestorm"));
        AppearanceElectricVioletMenuItem.Header = Check(preset == DmdColorPreset.ElectricViolet, L("electricViolet"));
        AppearanceArcticGlowMenuItem.Header = Check(preset == DmdColorPreset.ArcticGlow, L("arcticGlow"));
        AppearanceC64BlueRoundMenuItem.Header = Check(preset == DmdColorPreset.C64BlueRound, L("blueHalo"));
        AppearanceC64RedRoundMenuItem.Header = Check(preset == DmdColorPreset.C64RedRound, L("redHalo"));
        AppearanceC64EarthtoneMenuItem.Header = Check(preset == DmdColorPreset.C64Earthtone, L("earthtone"));
        AppearanceC64MetalMenuItem.Header = Check(preset == DmdColorPreset.C64Metal, L("metal"));
        AppearanceC64InterlacedBlueMenuItem.Header = Check(preset == DmdColorPreset.C64InterlacedBlue, L("interlacedBlue"));
        AppearanceC64ExtrudedCyanMenuItem.Header = Check(preset == DmdColorPreset.C64ExtrudedCyan, L("extrudedCyan"));
        AppearanceC64RainbowMenuItem.Header = Check(preset == DmdColorPreset.C64Rainbow, L("rainbow"));
        AppearanceC64PurpleHaloMenuItem.Header = Check(preset == DmdColorPreset.C64PurpleHalo, L("purpleHalo"));
        AppearanceRasterGreenHaloMenuItem.Header = Check(preset == DmdColorPreset.RasterGreenHalo, L("greenHalo"));
        AppearanceRasterAmberHaloMenuItem.Header = Check(preset == DmdColorPreset.RasterAmberHalo, L("amberHalo"));
        AppearanceRasterPurplePulseMenuItem.Header = Check(preset == DmdColorPreset.RasterPurplePulse, L("purplePulse"));
        AppearanceRasterOceanDepthMenuItem.Header = Check(preset == DmdColorPreset.RasterOceanDepth, L("oceanDepth"));
        AppearanceRasterSunsetBandsMenuItem.Header = Check(preset == DmdColorPreset.RasterSunsetBands, L("sunsetBands"));
        AppearanceRasterForestLayersMenuItem.Header = Check(preset == DmdColorPreset.RasterForestLayers, L("forestLayers"));
        AppearanceRasterArcticBandsMenuItem.Header = Check(preset == DmdColorPreset.RasterArcticBands, L("arcticBands"));
        AppearanceRasterCandyStripeMenuItem.Header = Check(preset == DmdColorPreset.RasterCandyStripe, L("candyStripe"));
        var plasmaPalette = _settings.PlasmaPalette ?? PlasmaPalettePreset.Neon;
        PlasmaNeonMenuItem.Header = Check(plasmaPalette == PlasmaPalettePreset.Neon, L("neonPulse"));
        PlasmaLavaMenuItem.Header = Check(plasmaPalette == PlasmaPalettePreset.Lava, L("lavaFlow"));
        PlasmaOceanMenuItem.Header = Check(plasmaPalette == PlasmaPalettePreset.Ocean, L("deepOcean"));
        PlasmaAuroraMenuItem.Header = Check(plasmaPalette == PlasmaPalettePreset.Aurora, L("auroraDrift"));
        PlasmaToxicMenuItem.Header = Check(plasmaPalette == PlasmaPalettePreset.Toxic, L("toxicSlime"));
        PlasmaVaporMenuItem.Header = Check(plasmaPalette == PlasmaPalettePreset.Vapor, L("vaporDream"));
        PlasmaSolarMenuItem.Header = Check(plasmaPalette == PlasmaPalettePreset.Solar, L("solarFlare"));
        PlasmaArcticMenuItem.Header = Check(plasmaPalette == PlasmaPalettePreset.Arctic, L("arcticIce"));
        PlasmaCustomMenuItem.Header = Check(plasmaPalette == PlasmaPalettePreset.Custom, L("customPalette"));
        var plasmaCycle = _settings.PlasmaCycleMilliseconds ?? PlasmaSpeedDefinition.DefaultCycleMilliseconds;
        PlasmaSlowMenuItem.Header = Check(plasmaCycle == 16_000, "Slow — 16 seconds");
        PlasmaNormalMenuItem.Header = Check(plasmaCycle == 8_000, "Normal — 8 seconds");
        PlasmaFastMenuItem.Header = Check(plasmaCycle == 4_000, "Fast — 4 seconds");
        PlasmaVeryFastMenuItem.Header = Check(plasmaCycle == 2_000, "Very fast — 2 seconds");
        var isPresetSpeed = plasmaCycle is 16_000 or 8_000 or 4_000 or 2_000;
        PlasmaCustomSpeedMenuItem.Header = Check(
            !isPresetSpeed,
            $"Custom… ({plasmaCycle / 1000d:0.##} seconds)");
        var family = ColorFamilyName(preset, customSolid);
        var choice = customSolid ? $"{L("custom")} {_settings.ForegroundColor}" : PresetName(preset);
        ColorsMenuItem.Header = $"{L("colors")}: {family} · {choice}";
        BasicColorsMenuItem.Header = Check(customSolid || IsBasicPreset(preset), L("basicColors"));
        PlasmaMenuItem.Header = Check(!customSolid && preset == DmdColorPreset.Plasma, L("plasma"));
        PlasmaPaletteMenuItem.Header = $"{L("palette")}: {PlasmaPaletteName(plasmaPalette)}";
        PlasmaSpeedMenuItem.Header = $"{L("speed")}: {PlasmaSpeedName(plasmaCycle)}";
        GradientThemesMenuItem.Header = Check(!customSolid && IsGradientPreset(preset), L("gradientThemes"));
        RasterThemesMenuItem.Header = Check(!customSolid && IsRasterPreset(preset), L("rasterThemes"));
        var backgroundMode = _settings.BackgroundMode ?? DmdBackgroundMode.Theme;
        BackgroundMenuItem.Header = $"{L("background")}: {BackgroundModeName(backgroundMode)}";
        BackgroundThemeMenuItem.Header = Check(backgroundMode == DmdBackgroundMode.Theme, L("themeDefault"));
        BackgroundBlackMenuItem.Header = Check(backgroundMode == DmdBackgroundMode.Black, L("black"));
        BackgroundCustomMenuItem.Header = Check(
            backgroundMode == DmdBackgroundMode.Custom,
            $"{L("custom")}: {_settings.BackgroundColor ?? "#000000"}");
        ResetCustomColorsMenuItem.IsEnabled =
            customSolid || backgroundMode == DmdBackgroundMode.Custom ||
            (preset == DmdColorPreset.Plasma && plasmaPalette == PlasmaPalettePreset.Custom);
        var brightness = _settings.BrightnessPercent ?? 100;
        Brightness25MenuItem.Header = Check(brightness == 25, "25 %");
        Brightness50MenuItem.Header = Check(brightness == 50, "50 %");
        Brightness75MenuItem.Header = Check(brightness == 75, "75 %");
        Brightness100MenuItem.Header = Check(brightness == 100, "100 %");
        GlowMenuItem.Header = Check(_settings.GlowEnabled ?? true, L("glow"));
        var hotCoreEnabled = _settings.HotCoreEnabled ?? false;
        var hotCoreStyle = _settings.HotCoreStyle ?? HotCoreStyle.Classic;
        HotCoreMenuItem.Header = Check(hotCoreEnabled, L("hotCoreGlow"));
        HotCoreOffMenuItem.Header = Check(!hotCoreEnabled, L("off"));
        HotCoreClassicMenuItem.Header = Check(hotCoreEnabled && hotCoreStyle == HotCoreStyle.Classic, L("hotCoreClassic"));
        HotCoreThemeMenuItem.Header = Check(hotCoreEnabled && hotCoreStyle == HotCoreStyle.Theme, L("hotCoreTheme"));
        HotCoreDualMenuItem.Header = Check(hotCoreEnabled && hotCoreStyle == HotCoreStyle.DualColor, L("hotCoreDual"));
        HotCoreColorMenuItem.Header = $"{L("hotCoreColor")}: {_settings.HotCoreColor ?? "#FFF2B0"}";
        HotCoreColorMenuItem.IsEnabled = hotCoreEnabled && hotCoreStyle == HotCoreStyle.DualColor;
        var dotDepth = _settings.DotDepth ?? DotDepthStyle.Flat;
        DotDepthMenuItem.Header = $"{L("dotDepth")}: {DotDepthName(dotDepth)}";
        DotDepthFlatMenuItem.Header = Check(dotDepth == DotDepthStyle.Flat, L("flat"));
        DotDepthSubtleMenuItem.Header = Check(dotDepth == DotDepthStyle.Subtle, L("subtle"));
        DotDepthDeepMenuItem.Header = Check(dotDepth == DotDepthStyle.Deep, L("deep"));
        AnimationInfoMenuItem.Header = Check(_settings.ShowAnimationInfo ?? true, L("animationInfo"));
        EnglishLanguageMenuItem.Header = Check((_settings.Language ?? "en") == "en", L("english"));
        SwedishLanguageMenuItem.Header = Check(_settings.Language == "sv", L("swedish"));
        Clock24MenuItem.Header = Check(_settings.ClockFormat != "12", L("hour24"));
        Clock12MenuItem.Header = Check(_settings.ClockFormat == "12", L("hour12"));
        ShowSecondsMenuItem.Header = Check(_settings.ShowSeconds ?? true, L("showSeconds"));
        ShowTitleBarMenuItem.Header = Check(_settings.ShowTitleBar ?? true, L("showTitleBar"));
        var displaySize = WindowState == WindowState.FullScreen
            ? _settings.FullscreenZoomPercent ?? 100
            : _settings.WindowScalePercent ?? 100;
        DisplaySizeMenuItem.Header = $"{L("displaySize")}: {displaySize} %";
        WindowDecorations = _launchOptions.Mode is ScreenSaverLaunchMode.Fullscreen or ScreenSaverLaunchMode.Preview
            ? Avalonia.Controls.WindowDecorations.None
            : (_settings.ShowTitleBar ?? true)
                ? Avalonia.Controls.WindowDecorations.Full
                : Avalonia.Controls.WindowDecorations.None;
        var dateFormat = _settings.DateFormat ?? "yyyy-MM-dd";
        DateIsoMenuItem.Header = Check(dateFormat == "yyyy-MM-dd", L("dateIso"));
        DateEuropeanMenuItem.Header = Check(dateFormat == "dd/MM/yyyy", L("dateEuropean"));
        DateUsMenuItem.Header = Check(dateFormat == "MM/dd/yyyy", L("dateUs"));
        DateDotsMenuItem.Header = Check(dateFormat == "dd.MM.yyyy", L("dateDots"));
        ApplyFontMenuChecks();
        ClockTime10MenuItem.Header = Check(_settings.ClockDisplaySeconds == 10, L("seconds10"));
        ClockTime30MenuItem.Header = Check(_settings.ClockDisplaySeconds == 30, L("seconds30"));
        ClockTime60MenuItem.Header = Check(_settings.ClockDisplaySeconds == 60, L("seconds60"));
        Animations1MenuItem.Header = Check(_settings.AnimationsPerCycle == 1, L("animation1"));
        Animations3MenuItem.Header = Check(_settings.AnimationsPerCycle == 3, L("animation3"));
        Animations5MenuItem.Header = Check(_settings.AnimationsPerCycle == 5, L("animation5"));
        AnimationGap0MenuItem.Header = Check(_settings.AnimationGapSeconds == 0, L("noPause"));
        AnimationGap5MenuItem.Header = Check(_settings.AnimationGapSeconds == 5, L("seconds5"));
        AnimationGap10MenuItem.Header = Check(_settings.AnimationGapSeconds == 10, L("seconds10"));
        AnimationGap30MenuItem.Header = Check(_settings.AnimationGapSeconds == 30, L("seconds30"));
        Display.SetAppearance(preset, brightness, _settings.GlowEnabled ?? true,
            _settings.ForegroundColor, ResolveBackgroundColor(preset),
            _settings.PlasmaPalette ?? PlasmaPalettePreset.Neon,
            _settings.PlasmaCustomColors,
            _settings.PlasmaCycleMilliseconds ?? PlasmaSpeedDefinition.DefaultCycleMilliseconds,
            hotCoreEnabled,
            hotCoreStyle,
            _settings.HotCoreColor,
            dotDepth);
    }

    private static string Check(bool selected, string label) => selected ? $"✓ {label}" : label;
    private static string L(string key) => LocalizationManager.Get(key);

    private static string DotDepthName(DotDepthStyle depth) => depth switch
    {
        DotDepthStyle.Subtle => L("subtle"),
        DotDepthStyle.Deep => L("deep"),
        _ => L("flat")
    };

    private void PopulateFontMenus()
    {
        _clockFontItems.Clear();
        _dateFontItems.Clear();
        ClockFontMenuItem.Items.Clear();
        DateFontMenuItem.Items.Clear();
        AddFontMenuItem(ClockFontMenuItem, _clockFontItems, null, L("builtInFont"), SetClockFont);
        AddFontMenuItem(DateFontMenuItem, _dateFontItems, null, L("builtInFont"), SetDateFont);
        foreach (var id in EmbeddedDotClkFonts.Ids)
        {
            var label = EmbeddedDotClkFonts.GetDisplayName(id);
            AddFontMenuItem(ClockFontMenuItem, _clockFontItems, id, label, SetClockFont);
            AddFontMenuItem(DateFontMenuItem, _dateFontItems, id, label, SetDateFont);
        }

        var fontsDirectory = Path.Combine(AppContext.BaseDirectory, "fonts");
        if (Directory.Exists(fontsDirectory))
        {
            var files = Directory.EnumerateFiles(fontsDirectory, "*", SearchOption.AllDirectories)
                .Where(IsSupportedFontFile)
                .Select(path => new
                {
                    Path = path,
                    Relative = Path.GetRelativePath(fontsDirectory, path).Replace('\\', '/')
                })
                .OrderBy(font => Path.GetFileNameWithoutExtension(font.Path), StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(font => font.Relative, StringComparer.OrdinalIgnoreCase);
            foreach (var font in files)
            {
                var label = Path.GetFileNameWithoutExtension(font.Path);
                AddFontMenuItem(ClockFontMenuItem, _clockFontItems, font.Relative, label, SetClockFont);
                AddFontMenuItem(DateFontMenuItem, _dateFontItems, font.Relative, label, SetDateFont);
            }
        }
        ApplyFontMenuChecks();
    }

    private static void AddFontMenuItem(MenuItem parent, Dictionary<MenuItem, string?> items,
        string? relativePath, string label, Action<string?> selected)
    {
        var item = new MenuItem { Header = label, StaysOpenOnClick = true };
        item.Click += (_, _) => selected(relativePath);
        items[item] = relativePath;
        parent.Items.Add(item);
    }

    private void ApplyFontMenuChecks()
    {
        foreach (var (item, path) in _clockFontItems)
            item.Header = Check(string.Equals(path, _settings.ClockFontFile, StringComparison.OrdinalIgnoreCase),
                path is null ? L("builtInFont") : Path.GetFileNameWithoutExtension(path));
        foreach (var (item, path) in _dateFontItems)
            item.Header = Check(string.Equals(path, _settings.DateFontFile, StringComparison.OrdinalIgnoreCase),
                path is null ? L("builtInFont") : Path.GetFileNameWithoutExtension(path));
    }

    private static bool IsSupportedFontFile(string path) =>
        Path.GetExtension(path) is { } extension &&
        (extension.Equals(".ttf", StringComparison.OrdinalIgnoreCase) ||
         extension.Equals(".otf", StringComparison.OrdinalIgnoreCase));

    private static string? ResolveFontPath(string? relativePath)
    {
        if (string.IsNullOrWhiteSpace(relativePath)) return null;
        var root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "fonts"));
        var candidate = Path.GetFullPath(Path.Combine(root, relativePath.Replace('/', Path.DirectorySeparatorChar)));
        if (!candidate.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
            !File.Exists(candidate) || !IsSupportedFontFile(candidate)) return null;
        return candidate;
    }

    private static void ApplyMenuTranslations(IEnumerable<object?> items)
    {
        foreach (var menuItem in items.OfType<MenuItem>())
        {
            var key = menuItem.Tag as string;
            if (key is null && menuItem.Header is string header)
            {
                key = LocalizationManager.FindKey(header);
                if (key is not null) menuItem.Tag = key;
            }
            if (key is not null) menuItem.Header = L(key);
            ApplyMenuTranslations(menuItem.Items);
        }
    }

    private void SetLanguage(string language)
    {
        _settings = (_settings with { Language = language }).Normalize();
        LoadLocalization(_settings.Language ?? "en");
        ApplyMenuTranslations(MainContextMenu.Items);
        PopulateFontMenus();
        ApplySettingsToMenu();
        SaveSettings();
    }

    private void LoadLocalization(string language)
    {
        foreach (var warning in LocalizationManager.Load(language))
        {
            _ = _log.WriteAsync(
                DateTimeOffset.UtcNow,
                $"localization.warning language=\"{SanitizeLogValue(warning.Language)}\" " +
                $"path=\"{SanitizeLogValue(warning.Path)}\" " +
                $"reason=\"{SanitizeLogValue(warning.Reason)}\" fallback=embedded-en");
        }
    }

    private void SetClockFormat(string format)
    {
        _settings = (_settings with { ClockFormat = format }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        if (_displayMode == DisplayMode.Time) UpdateClockOrDate();
    }

    private void ToggleShowSeconds()
    {
        _settings = (_settings with { ShowSeconds = !(_settings.ShowSeconds ?? true) }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        if (_displayMode == DisplayMode.Time) UpdateClockOrDate();
    }

    private void ToggleTitleBar()
    {
        _settings = (_settings with { ShowTitleBar = !(_settings.ShowTitleBar ?? true) }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
    }

    private void SetDateFormat(string format)
    {
        _settings = (_settings with { DateFormat = format }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        if (_displayMode == DisplayMode.Date) UpdateClockOrDate();
    }

    private void SetClockFont(string? relativePath)
    {
        _settings = (_settings with { ClockFontFile = relativePath }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        if (_displayMode == DisplayMode.Time) UpdateClockOrDate();
    }

    private void SetDateFont(string? relativePath)
    {
        _settings = (_settings with { DateFontFile = relativePath }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        if (_displayMode == DisplayMode.Date) UpdateClockOrDate();
    }

    private void SaveSettings() => _ = _settingsStore.SaveAtomicAsync(_settings, _settingsPath);

    private void SetClockDisplaySeconds(int seconds)
    {
        _settings = (_settings with { ClockDisplaySeconds = seconds }).Normalize();
        ApplySettingsToMenu();
        if (_displayMode == DisplayMode.Time)
            _clockUntilUtc = DateTimeOffset.UtcNow.AddSeconds(_settings.ClockDisplaySeconds);
        SaveSettings();
        SetStatus($"Klocktid: {_settings.ClockDisplaySeconds} sekunder");
    }

    private void SetAnimationsPerCycle(int count)
    {
        _settings = (_settings with { AnimationsPerCycle = count }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        SetStatus($"Animationer per cykel: {_settings.AnimationsPerCycle}");
    }

    private void SetAnimationGapSeconds(int seconds)
    {
        _settings = (_settings with { AnimationGapSeconds = seconds }).Normalize();
        ApplySettingsToMenu();
        if (_nextAnimationAtUtc is not null)
            _nextAnimationAtUtc = DateTimeOffset.UtcNow.AddSeconds(_settings.AnimationGapSeconds);
        SaveSettings();
        SetStatus(_settings.AnimationGapSeconds == 0
            ? "Ingen paus mellan animationer"
            : $"Tid mellan animationer: {_settings.AnimationGapSeconds} sekunder");
    }

    private void SetColorPreset(DmdColorPreset preset)
    {
        _settings = (_settings with { ColorPreset = preset, ForegroundColor = null }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        SetStatus($"Färgtema: {PresetName(preset)}");
    }

    private void SetMultiColorTheme(DmdColorPreset preset) => SetColorPreset(preset);

    private void SetPlasmaPalette(PlasmaPalettePreset palette)
    {
        _settings = (_settings with
        {
            ColorPreset = DmdColorPreset.Plasma,
            ForegroundColor = null,
            PlasmaPalette = palette
        }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        SetStatus($"Plasma palette: {palette}");
    }

    private async Task CustomizePlasmaPaletteAsync()
    {
        var palette = _settings.PlasmaPalette ?? PlasmaPalettePreset.Neon;
        var colors = PlasmaPaletteDefinition.GetStops(palette, _settings.PlasmaCustomColors);
        var dialog = new PlasmaPaletteEditorWindow(colors);
        var selected = await dialog.ShowDialog<string[]?>(this);
        if (selected is null) return;

        _settings = (_settings with
        {
            ColorPreset = DmdColorPreset.Plasma,
            ForegroundColor = null,
            PlasmaPalette = PlasmaPalettePreset.Custom,
            PlasmaCustomColors = selected
        }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        SetStatus("Plasma palette: Custom");
    }

    private void SetPlasmaSpeed(int cycleMilliseconds)
    {
        _settings = (_settings with
        {
            ColorPreset = DmdColorPreset.Plasma,
            ForegroundColor = null,
            PlasmaCycleMilliseconds = cycleMilliseconds
        }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        SetStatus($"Plasma cycle: {_settings.PlasmaCycleMilliseconds / 1000d:0.##} seconds");
    }

    private async Task CustomizePlasmaSpeedAsync()
    {
        var dialog = new PlasmaSpeedEditorWindow(
            _settings.PlasmaCycleMilliseconds ?? PlasmaSpeedDefinition.DefaultCycleMilliseconds);
        var selected = await dialog.ShowDialog<int?>(this);
        if (selected is { } milliseconds)
            SetPlasmaSpeed(milliseconds);
    }

    private async Task PickColorAsync(bool foreground)
    {
        var initial = foreground
            ? ParseDisplayColor(_settings.ForegroundColor, PresetColor(_settings.ColorPreset ?? DmdColorPreset.Orange))
            : ParseDisplayColor(ResolveBackgroundColor(_settings.ColorPreset ?? DmdColorPreset.Orange), Colors.Black);
        var dialog = new ColorPickerWindow(
            foreground ? L("foregroundColor") : L("backgroundColor"), initial, L("ok"), L("cancel"));
        var selected = await dialog.ShowDialog<Color?>(this);
        if (selected is not { } color) return;
        var value = $"#{color.R:X2}{color.G:X2}{color.B:X2}";
        _settings = foreground
            ? (_settings with { ColorPreset = DmdColorPreset.Orange, ForegroundColor = value }).Normalize()
            : (_settings with
            {
                BackgroundColor = value,
                BackgroundMode = DmdBackgroundMode.Custom
            }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        SetStatus($"{(foreground ? L("foregroundColor") : L("backgroundColor"))}: {value}");
    }

    private void SetHotCore(bool enabled, HotCoreStyle style)
    {
        _settings = (_settings with
        {
            HotCoreEnabled = enabled,
            HotCoreStyle = style
        }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        SetStatus(enabled ? $"{L("hotCoreGlow")}: {HotCoreStyleName(style)}" : $"{L("hotCoreGlow")}: {L("off")}");
    }

    private async Task PickHotCoreColorAsync(bool enableDualMode)
    {
        var initial = ParseDisplayColor(_settings.HotCoreColor, Color.FromRgb(255, 242, 176));
        var dialog = new ColorPickerWindow(L("hotCoreColor"), initial, L("ok"), L("cancel"));
        var selected = await dialog.ShowDialog<Color?>(this);
        if (selected is not { } color) return;

        var value = $"#{color.R:X2}{color.G:X2}{color.B:X2}";
        _settings = (_settings with
        {
            HotCoreEnabled = enableDualMode || (_settings.HotCoreEnabled ?? false),
            HotCoreStyle = enableDualMode ? HotCoreStyle.DualColor : _settings.HotCoreStyle,
            HotCoreColor = value
        }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        SetStatus($"{L("hotCoreColor")}: {value}");
    }

    private void SetDotDepth(DotDepthStyle depth)
    {
        _settings = (_settings with { DotDepth = depth }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        SetStatus($"{L("dotDepth")}: {DotDepthName(depth)}");
    }

    private static string HotCoreStyleName(HotCoreStyle style) => style switch
    {
        HotCoreStyle.Theme => L("hotCoreTheme"),
        HotCoreStyle.DualColor => L("hotCoreDual"),
        _ => L("hotCoreClassic")
    };

    private static Color ParseDisplayColor(string? value, Color fallback)
    {
        try { return string.IsNullOrWhiteSpace(value) ? fallback : Color.Parse(value); }
        catch (FormatException) { return fallback; }
    }

    private static Color PresetColor(DmdColorPreset preset) => preset switch
    {
        DmdColorPreset.Red => Color.FromRgb(255, 32, 16),
        DmdColorPreset.Plasma => Color.FromRgb(120, 100, 255),
        DmdColorPreset.Monochrome => Color.FromRgb(235, 235, 235),
        DmdColorPreset.Amber => Color.FromRgb(255, 176, 0),
        DmdColorPreset.Green => Color.FromRgb(57, 255, 90),
        DmdColorPreset.Blue => Color.FromRgb(58, 123, 255),
        DmdColorPreset.Cyan => Color.FromRgb(37, 230, 255),
        DmdColorPreset.Magenta => Color.FromRgb(255, 63, 203),
        DmdColorPreset.NeonSunset => Color.FromRgb(255, 209, 102),
        DmdColorPreset.CyberOcean => Color.FromRgb(94, 255, 255),
        DmdColorPreset.ToxicArcade => Color.FromRgb(245, 255, 87),
        DmdColorPreset.Vaporwave => Color.FromRgb(255, 92, 225),
        DmdColorPreset.Aurora => Color.FromRgb(180, 112, 255),
        DmdColorPreset.Firestorm => Color.FromRgb(255, 210, 63),
        DmdColorPreset.ElectricViolet => Color.FromRgb(255, 53, 200),
        DmdColorPreset.ArcticGlow => Color.FromRgb(232, 255, 255),
        DmdColorPreset.C64BlueRound => Color.FromRgb(0x6C, 0x5E, 0xB5),
        DmdColorPreset.C64RedRound => Color.FromRgb(0x9A, 0x67, 0x59),
        DmdColorPreset.C64Earthtone => Color.FromRgb(0xB8, 0xC7, 0x6F),
        DmdColorPreset.C64Metal => Color.FromRgb(0x95, 0x95, 0x95),
        DmdColorPreset.C64InterlacedBlue => Color.FromRgb(0x70, 0xA4, 0xB2),
        DmdColorPreset.C64ExtrudedCyan => Color.FromRgb(0x70, 0xA4, 0xB2),
        DmdColorPreset.C64Rainbow => Color.FromRgb(0xB8, 0xC7, 0x6F),
        DmdColorPreset.C64PurpleHalo => Color.FromRgb(0x6F, 0x3D, 0x86),
        DmdColorPreset.RasterGreenHalo => Color.FromRgb(0x9A, 0xD2, 0x84),
        DmdColorPreset.RasterAmberHalo => Color.FromRgb(0xB8, 0xC7, 0x6F),
        DmdColorPreset.RasterPurplePulse => Color.FromRgb(0x9A, 0x67, 0x59),
        DmdColorPreset.RasterOceanDepth => Color.FromRgb(0x70, 0xA4, 0xB2),
        DmdColorPreset.RasterSunsetBands => Color.FromRgb(0x6F, 0x4F, 0x25),
        DmdColorPreset.RasterForestLayers => Color.FromRgb(0x58, 0x8D, 0x43),
        DmdColorPreset.RasterArcticBands => Color.FromRgb(0x95, 0x95, 0x95),
        DmdColorPreset.RasterCandyStripe => Color.FromRgb(0x9A, 0x67, 0x59),
        _ => Color.FromRgb(255, 112, 14)
    };

    private void SetBrightness(int percent)
    {
        _settings = (_settings with { BrightnessPercent = percent }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        SetStatus($"Ljusstyrka: {_settings.BrightnessPercent} %");
    }

    private void ToggleAnimationInformation()
    {
        var enabled = !(_settings.ShowAnimationInfo ?? true);
        _settings = (_settings with { ShowAnimationInfo = enabled }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        if (!enabled) CancelInformationDisplay();
        SetStatus(enabled ? "Animationsinformation: på" : "Animationsinformation: av");
    }

    private void CancelInformationDisplay()
    {
        var cancellation = _informationCancellation;
        _informationCancellation = null;
        AnimationInfoOverlay.IsVisible = false;
        cancellation?.Cancel();
    }

    private static string PresetName(DmdColorPreset preset) => preset switch
    {
        DmdColorPreset.Red => L("pinballRed"),
        DmdColorPreset.Plasma => L("plasma"),
        DmdColorPreset.Monochrome => L("warmWhite"),
        DmdColorPreset.Amber => L("goldenAmber"),
        DmdColorPreset.Green => L("arcadeGreen"),
        DmdColorPreset.Blue => L("electricBlue"),
        DmdColorPreset.Cyan => L("iceCyan"),
        DmdColorPreset.Magenta => L("hotMagenta"),
        DmdColorPreset.NeonSunset => L("neonSunset"),
        DmdColorPreset.CyberOcean => L("cyberOcean"),
        DmdColorPreset.ToxicArcade => L("toxicArcade"),
        DmdColorPreset.Vaporwave => L("vaporwave"),
        DmdColorPreset.Aurora => L("aurora"),
        DmdColorPreset.Firestorm => L("firestorm"),
        DmdColorPreset.ElectricViolet => L("electricViolet"),
        DmdColorPreset.ArcticGlow => L("arcticGlow"),
        DmdColorPreset.C64BlueRound => L("blueHalo"),
        DmdColorPreset.C64RedRound => L("redHalo"),
        DmdColorPreset.C64Earthtone => L("earthtone"),
        DmdColorPreset.C64Metal => L("metal"),
        DmdColorPreset.C64InterlacedBlue => L("interlacedBlue"),
        DmdColorPreset.C64ExtrudedCyan => L("extrudedCyan"),
        DmdColorPreset.C64Rainbow => L("rainbow"),
        DmdColorPreset.C64PurpleHalo => L("purpleHalo"),
        DmdColorPreset.RasterGreenHalo => L("greenHalo"),
        DmdColorPreset.RasterAmberHalo => L("amberHalo"),
        DmdColorPreset.RasterPurplePulse => L("purplePulse"),
        DmdColorPreset.RasterOceanDepth => L("oceanDepth"),
        DmdColorPreset.RasterSunsetBands => L("sunsetBands"),
        DmdColorPreset.RasterForestLayers => L("forestLayers"),
        DmdColorPreset.RasterArcticBands => L("arcticBands"),
        DmdColorPreset.RasterCandyStripe => L("candyStripe"),
        _ => L("orange")
    };

    private string ResolveBackgroundColor(DmdColorPreset preset) =>
        DmdThemeBackgroundDefinition.Resolve(_settings with { ColorPreset = preset });

    private static bool IsBasicPreset(DmdColorPreset preset) => preset is
        DmdColorPreset.Orange or DmdColorPreset.Amber or DmdColorPreset.Red or
        DmdColorPreset.Green or DmdColorPreset.Blue or DmdColorPreset.Cyan or
        DmdColorPreset.Magenta or DmdColorPreset.Monochrome;

    private static bool IsGradientPreset(DmdColorPreset preset) => preset is
        DmdColorPreset.NeonSunset or DmdColorPreset.CyberOcean or DmdColorPreset.ToxicArcade or
        DmdColorPreset.Vaporwave or DmdColorPreset.Aurora or DmdColorPreset.Firestorm or
        DmdColorPreset.ElectricViolet or DmdColorPreset.ArcticGlow;

    private static bool IsRasterPreset(DmdColorPreset preset) => preset is
        DmdColorPreset.C64BlueRound or DmdColorPreset.C64RedRound or DmdColorPreset.C64Earthtone or
        DmdColorPreset.C64Metal or DmdColorPreset.C64InterlacedBlue or DmdColorPreset.C64ExtrudedCyan or
        DmdColorPreset.C64Rainbow or DmdColorPreset.C64PurpleHalo or
        DmdColorPreset.RasterGreenHalo or DmdColorPreset.RasterAmberHalo or
        DmdColorPreset.RasterPurplePulse or DmdColorPreset.RasterOceanDepth or
        DmdColorPreset.RasterSunsetBands or DmdColorPreset.RasterForestLayers or
        DmdColorPreset.RasterArcticBands or DmdColorPreset.RasterCandyStripe;

    private static string ColorFamilyName(DmdColorPreset preset, bool customSolid) =>
        customSolid || IsBasicPreset(preset) ? L("basic") :
        preset == DmdColorPreset.Plasma ? L("plasma") :
        IsGradientPreset(preset) ? L("gradient") : L("raster");

    private static string PlasmaPaletteName(PlasmaPalettePreset palette) => palette switch
    {
        PlasmaPalettePreset.Lava => L("lavaFlow"),
        PlasmaPalettePreset.Ocean => L("deepOcean"),
        PlasmaPalettePreset.Aurora => L("auroraDrift"),
        PlasmaPalettePreset.Toxic => L("toxicSlime"),
        PlasmaPalettePreset.Vapor => L("vaporDream"),
        PlasmaPalettePreset.Solar => L("solarFlare"),
        PlasmaPalettePreset.Arctic => L("arcticIce"),
        PlasmaPalettePreset.Custom => L("custom"),
        _ => L("neonPulse")
    };

    private static string PlasmaSpeedName(int cycleMilliseconds) => cycleMilliseconds switch
    {
        16_000 => L("slow"),
        8_000 => L("normal"),
        4_000 => L("fast"),
        2_000 => L("veryFast"),
        _ => $"{cycleMilliseconds / 1000d:0.##} s"
    };

    private static string BackgroundModeName(DmdBackgroundMode mode) => mode switch
    {
        DmdBackgroundMode.Black => L("black"),
        DmdBackgroundMode.Custom => L("custom"),
        _ => L("themeDefault")
    };

    private void SetBackgroundMode(DmdBackgroundMode mode)
    {
        _settings = (_settings with { BackgroundMode = mode }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        SetStatus($"{L("background")}: {BackgroundModeName(mode)}");
    }

    private void ResetCustomColors()
    {
        var palette = _settings.ColorPreset == DmdColorPreset.Plasma &&
                      _settings.PlasmaPalette == PlasmaPalettePreset.Custom
            ? PlasmaPalettePreset.Neon
            : _settings.PlasmaPalette;
        _settings = (_settings with
        {
            ForegroundColor = null,
            BackgroundMode = DmdBackgroundMode.Theme,
            PlasmaPalette = palette
        }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        SetStatus(L("customColorsReset"));
    }

    private void ConfigureColorSwatches()
    {
        SetColorSwatch(AppearanceOrangeMenuItem, false, "#FF700E");
        SetColorSwatch(AppearanceAmberMenuItem, false, "#FFB000");
        SetColorSwatch(AppearanceRedMenuItem, false, "#FF2010");
        SetColorSwatch(AppearanceGreenMenuItem, false, "#39FF5A");
        SetColorSwatch(AppearanceBlueMenuItem, false, "#3A7BFF");
        SetColorSwatch(AppearanceCyanMenuItem, false, "#25E6FF");
        SetColorSwatch(AppearanceMagentaMenuItem, false, "#FF3FCB");
        SetColorSwatch(AppearanceMonochromeMenuItem, false, "#EBEBEB");

        SetColorSwatch(PlasmaNeonMenuItem, false, "#2D0C6E", "#3250FF", "#1EEBFF", "#FF41DC");
        SetColorSwatch(PlasmaLavaMenuItem, false, "#4A0010", "#E02020", "#FF7A00", "#FFE060");
        SetColorSwatch(PlasmaOceanMenuItem, false, "#001040", "#0055D8", "#00C8FF", "#B8FFFF");
        SetColorSwatch(PlasmaAuroraMenuItem, false, "#180050", "#7A38FF", "#20E8A0", "#D8FF70");
        SetColorSwatch(PlasmaToxicMenuItem, false, "#082A12", "#16A34A", "#A3FF12", "#F5FF75");
        SetColorSwatch(PlasmaVaporMenuItem, false, "#24005E", "#7A38FF", "#FF41DC", "#41E9FF");
        SetColorSwatch(PlasmaSolarMenuItem, false, "#3D0500", "#D82900", "#FF8A00", "#FFF0A0");
        SetColorSwatch(PlasmaArcticMenuItem, false, "#001B3D", "#0077B6", "#48CAE4", "#E0FBFF");

        SetColorSwatch(AppearanceNeonSunsetMenuItem, false, "#FF2BD6", "#FFD166");
        SetColorSwatch(AppearanceCyberOceanMenuItem, false, "#267BFF", "#5EFFFF");
        SetColorSwatch(AppearanceToxicArcadeMenuItem, false, "#2EFF6A", "#F5FF57");
        SetColorSwatch(AppearanceVaporwaveMenuItem, false, "#8A4DFF", "#FF5CE1");
        SetColorSwatch(AppearanceAuroraMenuItem, false, "#34FFBE", "#B470FF");
        SetColorSwatch(AppearanceFirestormMenuItem, false, "#FF3218", "#FFD23F");
        SetColorSwatch(AppearanceElectricVioletMenuItem, false, "#4F46E5", "#FF35C8");
        SetColorSwatch(AppearanceArcticGlowMenuItem, false, "#20CFFF", "#E8FFFF");

        SetColorSwatch(AppearanceC64BlueRoundMenuItem, true, "#352879", "#6C5EB5", "#70A4B2", "#FFFFFF", "#70A4B2", "#6C5EB5", "#352879");
        SetColorSwatch(AppearanceC64RedRoundMenuItem, true, "#68372B", "#9A6759", "#6F4F25", "#B8C76F", "#FFFFFF", "#B8C76F", "#6F4F25", "#9A6759", "#68372B");
        SetColorSwatch(AppearanceC64EarthtoneMenuItem, true, "#433900", "#68372B", "#6F4F25", "#9A6759", "#B8C76F", "#9A6759", "#6F4F25", "#68372B", "#433900");
        SetColorSwatch(AppearanceC64MetalMenuItem, true, "#444444", "#6C6C6C", "#959595", "#FFFFFF", "#959595", "#6C6C6C", "#444444");
        SetColorSwatch(AppearanceC64InterlacedBlueMenuItem, true, "#352879", "#6C5EB5", "#352879", "#70A4B2", "#352879", "#FFFFFF", "#352879", "#70A4B2");
        SetColorSwatch(AppearanceC64ExtrudedCyanMenuItem, true, "#352879", "#70A4B2", "#FFFFFF", "#70A4B2", "#352879", "#6C5EB5");
        SetColorSwatch(AppearanceC64RainbowMenuItem, true, "#68372B", "#6F4F25", "#B8C76F", "#9AD284", "#588D43", "#70A4B2", "#6C5EB5", "#352879", "#6F3D86", "#9A6759");
        SetColorSwatch(AppearanceC64PurpleHaloMenuItem, true, "#352879", "#6F3D86", "#9A6759", "#FFFFFF", "#9A6759", "#6F3D86", "#352879");
        SetColorSwatch(AppearanceRasterGreenHaloMenuItem, true, "#588D43", "#9AD284", "#B8C76F", "#FFFFFF", "#B8C76F", "#9AD284", "#588D43");
        SetColorSwatch(AppearanceRasterAmberHaloMenuItem, true, "#433900", "#6F4F25", "#B8C76F", "#FFFFFF", "#B8C76F", "#6F4F25", "#433900");
        SetColorSwatch(AppearanceRasterPurplePulseMenuItem, true, "#6F3D86", "#9A6759", "#6F3D86", "#FFFFFF", "#6F3D86", "#9A6759", "#6F3D86");
        SetColorSwatch(AppearanceRasterOceanDepthMenuItem, true, "#352879", "#6C5EB5", "#70A4B2", "#6C5EB5", "#FFFFFF", "#6C5EB5", "#70A4B2", "#352879");
        SetColorSwatch(AppearanceRasterSunsetBandsMenuItem, true, "#6F3D86", "#68372B", "#9A6759", "#6F4F25", "#B8C76F", "#9A6759", "#68372B");
        SetColorSwatch(AppearanceRasterForestLayersMenuItem, true, "#433900", "#588D43", "#9AD284", "#B8C76F", "#9AD284", "#588D43", "#433900");
        SetColorSwatch(AppearanceRasterArcticBandsMenuItem, true, "#352879", "#70A4B2", "#959595", "#FFFFFF", "#959595", "#70A4B2", "#352879");
        SetColorSwatch(AppearanceRasterCandyStripeMenuItem, true, "#68372B", "#9A6759", "#FFFFFF", "#70A4B2", "#FFFFFF", "#9A6759", "#6F3D86");
    }

    private static void SetColorSwatch(MenuItem item, bool verticalBands, params string[] colors)
    {
        var panel = new StackPanel { Orientation = verticalBands ? Orientation.Vertical : Orientation.Horizontal };
        foreach (var value in colors)
        {
            panel.Children.Add(new Border
            {
                Width = verticalBands ? 42 : 42d / colors.Length,
                Height = verticalBands ? 12d / colors.Length : 12,
                Background = new SolidColorBrush(Color.Parse(value))
            });
        }
        item.Icon = new Border
        {
            Width = 42,
            Height = 12,
            CornerRadius = new CornerRadius(2),
            BorderBrush = new SolidColorBrush(Color.Parse("#66FFFFFF")),
            BorderThickness = new Thickness(1),
            ClipToBounds = true,
            Child = panel
        };
    }

    private static string ResolveScenesDirectory(string? savedDirectory)
    {
        if (!string.IsNullOrWhiteSpace(savedDirectory) && Directory.Exists(savedDirectory))
            return Path.GetFullPath(savedDirectory);

        var installedDirectory = Path.Combine(AppContext.BaseDirectory, "scenes");
        if (Directory.Exists(installedDirectory) &&
            Directory.EnumerateFiles(installedDirectory, "*.scn", SearchOption.AllDirectories).Any())
            return installedDirectory;

        var workingDirectory = Path.GetFullPath(Path.Combine(Environment.CurrentDirectory, "scenes"));
        if (Directory.Exists(workingDirectory)) return workingDirectory;

        Directory.CreateDirectory(installedDirectory);
        return installedDirectory;
    }

    private async void OpenScene_Click(object? sender, RoutedEventArgs e) => await OpenSceneAsync();
    private async void ChooseFolder_Click(object? sender, RoutedEventArgs e) => await ChooseFolderAsync();
    private async void DownloadScenes_Click(object? sender, RoutedEventArgs e) => await DownloadScenesAsync();
    private async void Rescan_Click(object? sender, RoutedEventArgs e) => await ScanLibraryAsync(startPlayback: false);
    private async void SceneReviewer_Click(object? sender, RoutedEventArgs e) => await OpenSceneReviewerAsync();
    private void MainContextMenu_Opened(object? sender, RoutedEventArgs e)
    {
        PopulateFontMenus();
        ApplySettingsToMenu();
    }
    private void PlayPause_Click(object? sender, RoutedEventArgs e) => TogglePause();
    private void NextFrame_Click(object? sender, RoutedEventArgs e) => MoveFrame(1);
    private void PreviousFrame_Click(object? sender, RoutedEventArgs e) => MoveFrame(-1);
    private async void NextAnimation_Click(object? sender, RoutedEventArgs e) => await PlayLibraryOffsetAsync(1);
    private async void PreviousAnimation_Click(object? sender, RoutedEventArgs e) => await PlayLibraryOffsetAsync(-1);
    private void RandomMode_Click(object? sender, RoutedEventArgs e)
    {
        _randomMode = !_randomMode;
        _settings = _settings with { RandomPlayback = _randomMode };
        ApplySettingsToMenu();
        SaveSettings();
    }
    private void AutomaticCycle_Click(object? sender, RoutedEventArgs e)
    {
        _settings = _settings with { AutomaticCycle = !_settings.AutomaticCycle };
        ApplySettingsToMenu();
        if (_settings.AutomaticCycle && _displayMode == DisplayMode.Time)
            _clockUntilUtc = DateTimeOffset.UtcNow.AddSeconds(_settings.ClockDisplaySeconds);
        SaveSettings();
    }
    private void ClockTime10_Click(object? sender, RoutedEventArgs e) => SetClockDisplaySeconds(10);
    private void ClockTime30_Click(object? sender, RoutedEventArgs e) => SetClockDisplaySeconds(30);
    private void ClockTime60_Click(object? sender, RoutedEventArgs e) => SetClockDisplaySeconds(60);
    private void Animations1_Click(object? sender, RoutedEventArgs e) => SetAnimationsPerCycle(1);
    private void Animations3_Click(object? sender, RoutedEventArgs e) => SetAnimationsPerCycle(3);
    private void Animations5_Click(object? sender, RoutedEventArgs e) => SetAnimationsPerCycle(5);
    private void AnimationGap0_Click(object? sender, RoutedEventArgs e) => SetAnimationGapSeconds(0);
    private void AnimationGap5_Click(object? sender, RoutedEventArgs e) => SetAnimationGapSeconds(5);
    private void AnimationGap10_Click(object? sender, RoutedEventArgs e) => SetAnimationGapSeconds(10);
    private void AnimationGap30_Click(object? sender, RoutedEventArgs e) => SetAnimationGapSeconds(30);
    private void AppearanceOrange_Click(object? sender, RoutedEventArgs e) => SetColorPreset(DmdColorPreset.Orange);
    private void AppearanceAmber_Click(object? sender, RoutedEventArgs e) => SetColorPreset(DmdColorPreset.Amber);
    private void AppearanceRed_Click(object? sender, RoutedEventArgs e) => SetColorPreset(DmdColorPreset.Red);
    private void AppearanceGreen_Click(object? sender, RoutedEventArgs e) => SetColorPreset(DmdColorPreset.Green);
    private void AppearanceBlue_Click(object? sender, RoutedEventArgs e) => SetColorPreset(DmdColorPreset.Blue);
    private void AppearanceCyan_Click(object? sender, RoutedEventArgs e) => SetColorPreset(DmdColorPreset.Cyan);
    private void AppearanceMagenta_Click(object? sender, RoutedEventArgs e) => SetColorPreset(DmdColorPreset.Magenta);
    private void PlasmaNeon_Click(object? sender, RoutedEventArgs e) => SetPlasmaPalette(PlasmaPalettePreset.Neon);
    private void PlasmaLava_Click(object? sender, RoutedEventArgs e) => SetPlasmaPalette(PlasmaPalettePreset.Lava);
    private void PlasmaOcean_Click(object? sender, RoutedEventArgs e) => SetPlasmaPalette(PlasmaPalettePreset.Ocean);
    private void PlasmaAurora_Click(object? sender, RoutedEventArgs e) => SetPlasmaPalette(PlasmaPalettePreset.Aurora);
    private void PlasmaToxic_Click(object? sender, RoutedEventArgs e) => SetPlasmaPalette(PlasmaPalettePreset.Toxic);
    private void PlasmaVapor_Click(object? sender, RoutedEventArgs e) => SetPlasmaPalette(PlasmaPalettePreset.Vapor);
    private void PlasmaSolar_Click(object? sender, RoutedEventArgs e) => SetPlasmaPalette(PlasmaPalettePreset.Solar);
    private void PlasmaArctic_Click(object? sender, RoutedEventArgs e) => SetPlasmaPalette(PlasmaPalettePreset.Arctic);
    private async void PlasmaCustom_Click(object? sender, RoutedEventArgs e) => await CustomizePlasmaPaletteAsync();
    private void PlasmaSlow_Click(object? sender, RoutedEventArgs e) => SetPlasmaSpeed(16_000);
    private void PlasmaNormal_Click(object? sender, RoutedEventArgs e) => SetPlasmaSpeed(8_000);
    private void PlasmaFast_Click(object? sender, RoutedEventArgs e) => SetPlasmaSpeed(4_000);
    private void PlasmaVeryFast_Click(object? sender, RoutedEventArgs e) => SetPlasmaSpeed(2_000);
    private async void PlasmaCustomSpeed_Click(object? sender, RoutedEventArgs e) => await CustomizePlasmaSpeedAsync();
    private void AppearanceMonochrome_Click(object? sender, RoutedEventArgs e) => SetColorPreset(DmdColorPreset.Monochrome);
    private void AppearanceNeonSunset_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.NeonSunset);
    private void AppearanceCyberOcean_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.CyberOcean);
    private void AppearanceToxicArcade_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.ToxicArcade);
    private void AppearanceVaporwave_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.Vaporwave);
    private void AppearanceAurora_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.Aurora);
    private void AppearanceFirestorm_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.Firestorm);
    private void AppearanceElectricViolet_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.ElectricViolet);
    private void AppearanceArcticGlow_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.ArcticGlow);
    private void AppearanceC64BlueRound_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.C64BlueRound);
    private void AppearanceC64RedRound_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.C64RedRound);
    private void AppearanceC64Earthtone_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.C64Earthtone);
    private void AppearanceC64Metal_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.C64Metal);
    private void AppearanceC64InterlacedBlue_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.C64InterlacedBlue);
    private void AppearanceC64ExtrudedCyan_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.C64ExtrudedCyan);
    private void AppearanceC64Rainbow_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.C64Rainbow);
    private void AppearanceC64PurpleHalo_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.C64PurpleHalo);
    private void AppearanceRasterGreenHalo_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.RasterGreenHalo);
    private void AppearanceRasterAmberHalo_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.RasterAmberHalo);
    private void AppearanceRasterPurplePulse_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.RasterPurplePulse);
    private void AppearanceRasterOceanDepth_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.RasterOceanDepth);
    private void AppearanceRasterSunsetBands_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.RasterSunsetBands);
    private void AppearanceRasterForestLayers_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.RasterForestLayers);
    private void AppearanceRasterArcticBands_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.RasterArcticBands);
    private void AppearanceRasterCandyStripe_Click(object? sender, RoutedEventArgs e) => SetMultiColorTheme(DmdColorPreset.RasterCandyStripe);
    private void Brightness25_Click(object? sender, RoutedEventArgs e) => SetBrightness(25);
    private void Brightness50_Click(object? sender, RoutedEventArgs e) => SetBrightness(50);
    private void Brightness75_Click(object? sender, RoutedEventArgs e) => SetBrightness(75);
    private void Brightness100_Click(object? sender, RoutedEventArgs e) => SetBrightness(100);
    private void Glow_Click(object? sender, RoutedEventArgs e)
    {
        _settings = (_settings with { GlowEnabled = !(_settings.GlowEnabled ?? true) }).Normalize();
        ApplySettingsToMenu();
        SaveSettings();
        SetStatus((_settings.GlowEnabled ?? true) ? "Glöd: på" : "Glöd: av");
    }
    private void HotCoreOff_Click(object? sender, RoutedEventArgs e) => SetHotCore(false, _settings.HotCoreStyle ?? HotCoreStyle.Classic);
    private void HotCoreClassic_Click(object? sender, RoutedEventArgs e) => SetHotCore(true, HotCoreStyle.Classic);
    private void HotCoreTheme_Click(object? sender, RoutedEventArgs e) => SetHotCore(true, HotCoreStyle.Theme);
    private async void HotCoreDual_Click(object? sender, RoutedEventArgs e) => await PickHotCoreColorAsync(enableDualMode: true);
    private async void HotCoreColor_Click(object? sender, RoutedEventArgs e) => await PickHotCoreColorAsync(enableDualMode: false);
    private void DotDepthFlat_Click(object? sender, RoutedEventArgs e) => SetDotDepth(DotDepthStyle.Flat);
    private void DotDepthSubtle_Click(object? sender, RoutedEventArgs e) => SetDotDepth(DotDepthStyle.Subtle);
    private void DotDepthDeep_Click(object? sender, RoutedEventArgs e) => SetDotDepth(DotDepthStyle.Deep);
    private async void ForegroundColor_Click(object? sender, RoutedEventArgs e) => await PickColorAsync(foreground: true);
    private async void BackgroundColor_Click(object? sender, RoutedEventArgs e) => await PickColorAsync(foreground: false);
    private void BackgroundTheme_Click(object? sender, RoutedEventArgs e) => SetBackgroundMode(DmdBackgroundMode.Theme);
    private void BackgroundBlack_Click(object? sender, RoutedEventArgs e) => SetBackgroundMode(DmdBackgroundMode.Black);
    private void ResetCustomColors_Click(object? sender, RoutedEventArgs e) => ResetCustomColors();
    private void AnimationInfo_Click(object? sender, RoutedEventArgs e) => ToggleAnimationInformation();
    private void ShowTime_Click(object? sender, RoutedEventArgs e) => Show(DisplayMode.Time);
    private void ShowDate_Click(object? sender, RoutedEventArgs e) => Show(DisplayMode.Date);
    private void Fullscreen_Click(object? sender, RoutedEventArgs e) => ToggleFullscreen();
    private void IncreaseDisplaySize_Click(object? sender, RoutedEventArgs e) => AdjustDisplaySize(5);
    private void DecreaseDisplaySize_Click(object? sender, RoutedEventArgs e) => AdjustDisplaySize(-5);
    private void ResetDisplaySize_Click(object? sender, RoutedEventArgs e) => ResetDisplaySize();
    private void HelpGitHub_Click(object? sender, RoutedEventArgs e)
        => OpenHelpGitHub();

    private void StartupCredit_PointerPressed(object? sender, PointerPressedEventArgs e)
    {
        if (_launchOptions.Mode == ScreenSaverLaunchMode.Fullscreen)
            Close();
        else if (_launchOptions.Mode != ScreenSaverLaunchMode.Preview)
            OpenHelpGitHub();
        e.Handled = true;
    }

    private void OpenHelpGitHub()
    {
        try
        {
            Process.Start(new ProcessStartInfo(HelpGitHubUrl) { UseShellExecute = true });
            _ = _log.WriteAsync(DateTimeOffset.UtcNow, $"help.open url=\"{HelpGitHubUrl}\"");
        }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            SetStatus($"Kan inte öppna GitHub: {exception.Message}");
        }
    }
    private void EnglishLanguage_Click(object? sender, RoutedEventArgs e) => SetLanguage("en");
    private void SwedishLanguage_Click(object? sender, RoutedEventArgs e) => SetLanguage("sv");
    private void Clock24_Click(object? sender, RoutedEventArgs e) => SetClockFormat("24");
    private void Clock12_Click(object? sender, RoutedEventArgs e) => SetClockFormat("12");
    private void ShowSeconds_Click(object? sender, RoutedEventArgs e) => ToggleShowSeconds();
    private void ShowTitleBar_Click(object? sender, RoutedEventArgs e) => ToggleTitleBar();
    private void DateIso_Click(object? sender, RoutedEventArgs e) => SetDateFormat("yyyy-MM-dd");
    private void DateEuropean_Click(object? sender, RoutedEventArgs e) => SetDateFormat("dd/MM/yyyy");
    private void DateUs_Click(object? sender, RoutedEventArgs e) => SetDateFormat("MM/dd/yyyy");
    private void DateDots_Click(object? sender, RoutedEventArgs e) => SetDateFormat("dd.MM.yyyy");
    private void Exit_Click(object? sender, RoutedEventArgs e)
    {
        _exitRequestedByMenu = true;
        Close();
    }

    private void Display_PointerPressed(object? sender, PointerPressedEventArgs e)
    {
        if (_launchOptions.Mode == ScreenSaverLaunchMode.Fullscreen)
        {
            Close();
            e.Handled = true;
            return;
        }
        if (_launchOptions.Mode == ScreenSaverLaunchMode.Preview) return;
        if (!(_settings.ShowTitleBar ?? true) && e.GetCurrentPoint(this).Properties.IsLeftButtonPressed)
        {
            BeginMoveDrag(e);
            e.Handled = true;
        }
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        ShowCursorAndRestartTimeout();
        if (_launchOptions.Mode != ScreenSaverLaunchMode.Fullscreen) return;
        var position = e.GetPosition(this);
        if (DateTimeOffset.UtcNow - _startedUtc < TimeSpan.FromSeconds(2))
        {
            _screenSaverMouseOrigin = position;
            return;
        }
        if (_screenSaverMouseOrigin is not { } origin)
        {
            _screenSaverMouseOrigin = position;
            return;
        }
        var deltaX = position.X - origin.X;
        var deltaY = position.Y - origin.Y;
        if ((deltaX * deltaX) + (deltaY * deltaY) >= 64) Close();
    }

    protected override void OnPointerEntered(PointerEventArgs e)
    {
        base.OnPointerEntered(e);
        _pointerIsOverWindow = true;
        ShowCursorAndRestartTimeout();
    }

    protected override void OnPointerExited(PointerEventArgs e)
    {
        base.OnPointerExited(e);
        _pointerIsOverWindow = false;
        _cursorHideTimer.Stop();
        Cursor = null;
    }

    private void ShowCursorAndRestartTimeout()
    {
        if (!_pointerIsOverWindow) return;
        Cursor = null;
        _cursorHideTimer.Stop();
        _cursorHideTimer.Start();
    }

    private void HideInactiveCursor()
    {
        _cursorHideTimer.Stop();
        if (_pointerIsOverWindow) Cursor = _hiddenCursor;
    }

    private void ConfigureLaunchMode()
    {
        if (_launchOptions.Mode == ScreenSaverLaunchMode.Fullscreen)
        {
            WindowDecorations = Avalonia.Controls.WindowDecorations.None;
            WindowState = WindowState.FullScreen;
            ShowInTaskbar = false;
            Topmost = true;
            Display.ContextMenu = null;
        }
        else if (_launchOptions.Mode == ScreenSaverLaunchMode.Preview)
        {
            WindowDecorations = Avalonia.Controls.WindowDecorations.None;
            WindowStartupLocation = WindowStartupLocation.Manual;
            ShowInTaskbar = false;
            CanResize = false;
            Display.ContextMenu = null;
        }
    }

    private enum DisplayMode { Time, Date, Animation }
}
