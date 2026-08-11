namespace DmdClock.Core.Library;

public sealed record ScenePackCatalog(
    int SchemaVersion,
    DateTimeOffset UpdatedAt,
    IReadOnlyList<ScenePackCatalogEntry> Packs)
{
    public const int CurrentSchemaVersion = 1;

    public ScenePackCatalogEntry GetPreferredAvailablePack(string platform)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(platform);
        return Packs.SingleOrDefault(item =>
            item.Preferred && item.Available &&
            item.SupportedPlatforms.Contains(platform, StringComparer.OrdinalIgnoreCase)) ??
            throw new InvalidDataException($"The catalog does not define one preferred scene library for '{platform}'.");
    }

    public ScenePackCatalogEntry GetRequiredAvailablePack(string packId, string platform)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(packId);
        ArgumentException.ThrowIfNullOrWhiteSpace(platform);
        var pack = Packs.SingleOrDefault(item =>
            string.Equals(item.PackId, packId, StringComparison.OrdinalIgnoreCase)) ??
            throw new InvalidDataException($"Scene library '{packId}' is not present in the catalog.");
        if (!pack.Available)
            throw new InvalidDataException($"Scene library '{pack.DisplayName}' is not available for download.");
        if (!pack.SupportedPlatforms.Contains(platform, StringComparer.OrdinalIgnoreCase))
            throw new InvalidDataException($"Scene library '{pack.DisplayName}' does not support '{platform}'.");
        return pack;
    }
}

public sealed record ScenePackCatalogEntry(
    string PackId,
    string DisplayName,
    string Description,
    string Version,
    string ManagedDirectory,
    bool Preferred,
    IReadOnlyList<string> IncludesPackIds,
    bool Available,
    string DistributionStatus,
    string SourcePageUrl,
    string? DownloadUrl,
    string? SourceRevision,
    string ArchiveFormat,
    string ScenesPathMarker,
    long? DownloadBytes,
    long InstalledBytes,
    string? ArchiveSha256,
    int SceneCount,
    IReadOnlyList<string> SupportedPlatforms);
