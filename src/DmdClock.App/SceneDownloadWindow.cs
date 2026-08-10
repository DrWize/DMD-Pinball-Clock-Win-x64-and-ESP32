using System.Diagnostics;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using DmdClock.App.Localization;
using DmdClock.Core.Library;

namespace DmdClock.App;

public sealed class SceneDownloadWindow : Window
{
    private readonly string _destinationRoot;
    private readonly ComboBox _packSelector;
    private readonly TextBlock _packDescription;
    private readonly TextBlock _destination;
    private readonly ProgressBar _progress;
    private readonly TextBlock _status;
    private readonly Button _download;
    private readonly Button _cancel;
    private readonly Button _source;
    private readonly CancellationTokenSource _cancellation = new();
    private IReadOnlyList<ScenePackCatalogEntry> _packs = [];
    private bool _downloadStarted;

    public SceneDownloadWindow(
        string destinationRoot,
        string title,
        string description,
        string sourceText,
        string downloadText,
        string cancelText)
    {
        _destinationRoot = destinationRoot;
        Title = title;
        Width = 620;
        MinWidth = 620;
        SizeToContent = SizeToContent.Height;
        CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        _progress = new ProgressBar
        {
            Minimum = 0,
            Maximum = 100,
            Height = 12,
            IsVisible = false
        };
        _status = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Foreground = Brushes.Gray
        };
        _packSelector = new ComboBox { MinWidth = 360, IsEnabled = false };
        _packDescription = new TextBlock { TextWrapping = TextWrapping.Wrap };
        _destination = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            FontFamily = FontFamily.Parse("Consolas"),
            FontSize = 11,
            Foreground = Brushes.Gray
        };
        _download = new Button { Content = downloadText, MinWidth = 130, IsEnabled = false };
        _cancel = new Button { Content = cancelText, MinWidth = 90 };
        _source = new Button
        {
            Content = sourceText,
            HorizontalAlignment = HorizontalAlignment.Left,
            IsEnabled = false
        };

        _download.Click += async (_, _) => await DownloadAsync();
        _cancel.Click += (_, _) => CancelOrClose();
        _source.Click += (_, _) => OpenSource();
        _packSelector.SelectionChanged += (_, _) => UpdateSelectedPack();

        Content = new StackPanel
        {
            Margin = new Thickness(22),
            Spacing = 12,
            Children =
            {
                new TextBlock
                {
                    Text = description,
                    TextWrapping = TextWrapping.Wrap
                },
                _packSelector,
                _packDescription,
                _destination,
                _source,
                _progress,
                _status,
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    HorizontalAlignment = HorizontalAlignment.Right,
                    Spacing = 10,
                    Children = { _cancel, _download }
                }
            }
        };
    }

    protected override async void OnOpened(EventArgs e)
    {
        base.OnOpened(e);
        await LoadCatalogAsync();
    }

    protected override void OnClosed(EventArgs e)
    {
        _cancellation.Cancel();
        _cancellation.Dispose();
        base.OnClosed(e);
    }

    private async Task DownloadAsync()
    {
        if (_downloadStarted || SelectedPack is not { } pack) return;
        _downloadStarted = true;
        _download.IsEnabled = false;
        _progress.IsVisible = true;
        _progress.IsIndeterminate = true;
        _status.Text = L("sceneDownloadConnecting");

        var progress = new Progress<ScenePackDownloadProgress>(value =>
        {
            if (value.Percentage is { } percentage)
            {
                _progress.IsIndeterminate = false;
                _progress.Value = percentage;
                _status.Text = string.Format(
                    System.Globalization.CultureInfo.CurrentCulture,
                    L("sceneDownloadingPercent"),
                    percentage,
                    FormatBytes(value.BytesDownloaded));
            }
            else
            {
                _progress.IsIndeterminate = true;
                _status.Text = string.Format(
                    System.Globalization.CultureInfo.CurrentCulture,
                    L("sceneDownloading"),
                    FormatBytes(value.BytesDownloaded));
            }
        });

        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromMinutes(15) };
            var metadataPath = Path.Combine(
                AppContext.BaseDirectory, "scenes", SceneMetadataStore.DefaultFileName);
            var destinationDirectory = Path.Combine(_destinationRoot, pack.ManagedDirectory);
            var result = await new ScenePackDownloader(client).DownloadAndInstallAsync(
                pack,
                destinationDirectory,
                progress,
                _cancellation.Token,
                File.Exists(metadataPath) ? metadataPath : null);
            Close(result);
        }
        catch (OperationCanceledException)
        {
            if (IsVisible) Close(null);
        }
        catch (Exception exception) when (
            exception is HttpRequestException or IOException or UnauthorizedAccessException or InvalidDataException)
        {
            _status.Text = string.Format(
                System.Globalization.CultureInfo.CurrentCulture,
                L("sceneDownloadFailed"),
                exception.Message);
            _progress.IsIndeterminate = false;
            _progress.Value = 0;
            _downloadStarted = false;
            _download.IsEnabled = true;
        }
    }

    private void CancelOrClose()
    {
        if (_downloadStarted)
        {
            _cancel.IsEnabled = false;
            _status.Text = L("sceneDownloadCancelling");
            _cancellation.Cancel();
        }
        else
            Close(null);
    }

    private void OpenSource()
    {
        if (SelectedPack is not { } pack) return;
        try
        {
            Process.Start(new ProcessStartInfo(pack.SourcePageUrl) { UseShellExecute = true });
        }
        catch (Exception exception) when (
            exception is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            _status.Text = string.Format(
                System.Globalization.CultureInfo.CurrentCulture,
                L("sceneSourceOpenFailed"),
                exception.Message);
        }
    }

    private async Task LoadCatalogAsync()
    {
        _status.Text = L("sceneDownloadConnecting");
        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            var platform = OperatingSystem.IsMacOS() ? "osx-arm64" : "windows-x64";
            var catalog = await new ScenePackCatalogClient(client).DownloadAsync(_cancellation.Token);
            _packs = catalog.Packs
                .Where(pack => pack.Available &&
                    pack.SupportedPlatforms.Contains(platform, StringComparer.OrdinalIgnoreCase))
                .OrderByDescending(pack => pack.Preferred)
                .ThenBy(pack => pack.DisplayName, StringComparer.CurrentCultureIgnoreCase)
                .ToArray();
            if (_packs.Count != 2)
                throw new InvalidDataException("The shared catalog must provide both scene packs for this platform.");
            _packSelector.ItemsSource = _packs.Select(PackLabel).ToArray();
            var preferred = catalog.GetPreferredAvailablePack(platform);
            _packSelector.SelectedIndex = _packs
                .Select((pack, index) => (pack, index))
                .Single(item => string.Equals(
                    item.pack.PackId, preferred.PackId, StringComparison.OrdinalIgnoreCase)).index;
            _packSelector.IsEnabled = true;
            _source.IsEnabled = true;
            _download.IsEnabled = true;
            _status.Text = L("scenePackReady");
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) when (exception is HttpRequestException or IOException or InvalidDataException)
        {
            _status.Text = string.Format(
                System.Globalization.CultureInfo.CurrentCulture,
                L("sceneDownloadFailed"), exception.Message);
        }
    }

    private ScenePackCatalogEntry? SelectedPack =>
        _packSelector.SelectedIndex >= 0 && _packSelector.SelectedIndex < _packs.Count
            ? _packs[_packSelector.SelectedIndex]
            : null;

    private void UpdateSelectedPack()
    {
        if (SelectedPack is not { } pack) return;
        _packDescription.Text = pack.Description;
        _destination.Text = Path.Combine(_destinationRoot, pack.ManagedDirectory);
    }

    private static string PackLabel(ScenePackCatalogEntry pack) =>
        $"{pack.DisplayName} — {pack.SceneCount:N0} scenes" +
        (pack.Preferred ? " (Preferred)" : string.Empty);

    private static string FormatBytes(long bytes) =>
        bytes >= 1024L * 1024
            ? $"{bytes / (1024d * 1024d):N1} MB"
            : $"{bytes / 1024d:N0} KB";

    private static string L(string key) => LocalizationManager.Get(key);
}
