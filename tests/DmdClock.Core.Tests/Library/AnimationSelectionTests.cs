using DmdClock.Core.Library;

namespace DmdClock.Core.Tests.Library;

public sealed class AnimationSelectionTests : IDisposable
{
    private readonly string _directory = Path.Combine(
        Path.GetTempPath(), $"dmdclock-selection-{Guid.NewGuid():N}");

    [Fact]
    public async Task Store_RoundTripsNormalizedSelectionAtomically()
    {
        var path = Path.Combine(_directory, "library-selections.json");
        var document = AnimationSelectionDocument.Empty with
        {
            LibraryRoot = _directory,
            Columns = 99,
            Rows = 0,
            DisabledGames = [" Attack from Mars ", "attack from mars"],
            Scenes =
            [
                new("ID1", @"folder\scene.scn", "HASH", AnimationSelectionState.Allowed)
            ]
        };
        var store = new AnimationSelectionStore();

        await store.SaveAtomicAsync(document, path);
        var loaded = await store.LoadAsync(path);

        Assert.Equal(20, loaded.Columns);
        Assert.Equal(1, loaded.Rows);
        Assert.True(loaded.DefaultGamesEnabled);
        Assert.Equal(AnimationSelectionState.Allowed, loaded.DefaultSceneState);
        Assert.Equal(["Attack from Mars"], loaded.DisabledGames);
        Assert.Equal("folder/scene.scn", Assert.Single(loaded.Scenes).LastRelativePath);
        Assert.Empty(Directory.EnumerateFiles(_directory, "*.tmp"));
    }

    [Fact]
    public void Resolver_AllowsValidScenesAndGamesByDefault()
    {
        var item = Catalog("ID1", "afm01.scn", "HASH", "Attack from Mars");

        Assert.Equal(
            ["afm01.scn"],
            AnimationSelectionResolver.ResolvePlayable(
                    [item], AnimationSelectionDocument.Empty)
                .Select(static scene => scene.RelativePath));
    }

    [Fact]
    public void Resolver_DisabledGameOrDisallowedSceneIsNotPlayable()
    {
        var item = Catalog("ID1", "afm01.scn", "HASH", "Attack from Mars");
        var disabledGame = AnimationSelectionResolver.SetGameEnabled(
            AnimationSelectionDocument.Empty, "Attack from Mars", enabled: false);
        var disallowedScene = AnimationSelectionResolver.SetSceneState(
            AnimationSelectionDocument.Empty, item, AnimationSelectionState.Disallowed);

        Assert.Empty(AnimationSelectionResolver.ResolvePlayable([item], disabledGame));
        Assert.Empty(AnimationSelectionResolver.ResolvePlayable([item], disallowedScene));
        Assert.Empty(AnimationSelectionResolver.ResolvePlayable(
            [item],
            AnimationSelectionResolver.SetSceneState(
                AnimationSelectionDocument.Empty,
                item,
                AnimationSelectionState.Unreviewed)));

        var restored = AnimationSelectionResolver.SetGameEnabled(
            disabledGame, "Attack from Mars", enabled: true);
        Assert.Single(AnimationSelectionResolver.ResolvePlayable([item], restored));
    }

    [Fact]
    public void Resolver_AllowAllClearsEveryException()
    {
        var item = Catalog("ID1", "afm01.scn", "HASH", "Attack from Mars");
        var restricted = AnimationSelectionResolver.SetSceneState(
            AnimationSelectionResolver.SetGameEnabled(
                AnimationSelectionDocument.Empty, "Attack from Mars", enabled: false),
            item,
            AnimationSelectionState.Disallowed);

        var allowed = AnimationSelectionResolver.AllowAll(restricted);

        Assert.True(AnimationSelectionResolver.IsGameEnabled(allowed, item.Game));
        Assert.Equal(AnimationSelectionState.Allowed,
            AnimationSelectionResolver.ResolveState(item, allowed));
        Assert.Empty(allowed.DisabledGames);
        Assert.Empty(allowed.Scenes);
        Assert.Single(AnimationSelectionResolver.ResolvePlayable([item], allowed));
    }

