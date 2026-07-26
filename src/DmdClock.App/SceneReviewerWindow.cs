using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using System.Diagnostics;
using DmdClock.App.Controls;
using DmdClock.Core;
using DmdClock.Core.Clock;
using DmdClock.Core.Library;
using DmdClock.Core.Playback;
using DmdClock.Core.Rendering;
using DmdClock.Core.Scn;
using DmdClock.Core.Settings;

namespace DmdClock.App;

public sealed class SceneReviewerWindow : Window
{
    private readonly string _libraryRoot;
    private readonly IReadOnlyList<AnimationCatalogItem> _catalog;
    private readonly AnimationSelectionStore _store;
    private readonly string _selectionPath;
    private readonly DmdClockSettings _settings;
    private readonly ComboBox _gamePicker;
    private readonly ComboBox _filterPicker;
    private readonly NumericUpDown _columns;
    private readonly NumericUpDown _rows;
    private readonly CheckBox _gameEnabled;
    private readonly TextBlock _pageText;
    private readonly TextBlock _summaryText;
    private readonly TextBlock _statusText;
    private readonly Grid _tileGrid;
    private readonly Button _previous;
    private readonly Button _next;
    private readonly DispatcherTimer _timer;
    private readonly SemaphoreSlim _saveGate = new(1, 1);
    private readonly List<TileSession> _tiles = [];
    private readonly IReadOnlyList<GameOption> _games;
    private readonly Stopwatch _effectClock = Stopwatch.StartNew();
    private CancellationTokenSource _pageCancellation = new();
    private AnimationSelectionDocument _document;
    private int _page;
    private bool _paused;
    private bool _updatingControls;

