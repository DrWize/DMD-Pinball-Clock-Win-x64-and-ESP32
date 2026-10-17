using System.Security.Cryptography;
using DmdClock.Core.Library;
using DmdClock.Core.Rendering;
using DmdClock.Core.Scn;

namespace DmdClock.Core.Playback;

public static class ScenePlaybackLoader
{
    public static (ScnScene Scene, ResolvedSceneMetadata Metadata) Read(
        string path, SceneMetadataCatalog catalog, string relativePath) =>
        Read(File.ReadAllBytes(path), catalog, relativePath);

    public static (ScnScene Scene, ResolvedSceneMetadata Metadata) Read(
        byte[] data, SceneMetadataCatalog catalog, string relativePath)
    {
        // Decode and verify the same bytes, rather than trusting an earlier library scan.
        using var stream = new MemoryStream(data, writable: false);
        var scene = ScnReader.Read(stream);
        stream.Position = 0;
        var analysis = ScnIntensityAnalyzer.Analyze(stream);
        var hash = Convert.ToHexString(SHA256.HashData(data));
        var metadata = catalog.Resolve(relativePath, hash, analysis);
        return (SceneIntensityMapper.Apply(scene, metadata), metadata);
    }
}