    [Fact]
    public void Resolver_ReconcilesUniqueHashThenPath()
    {
        var original = Catalog("OLD", "old.scn", "SAME", "Game");
        var document = AnimationSelectionResolver.SetSceneState(
            AnimationSelectionDocument.Empty,
            original,
            AnimationSelectionState.Disallowed);

        Assert.Equal(
            AnimationSelectionState.Disallowed,
            AnimationSelectionResolver.ResolveState(
                Catalog("NEW", "moved.scn", "SAME", "Game"), document));
        Assert.Equal(
            AnimationSelectionState.Disallowed,
            AnimationSelectionResolver.ResolveState(
                Catalog("NEW", "old.scn", "CHANGED", "Game"), document));
    }

    [Fact]
    public async Task Store_InvalidJsonFallsBackToEmptySelection()
    {
        Directory.CreateDirectory(_directory);
        var path = Path.Combine(_directory, "library-selections.json");
        await File.WriteAllTextAsync(path, "{broken");

        var loaded = await new AnimationSelectionStore().LoadAsync(path);

        Assert.Equal(AnimationSelectionDocument.Empty, loaded);
    }

    [Fact]
    public async Task Store_MigratesVersion1ToAllowAllWhilePreservingBlockedScenes()
    {
        Directory.CreateDirectory(_directory);
        var path = Path.Combine(_directory, "library-selections.json");
        await File.WriteAllTextAsync(path, """
            {
              "schemaVersion": 1,
              "libraryRoot": "C:/Scenes",
              "columns": 5,
              "rows": 8,
              "enabledGames": ["Attack from Mars"],
              "scenes": [
                {
                  "id": "ID1",
                  "lastRelativePath": "afm01.scn",
                  "sha256": "HASH",
                  "state": "allowed"
                },
                {
                  "id": "ID2",
                  "lastRelativePath": "afm02.scn",
                  "sha256": "HASH2",
                  "state": "disallowed"
                }
              ]
            }
            """);

        var loaded = await new AnimationSelectionStore().LoadAsync(path);
        var allowed = Catalog("ID1", "afm01.scn", "HASH", "Attack from Mars");
        var blocked = Catalog("ID2", "afm02.scn", "HASH2", "Attack from Mars");
        var newlyAllowed = Catalog("ID3", "afm03.scn", "HASH3", "Other Game");

        Assert.Equal(AnimationSelectionDocument.CurrentSchemaVersion, loaded.SchemaVersion);
        Assert.True(loaded.DefaultGamesEnabled);
        Assert.Equal(AnimationSelectionState.Allowed, loaded.DefaultSceneState);
        Assert.True(AnimationSelectionResolver.IsGameEnabled(loaded, "Attack from Mars"));
        Assert.True(AnimationSelectionResolver.IsGameEnabled(loaded, "Other Game"));
        Assert.Equal(AnimationSelectionState.Allowed,
            AnimationSelectionResolver.ResolveState(allowed, loaded));
        Assert.Equal(AnimationSelectionState.Disallowed,
            AnimationSelectionResolver.ResolveState(blocked, loaded));
        Assert.Equal(AnimationSelectionState.Allowed,
            AnimationSelectionResolver.ResolveState(newlyAllowed, loaded));
    }

    private static AnimationCatalogItem Catalog(
        string id,
        string path,
        string hash,
        string game) =>
        new(
            new AnimationLibraryItem(
                id, path, 1, DateTimeOffset.UnixEpoch, hash, 1, 100, null, []),
            new ResolvedSceneMetadata(
                path, Path.GetFileName(path), game, null, game, null, null, null, null, null, null));

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
        GC.SuppressFinalize(this);
    }
}
