namespace DmdClock.Core.Library;

public sealed record ScenePackInstallResult(
    string DestinationDirectory,
    int SceneCount,
    long DownloadedBytes,
    string PackId,
    string DisplayName,
    string SourcePageUrl);