    public SceneReviewerWindow(
        string libraryRoot,
        IReadOnlyList<AnimationCatalogItem> catalog,
        AnimationSelectionStore store,
        string selectionPath,
        AnimationSelectionDocument document,
        DmdClockSettings settings)
    {
        _libraryRoot = Path.GetFullPath(libraryRoot);
        _catalog = catalog.ToArray();
        _store = store;
        _selectionPath = selectionPath;
        _document = (document with { LibraryRoot = _libraryRoot }).Normalize();
        _settings = settings;
        _games = BuildGames(_catalog);

        Title = "DMDClock Scene Reviewer";
        Width = 1500;
        Height = 920;
        MinWidth = 900;
        MinHeight = 620;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = new SolidColorBrush(Color.Parse("#111111"));

        _gamePicker = new ComboBox
        {
            Width = 320,
            ItemsSource = _games,
            SelectedIndex = _games.Count > 0 ? 0 : -1
        };
        _filterPicker = new ComboBox
        {
            Width = 130,
            ItemsSource = new[] { "All", "Unreviewed", "Allowed", "Disallowed" },
            SelectedIndex = 0
        };
        _columns = Number(_document.Columns);
        _rows = Number(_document.Rows);
        _gameEnabled = new CheckBox { Content = "Enable game for clock" };
        _pageText = MutedText();
        _summaryText = MutedText();
        _statusText = MutedText();
        _previous = new Button { Content = "Previous", MinWidth = 90 };
        _next = new Button { Content = "Next", MinWidth = 90 };
        var allowPage = new Button { Content = "Allow page" };
        var disallowPage = new Button { Content = "Disallow page" };
        var allowAll = new Button { Content = "Allow all" };
        var pause = new Button { Content = "Pause all" };

        _tileGrid = new Grid
        {
            Margin = new Thickness(10),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch
        };

        _gamePicker.SelectionChanged += async (_, _) =>
        {
            if (_updatingControls) return;
            _page = 0;
            UpdateGameEnabledControl();
            await RebuildPageAsync();
        };
        _filterPicker.SelectionChanged += async (_, _) =>
        {
            if (_updatingControls) return;
            _page = 0;
            await RebuildPageAsync();
        };
        _columns.ValueChanged += async (_, _) => await ChangeGridAsync();
        _rows.ValueChanged += async (_, _) => await ChangeGridAsync();
        _gameEnabled.IsCheckedChanged += async (_, _) =>
        {
            if (_updatingControls || SelectedGame is null) return;
            _document = AnimationSelectionResolver.SetGameEnabled(
                _document, SelectedGame.Game, _gameEnabled.IsChecked == true);
            await SaveAsync();
            UpdateSummary();
        };
        _previous.Click += async (_, _) =>
        {
            if (_page <= 0) return;
            _page--;
            await RebuildPageAsync();
        };
        _next.Click += async (_, _) =>
        {
            if (_page >= PageCount - 1) return;
            _page++;
            await RebuildPageAsync();
        };
        allowPage.Click += async (_, _) => await SetPageStateAsync(AnimationSelectionState.Allowed);
        disallowPage.Click += async (_, _) => await SetPageStateAsync(AnimationSelectionState.Disallowed);
        allowAll.Click += async (_, _) =>
        {
            _document = AnimationSelectionResolver.AllowAll(_document);
            UpdateGameEnabledControl();
            await SaveAsync();
            await RebuildPageAsync();
            _statusText.Text = "All valid scenes and games are allowed.";
        };
        pause.Click += (_, _) =>
        {
            _paused = !_paused;
            if (_paused) _effectClock.Stop(); else _effectClock.Start();
            pause.Content = _paused ? "Resume all" : "Pause all";
        };

        var toolbar = new WrapPanel
        {
            Margin = new Thickness(12, 10),
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center,
            ItemHeight = 34
        };
        toolbar.Children.Add(Label("Game"));
        toolbar.Children.Add(_gamePicker);
        toolbar.Children.Add(_gameEnabled);
        toolbar.Children.Add(Label("Filter"));
        toolbar.Children.Add(_filterPicker);
        toolbar.Children.Add(Label("Columns"));
        toolbar.Children.Add(_columns);
        toolbar.Children.Add(Label("Rows"));
        toolbar.Children.Add(_rows);
        toolbar.Children.Add(allowPage);
        toolbar.Children.Add(disallowPage);
        toolbar.Children.Add(allowAll);
        toolbar.Children.Add(pause);

        var footer = new Grid
        {
            Margin = new Thickness(12, 6, 12, 12),
            ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto,Auto")
        };
        var textStack = new StackPanel { Spacing = 2 };
        textStack.Children.Add(_summaryText);
        textStack.Children.Add(_statusText);
        footer.Children.Add(textStack);
        Grid.SetColumn(_pageText, 1);
        Grid.SetColumn(_previous, 2);
        Grid.SetColumn(_next, 3);
        footer.Children.Add(_pageText);
        footer.Children.Add(_previous);
        footer.Children.Add(_next);

        var layout = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto") };
        layout.Children.Add(toolbar);
        Grid.SetRow(_tileGrid, 1);
        layout.Children.Add(_tileGrid);
        Grid.SetRow(footer, 2);
        layout.Children.Add(footer);
        Content = layout;

        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(33) };
        _timer.Tick += (_, _) => Tick();
        _timer.Start();
        Closed += OnClosed;
        UpdateGameEnabledControl();
        Dispatcher.UIThread.Post(() => _ = RebuildPageAsync());
    }

    private GameOption? SelectedGame => _gamePicker.SelectedItem as GameOption;
    private int Columns => Math.Clamp((int)(_columns.Value ?? 5), 1, 20);
    private int Rows => Math.Clamp((int)(_rows.Value ?? 8), 1, 20);
    private int PageSize => Columns * Rows;
    private IReadOnlyList<AnimationCatalogItem> FilteredItems => GetFilteredItems();
    private int PageCount => Math.Max(1, (int)Math.Ceiling(FilteredItems.Count / (double)PageSize));

    private async Task ChangeGridAsync()
    {
        if (_updatingControls) return;
        _document = (_document with { Columns = Columns, Rows = Rows }).Normalize();
        _page = Math.Min(_page, PageCount - 1);
        await SaveAsync();
        await RebuildPageAsync();
    }

    private async Task RebuildPageAsync()
    {
        _pageCancellation.Cancel();
        _pageCancellation.Dispose();
        _pageCancellation = new CancellationTokenSource();
        var cancellationToken = _pageCancellation.Token;
        _tiles.Clear();
        _tileGrid.Children.Clear();
        _tileGrid.ColumnDefinitions.Clear();
        _tileGrid.RowDefinitions.Clear();
        for (var column = 0; column < Columns; column++)
            _tileGrid.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Star));
        for (var row = 0; row < Rows; row++)
            _tileGrid.RowDefinitions.Add(new RowDefinition(GridLength.Star));

        var filtered = FilteredItems;
        var pageCount = Math.Max(1, (int)Math.Ceiling(filtered.Count / (double)PageSize));
        _page = Math.Clamp(_page, 0, pageCount - 1);
        var pageItems = filtered.Skip(_page * PageSize).Take(PageSize).ToArray();
        _pageText.Text = $"Page {_page + 1} of {pageCount}";
        _previous.IsEnabled = _page > 0;
        _next.IsEnabled = _page + 1 < pageCount;
        _statusText.Text = pageItems.Length == 0
            ? "No scenes match this filter."
            : $"Loading {pageItems.Length} live scenes…";
        UpdateSummary();

        var now = DateTimeOffset.UtcNow;
        for (var index = 0; index < pageItems.Length; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var item = pageItems[index];
            var display = new DmdDisplay();
            ApplyAppearance(display);
            var title = new TextBlock
            {
                Text = item.LibraryItem.IsValid
                    ? $"{item.DisplayName} · {Path.GetFileName(item.LibraryItem.RelativePath)}"
                    : $"ERROR · {Path.GetFileName(item.LibraryItem.RelativePath)}",
                TextTrimming = TextTrimming.CharacterEllipsis,
                FontSize = 11,
                Margin = new Thickness(5, 2),
                HorizontalAlignment = HorizontalAlignment.Center
            };
            var content = new Grid { RowDefinitions = new RowDefinitions("*,Auto") };
            content.Children.Add(display);
            Grid.SetRow(title, 1);
            content.Children.Add(title);
            var border = new Border
            {
                Margin = new Thickness(3),
                Padding = new Thickness(2),
                BorderThickness = new Thickness(2),
                CornerRadius = new CornerRadius(4),
                Child = content,
                Cursor = new Cursor(StandardCursorType.Hand)
            };
            ToolTip.SetTip(
                border,
                $"{item.Game}\n{item.LibraryItem.RelativePath}\n" +
                "Left-click: Allowed/Unreviewed · Right-click: Disallowed/Allowed");
            var tile = new TileSession(item, border, display);
            ApplyTileState(tile);
            border.PointerPressed += async (_, eventArgs) =>
            {
                var properties = eventArgs.GetCurrentPoint(border).Properties;
                if (!properties.IsLeftButtonPressed && !properties.IsRightButtonPressed) return;
                if (!item.LibraryItem.IsValid)
                {
                    _statusText.Text =
                        $"{item.LibraryItem.RelativePath}: {item.LibraryItem.Error}";
                    eventArgs.Handled = true;
                    return;
                }
                var current = AnimationSelectionResolver.ResolveState(item, _document);
                var next = properties.IsRightButtonPressed
                    ? current == AnimationSelectionState.Disallowed
                        ? AnimationSelectionState.Allowed
                        : AnimationSelectionState.Disallowed
                    : current == AnimationSelectionState.Allowed
                        ? AnimationSelectionState.Unreviewed
                        : AnimationSelectionState.Allowed;
                _document = AnimationSelectionResolver.SetSceneState(_document, item, next);
                ApplyTileState(tile);
                await SaveAsync();
                UpdateSummary();
                eventArgs.Handled = true;
            };
            Grid.SetColumn(border, index % Columns);
            Grid.SetRow(border, index / Columns);
            _tileGrid.Children.Add(border);
            _tiles.Add(tile);
        }

        try
        {
            foreach (var tile in _tiles)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!tile.Item.LibraryItem.IsValid) continue;
                var fullPath = Path.Combine(
                    _libraryRoot,
                    tile.Item.LibraryItem.RelativePath.Replace(
                        '/', Path.DirectorySeparatorChar));
                var scene = await Task.Run(() => ScnReader.Read(fullPath), cancellationToken);
                tile.Scene = scene;
                tile.Playback = new ScenePlaybackSession(scene, now);
                RenderTile(tile, DateTimeOffset.Now);
            }
            _statusText.Text = pageItems.Length == 0
                ? "No scenes match this filter."
                : "All visible scenes are playing. Right-click a bad scene to disallow it.";
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            _statusText.Text = $"Some scenes could not be loaded: {exception.Message}";
        }
    }

    private void Tick()
    {
        if (_paused) return;
        var now = DateTimeOffset.UtcNow;
        var localNow = DateTimeOffset.Now;
        foreach (var tile in _tiles)
        {
            tile.Display.SetEffectTime(_effectClock.ElapsedMilliseconds);
            if (tile.Scene is null || tile.Playback is null) continue;
            var changed = tile.Playback.Advance(now);
            if (tile.Playback.IsComplete)
            {
                tile.Playback = new ScenePlaybackSession(tile.Scene, now);
                changed = true;
            }
            if (changed || tile.LastClockSecond != localNow.Second)
            {
                tile.LastClockSecond = localNow.Second;
                RenderTile(tile, localNow);
            }
        }
    }

    private void RenderTile(TileSession tile, DateTimeOffset now)
    {
        var playback = tile.Playback;
        if (playback is null) return;
        var storyboard = playback.Storyboard;
        var clock = storyboard.ClockStyle == 1
            ? ClockFrameFactory.CreateCompactTime(
                now, storyboard.CustomX, storyboard.CustomY,
                _settings.ClockFormat == "12")
            : ClockFrameFactory.Create(
                now,
                _settings.ClockFormat == "12",
                _settings.ShowSeconds ?? true);
        tile.Display.Frame = DmdFrameCompositor.Compose(
            playback.CurrentFrame, clock, playback.ClockAbove);
    }

    private async Task SetPageStateAsync(AnimationSelectionState state)
    {
        foreach (var tile in _tiles)
        {
            if (!tile.Item.LibraryItem.IsValid) continue;
            _document = AnimationSelectionResolver.SetSceneState(
                _document, tile.Item, state);
            ApplyTileState(tile);
        }
        await SaveAsync();
        UpdateSummary();
    }

    private async Task SaveAsync()
    {
        await _saveGate.WaitAsync();
        try { await _store.SaveAtomicAsync(_document, _selectionPath); }
        finally { _saveGate.Release(); }
    }

    private void ApplyTileState(TileSession tile)
    {
        if (!tile.Item.LibraryItem.IsValid)
        {
            tile.Border.BorderBrush = new SolidColorBrush(Color.Parse("#FF4D4D"));
            tile.Border.Background = new SolidColorBrush(Color.Parse("#661A1010"));
            tile.Border.Opacity = 0.72;
            return;
        }
        var state = AnimationSelectionResolver.ResolveState(tile.Item, _document);
        tile.Border.BorderBrush = state switch
        {
            AnimationSelectionState.Allowed => new SolidColorBrush(Color.Parse("#38C172")),
            AnimationSelectionState.Disallowed => new SolidColorBrush(Color.Parse("#E3342F")),
            _ => new SolidColorBrush(Color.Parse("#F2B134"))
        };
        tile.Border.Background = state == AnimationSelectionState.Disallowed
            ? new SolidColorBrush(Color.Parse("#551A1010"))
            : new SolidColorBrush(Color.Parse("#CC080808"));
        tile.Border.Opacity = state == AnimationSelectionState.Disallowed ? 0.62 : 1;
    }

    private void UpdateGameEnabledControl()
    {
        _updatingControls = true;
        _gameEnabled.IsChecked = SelectedGame is { } game &&
            AnimationSelectionResolver.IsGameEnabled(_document, game.Game);
        _updatingControls = false;
    }

    private void UpdateSummary()
    {
        if (SelectedGame is not { } game)
        {
            _summaryText.Text = "No games found.";
            return;
        }
        var scenes = _catalog.Where(item =>
            string.Equals(item.Game, game.Game, StringComparison.OrdinalIgnoreCase)).ToArray();
        var allowed = scenes.Count(item =>
            AnimationSelectionResolver.ResolveState(item, _document) == AnimationSelectionState.Allowed);
        var disallowed = scenes.Count(item =>
            AnimationSelectionResolver.ResolveState(item, _document) == AnimationSelectionState.Disallowed);
        var unreviewed = scenes.Length - allowed - disallowed;
        _summaryText.Text =
            $"{game.DisplayLabel}: {allowed} allowed · {disallowed} disallowed · {unreviewed} unreviewed";
    }

    private IReadOnlyList<AnimationCatalogItem> GetFilteredItems()
    {
        if (SelectedGame is not { } game) return [];
        var items = _catalog.Where(item =>
            string.Equals(item.Game, game.Game, StringComparison.OrdinalIgnoreCase));
        var filter = _filterPicker.SelectedIndex switch
        {
            1 => AnimationSelectionState.Unreviewed,
            2 => AnimationSelectionState.Allowed,
            3 => AnimationSelectionState.Disallowed,
            _ => (AnimationSelectionState?)null
        };
        if (filter is not null)
            items = items.Where(item =>
                AnimationSelectionResolver.ResolveState(item, _document) == filter);
        return items.OrderBy(
                static item => item.LibraryItem.RelativePath,
                NaturalPathComparer.Instance)
            .ToArray();
    }

    private void ApplyAppearance(DmdDisplay display) =>
        display.SetAppearance(
            _settings.ColorPreset ?? DmdColorPreset.Orange,
            _settings.BrightnessPercent ?? 100,
            _settings.GlowEnabled ?? true,
            _settings.ForegroundColor,
            _settings.BackgroundColor);

    private void OnClosed(object? sender, EventArgs e)
    {
        _timer.Stop();
        _pageCancellation.Cancel();
        _pageCancellation.Dispose();
    }

    private static IReadOnlyList<GameOption> BuildGames(
        IReadOnlyList<AnimationCatalogItem> catalog) =>
        catalog.GroupBy(static item => item.Game, StringComparer.OrdinalIgnoreCase)
            .Select(group =>
            {
                var years = group.Select(static item => item.Metadata.Year)
                    .Where(static year => year is not null)
                    .Select(static year => year!.Value)
                    .Distinct()
                    .ToArray();
                return new GameOption(
                    group.Key,
                    years.Length == 1 ? years[0] : null,
                    group.Count());
            })
            .OrderBy(static game => game.Game, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();

    private static NumericUpDown Number(int value) => new()
    {
        Minimum = 1,
        Maximum = 20,
        Increment = 1,
        Value = value,
        Width = 105,
        FormatString = "0"
    };

    private static TextBlock Label(string text) => new()
    {
        Text = text,
        Margin = new Thickness(12, 7, 5, 0),
        VerticalAlignment = VerticalAlignment.Center
    };

    private static TextBlock MutedText() => new()
    {
        Foreground = new SolidColorBrush(Color.Parse("#B8FFFFFF")),
        VerticalAlignment = VerticalAlignment.Center,
        Margin = new Thickness(8, 0)
    };

    private sealed record GameOption(string Game, int? Year, int SceneCount)
    {
        public string DisplayLabel => Year is { } year
            ? $"{Game} ({year})"
            : Game;

        public override string ToString() => $"{DisplayLabel} · {SceneCount} scenes";
    }

    private sealed class TileSession(
        AnimationCatalogItem item,
        Border border,
        DmdDisplay display)
    {
        public AnimationCatalogItem Item { get; } = item;
        public Border Border { get; } = border;
        public DmdDisplay Display { get; } = display;
        public ScnScene? Scene { get; set; }
        public ScenePlaybackSession? Playback { get; set; }
        public int LastClockSecond { get; set; } = -1;
    }
}
