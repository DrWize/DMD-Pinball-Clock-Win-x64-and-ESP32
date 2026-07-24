namespace DmdClock.Core.Library;

public static class AnimationSelectionResolver
{
    public static IReadOnlyList<AnimationCatalogItem> BuildCatalog(
        IEnumerable<AnimationLibraryItem> items,
        SceneMetadataCatalog metadata) =>
        items.Select(item => new AnimationCatalogItem(
                item,
                metadata.Resolve(item.RelativePath)))
            .ToArray();

    public static IReadOnlyList<AnimationLibraryItem> ResolvePlayable(
        IEnumerable<AnimationCatalogItem> catalog,
        AnimationSelectionDocument document)
    {
        var normalized = document.Normalize();
        return catalog
            .Where(item =>
                item.LibraryItem.IsValid &&
                IsGameEnabled(normalized, item.Game) &&
                ResolveState(item, normalized) == AnimationSelectionState.Allowed)
            .Select(static item => item.LibraryItem)
            .ToArray();
    }

    public static AnimationSelectionState ResolveState(
        AnimationCatalogItem item,
        AnimationSelectionDocument document)
    {
        var entries = document.Scenes ?? [];
        var byId = entries.LastOrDefault(entry =>
            string.Equals(entry.Id, item.LibraryItem.Id, StringComparison.OrdinalIgnoreCase));
        if (byId is not null) return byId.State;

        if (!string.IsNullOrWhiteSpace(item.LibraryItem.Sha256))
        {
            var byHash = entries.Where(entry =>
                    !string.IsNullOrWhiteSpace(entry.Sha256) &&
                    string.Equals(
                        entry.Sha256, item.LibraryItem.Sha256,
                        StringComparison.OrdinalIgnoreCase))
                .Take(2)
                .ToArray();
            if (byHash.Length == 1) return byHash[0].State;
        }

        var normalizedPath = AnimationSelectionDocument.NormalizePath(
            item.LibraryItem.RelativePath);
        return entries.LastOrDefault(entry =>
                string.Equals(
                    AnimationSelectionDocument.NormalizePath(entry.LastRelativePath),
                    normalizedPath,
                    StringComparison.OrdinalIgnoreCase))
            ?.State ?? document.DefaultSceneState;
    }

    public static AnimationSelectionDocument SetSceneState(
        AnimationSelectionDocument document,
        AnimationCatalogItem item,
        AnimationSelectionState state)
    {
        var entries = (document.Scenes ?? [])
            .Where(entry =>
                !string.Equals(
                    entry.Id, item.LibraryItem.Id, StringComparison.OrdinalIgnoreCase))
            .ToArray();
        if (state != document.DefaultSceneState)
        {
            entries =
            [
                .. entries,
                new AnimationSelectionEntry(
                    item.LibraryItem.Id,
                    item.LibraryItem.RelativePath,
                    item.LibraryItem.Sha256,
                    state)
            ];
        }
        return (document with { Scenes = entries }).Normalize();
    }

    public static AnimationSelectionDocument SetGameEnabled(
        AnimationSelectionDocument document,
        string game,
        bool enabled)
    {
        var enabledGames = (document.EnabledGames ?? [])
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var disabledGames = (document.DisabledGames ?? [])
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (document.DefaultGamesEnabled)
        {
            if (enabled) disabledGames.Remove(game);
            else disabledGames.Add(game);
        }
        else
        {
            if (enabled) enabledGames.Add(game);
            else enabledGames.Remove(game);
        }
        return (document with
        {
            EnabledGames = enabledGames.ToArray(),
            DisabledGames = disabledGames.ToArray()
        }).Normalize();
    }

    public static bool IsGameEnabled(
        AnimationSelectionDocument document,
        string game) =>
        document.DefaultGamesEnabled
            ? !(document.DisabledGames ?? []).Contains(
                game, StringComparer.OrdinalIgnoreCase)
            : (document.EnabledGames ?? []).Contains(
                game, StringComparer.OrdinalIgnoreCase);

    public static AnimationSelectionDocument AllowAll(
        AnimationSelectionDocument document) =>
        (document with
        {
            SchemaVersion = AnimationSelectionDocument.CurrentSchemaVersion,
            DefaultGamesEnabled = true,
            DefaultSceneState = AnimationSelectionState.Allowed,
            EnabledGames = [],
            DisabledGames = [],
            Scenes = []
        }).Normalize();
}
