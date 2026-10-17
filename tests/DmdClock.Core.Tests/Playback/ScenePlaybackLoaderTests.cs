using System.Security.Cryptography;
using DmdClock.Core.Library;
using DmdClock.Core.Playback;
using DmdClock.Core.Rendering;
using DmdClock.Core.Scn;

namespace DmdClock.Core.Tests.Playback;

public sealed class ScenePlaybackLoaderTests
{
    [Fact]
    public void MapsLastActionHeroAndPreservesSourceAndTiming()
    {
        var data = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "TestData", "LAST_ACTION_HERO_010.scn"));
        var original = data.ToArray();
        var intensity = new SceneIntensityMetadata(
            "d0bd0aad828ecb1a403018af6962b0fe7a7cfc100825b20dd8b3eba3bb75a78c",
            2, [0, 10, 15], "evenly-spaced-v1", [0, 128, 255]);
        var (mapped, metadata) = ScenePlaybackLoader.Read(data, Catalog(intensity), "test.scn");
        using var stream = new MemoryStream(data);
        var raw = ScnReader.Read(stream);

        Assert.True(metadata.IntensityMetadataVerified);
        Assert.Equal(new byte[] { 0, 8, 15 }, mapped.Frames.SelectMany(frame => frame.Intensities.ToArray()).Distinct().Order().ToArray());
        for (var index = 0; index < raw.Frames.Count; index++)
        {
            Assert.Equal(raw.Frames[index].Intensities.ToArray().Select(value => value == 10 ? (byte)8 : value),
                mapped.Frames[index].Intensities.ToArray());
            Assert.Equal(raw.Frames[index].Mask?.ToArray(), mapped.Frames[index].Mask?.ToArray());
        }
        Assert.Equal(original, data);
        Assert.Equal(raw.Storyboards, mapped.Storyboards);
        Assert.Equal(new ScenePlaybackSession(raw, DateTimeOffset.UnixEpoch).ExpectedDurationMs,
            new ScenePlaybackSession(mapped, DateTimeOffset.UnixEpoch).ExpectedDurationMs);
    }

    [Theory]
    [InlineData("missing")]
    [InlineData("hash")]
    [InlineData("count")]
    [InlineData("values")]
    [InlineData("mapping")]
    [InlineData("outputs")]
    [InlineData("null-values")]
    [InlineData("null-outputs")]
    [InlineData("black")]
    public void UnverifiedMetadataFallsBackToRawPlayback(string fault)
    {
        using var stream = TestScnFile.Create(includeMask: true);
        var data = stream.ToArray();
        var intensity = new SceneIntensityMetadata(Convert.ToHexString(SHA256.HashData(data)),
            1, [0, 1, 10], "evenly-spaced-v1", [0, 128, 255]);
        intensity = fault switch
        {
            "hash" => intensity with { Sha256 = new string('0', 64) },
            "count" => intensity with { FrameCount = 2 },
            "values" => intensity with { UsedValues = [0, 2, 10] },
            "mapping" => intensity with { Mapping = "unknown" },
            "outputs" => intensity with { OutputValues = [0, 128] },
            "null-values" => intensity with { UsedValues = null! },
            "null-outputs" => intensity with { OutputValues = null! },
            "black" => intensity with { OutputValues = [1, 128, 255] },
            _ => intensity
        };
        var catalog = fault == "missing" ? SceneMetadataCatalog.Empty : Catalog(intensity);
        var (scene, metadata) = ScenePlaybackLoader.Read(data, catalog, "test.scn");
        Assert.False(metadata.IntensityMetadataVerified);
        Assert.Equal(new byte[] { 1, 10, 0 }, scene.Frames[0].Intensities.Span[..3].ToArray());
        Assert.True(scene.Frames[0].IsMasked(0, 0));
    }

    [Fact]
    public void WholeSceneMappingKeepsSubsetFramesStableAndClockUnchanged()
    {
        var intensity = new SceneIntensityMetadata("abc", 2, [0, 10, 15], "evenly-spaced-v1", [0, 128, 255]);
        var metadata = Catalog(intensity).Resolve("test.scn", "abc", new ScnIntensityAnalysis(2, [0, 10, 15], 2, []));
        var first = new DmdFrame(2, 1, [0, 10], [1, 0]);
        var second = new DmdFrame(2, 1, [10, 15]);
        var raw = new ScnScene(1, [], [first, second]);
        var mapped = SceneIntensityMapper.Apply(raw, metadata);

        Assert.Equal(new byte[] { 0, 8 }, mapped.Frames[0].Intensities.ToArray());
        Assert.Equal(new byte[] { 8, 15 }, mapped.Frames[1].Intensities.ToArray());
        var clock = new DmdFrame(2, 1, [10, 0], [0, 1]);
        Assert.Equal(new byte[] { 10, 8 }, DmdFrameCompositor.Compose(mapped.Frames[0], clock, true).Intensities.ToArray());
        Assert.Equal(new byte[] { 0, 10 }, first.Intensities.ToArray());
        Assert.Equal(new byte[] { 1, 0 }, mapped.Frames[0].Mask!.Value.ToArray());
    }

    private static SceneMetadataCatalog Catalog(SceneIntensityMetadata intensity) =>
        new(files: [new SceneFileMetadata("test.scn", Intensity: intensity)]);
}
