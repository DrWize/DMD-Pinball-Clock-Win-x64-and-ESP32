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
    private readonly string _destinationDirectory;
    private readonly ProgressBar _progress;
    private readonly TextBlock _status;
    private readonly Button _download;
    private readonly Button _cancel;
    private readonly CancellationTokenSource _cancellation = new();
    private bool _downloadStarted;

    public SceneDownloadWindow(
        string destinationDirectory,
        string title,
        string description,
        string sourceText,
        string downloadText,
        string cancelText)
    {
        _destinationDirectory = destinationDirectory;
        Title = title;
        Width = 520;
        MinWidth = 520;
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
        _download = new Button { Content = downloadText, MinWidth = 130 };
        _cancel = new Button { Content = cancelText, MinWidth = 90 };
        var source = new Button
        {
            Content = sourceText,
            HorizontalAlignment = HorizontalAlignment.Left
        };

        _download.Click += async (_, _) => await DownloadAsync();
        _cancel.Click += (_, _) => CancelOrClose();
        source.Click += (_, _) => OpenSource();

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
                new TextBlock
                {
                    Text = destinationDirectory,
                    TextWrapping = TextWrapping.Wrap,
                    FontFamily = FontFamily.Parse("Consolas"),
                    FontSize = 11,
                    Foreground = Brushes.Gray
                },
                source,
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

    protected override void OnClosed(EventArgs e)
    {
        _cancellation.Cancel();
        _cancellation.Dispose();
        base.OnClosed(e);
    }

    private async Task DownloadAsync()
    {
        if (_downloadStarted) return;
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
            var platform = OperatingSystem.IsMacOS() ? "osx-arm64" : "windows-x64";
            var catalog = await new ScenePackCatalogClient(client)
                .DownloadAsync(_cancellation.Token);
            var pack = catalog.GetRequiredAvailablePack("drwize-complete", platform);
            var metadataPath = Path.Combine(
                AppContext.BaseDirectory, "scenes", SceneMetadataStore.DefaultFileName);
            var result = await new ScenePackDownloader(client).DownloadAndInstallAsync(
                pack,
                _destinationDirectory,
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
            exception is HttpRequestException or IOException or UnauthorizedAccessException)
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
        try
        {
            Process.Start(new ProcessStartInfo(ScenePackDownloader.SourcePageUrl) { UseShellExecute = true });
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

    private static string FormatBytes(long bytes) =>
        bytes >= 1024L * 1024
            ? $"{bytes / (1024d * 1024d):N1} MB"
            : $"{bytes / 1024d:N0} KB";

    private static string L(string key) => LocalizationManager.Get(key);
}
