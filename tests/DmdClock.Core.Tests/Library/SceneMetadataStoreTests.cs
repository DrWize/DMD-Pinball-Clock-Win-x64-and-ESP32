using System.Text.Json;
using DmdClock.Core.Library;

namespace DmdClock.Core.Tests.Library;

public sealed class SceneMetadataStoreTests
{
    [Fact]
    public async Task LoadAndResolve_UsesExactOverrideThenLongestPrefix()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"dmdclock-metadata-{Guid.NewGuid():N}");
        var path = Path.Combine(directory, SceneMetadataStore.DefaultFileName);
        Directory.CreateDirectory(directory);
        try
        {
            await File.WriteAllTextAsync(path, """
                {
                  "schemaVersion": 1,
                  "prefixes": [
                    { "prefix": "g", "game": "Generic" },
                    { "prefix": "got", "game": "Game of Thrones", "manufacturer": "Stern", "year": 2015,
                      "dateManufactured": "2015", "players": 4, "machineType": "SS", "theme": "Licensed Theme" }
                  ],
                  "files": [
                    { "path": "special/got01.scn", "title": "Opening", "game": "Override Game" }
                  ]
                }
                """);

            var catalog = await new SceneMetadataStore().LoadAsync(path);
            var exact = catalog.Resolve("special\\got01.scn");
            var prefix = catalog.Resolve("got02.scn");
            var unknown = catalog.Resolve("RD0001.scn");

            Assert.Equal("Opening", exact.DisplayName);
            Assert.Equal("Override Game", exact.Game);
            Assert.Equal("Stern", exact.Manufacturer);
            Assert.Equal(2015, exact.Year);
            Assert.Equal(4, exact.Players);
            Assert.Equal("SS", exact.MachineType);
            Assert.Equal("Licensed Theme", exact.Theme);
            Assert.Equal("Game of Thrones — got02", prefix.DisplayName);
            Assert.Equal("RD0001", unknown.DisplayName);
            Assert.Null(unknown.Game);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task Load_RejectsUnknownSchema()
    {
        var path = Path.GetTempFileName();
        try
        {
            await File.WriteAllTextAsync(path, """{"schemaVersion":99,"prefixes":[],"files":[]}""");
            await Assert.ThrowsAsync<JsonException>(() => new SceneMetadataStore().LoadAsync(path));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void Resolve_OnlyReturnsMatchingVerifiedIntensity()
    {
        var raw = new DmdClock.Core.Scn.ScnIntensityAnalysis(2, [0, 3, 15], 2, [4L, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]);
        var intensity = new SceneIntensityMetadata("ABC", 2, [0, 3, 15], "evenly-spaced-v1", [0, 128, 255]);
        var catalog = new SceneMetadataCatalog(files: [new SceneFileMetadata("test.scn", Intensity: intensity)]);

        var verified = catalog.Resolve("test.scn", "abc", raw);
        var stale = catalog.Resolve("test.scn", "def", raw);

        Assert.True(verified.IntensityMetadataVerified);
        Assert.Same(intensity, verified.Intensity);
        Assert.False(stale.IntensityMetadataVerified);
        Assert.Null(stale.Intensity);
    }
}
