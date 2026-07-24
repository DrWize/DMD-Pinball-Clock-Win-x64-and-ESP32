namespace DmdClock.Core.Library;

public enum AnimationSelectionState
{
    Unreviewed,
    Allowed,
    Disallowed
}
public sealed record AnimationSelectionEntry(
    string Id,
    string LastRelativePath,
    string Sha256,
    AnimationSelectionState State);

public sealed record AnimationSelectionDocument(
    int SchemaVersion,
    string? LibraryRoot,
    int Columns,
    int Rows,
    bool DefaultGamesEnabled,
    AnimationSelectionState DefaultSceneState,
    IReadOnlyList<string> EnabledGames,
    IReadOnlyList<string> DisabledGames,
    IReadOnlyList<AnimationSelectionEntry> Scenes)
{
    public const int CurrentSchemaVersion = 2;

    public static AnimationSelectionDocument Empty { get; } =
        new(
            CurrentSchemaVersion,
            null,
            5,
            8,
            DefaultGamesEnabled: true,
            DefaultSceneState: AnimationSelectionState.Allowed,
            EnabledGames: [],
            DisabledGames: [],
            Scenes: []);

    public AnimationSelectionDocument Normalize() => this with
    {
        SchemaVersion = CurrentSchemaVersion,
        LibraryRoot = NormalizeRoot(LibraryRoot),
        Columns = Math.Clamp(Columns, 1, 20),
        Rows = Math.Clamp(Rows, 1, 20),
        EnabledGames = (EnabledGames ?? [])
            .Where(static game => !string.IsNullOrWhiteSpace(game))
            .Select(static game => game.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Order(StringComparer.OrdinalIgnoreCase)
            .ToArray(),
        DisabledGames = (DisabledGames ?? [])
            .Where(static game => !string.IsNullOrWhiteSpace(game))
            .Select(static game => game.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Order(StringComparer.OrdinalIgnoreCase)
            .ToArray(),
        Scenes = (Scenes ?? [])
            .Where(static scene =>
                !string.IsNullOrWhiteSpace(scene.Id) &&
                !string.IsNullOrWhiteSpace(scene.LastRelativePath))
            .GroupBy(static scene => scene.Id, StringComparer.OrdinalIgnoreCase)
            .Select(static group => group.Last() with
            {
                Id = group.Last().Id.Trim(),
                LastRelativePath = NormalizePath(group.Last().LastRelativePath),
                Sha256 = group.Last().Sha256?.Trim() ?? string.Empty
            })
            .OrderBy(static scene => scene.LastRelativePath, NaturalPathComparer.Instance)
            .ToArray()
    };

    private static string? NormalizeRoot(string? root)
    {
        if (string.IsNullOrWhiteSpace(root)) return null;
        try { return Path.GetFullPath(root.Trim()); }
        catch (Exception exception) when (
            exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return null;
        }
    }

    internal static string NormalizePath(string path) => path.Replace('\\', '/').TrimStart('/');
}

public sealed record AnimationCatalogItem(
    AnimationLibraryItem LibraryItem,
    ResolvedSceneMetadata Metadata)
{
    public string Game => string.IsNullOrWhiteSpace(Metadata.Game) ? "Unknown" : Metadata.Game;
    public string DisplayName => Metadata.Title ?? Metadata.DisplayName;
}
