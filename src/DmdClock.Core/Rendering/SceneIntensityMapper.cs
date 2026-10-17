using DmdClock.Core.Library;
using DmdClock.Core.Scn;

namespace DmdClock.Core.Rendering;

public static class SceneIntensityMapper
{
    public static ScnScene Apply(ScnScene scene, ResolvedSceneMetadata metadata)
    {
        var lookup = CreateLookup(metadata);
        return lookup is null ? scene : scene with
        {
            Frames = scene.Frames.Select(frame => Apply(frame, lookup)).ToArray()
        };
    }

    public static DmdFrame Apply(DmdFrame frame, ResolvedSceneMetadata metadata)
    {
        var lookup = CreateLookup(metadata);
        return lookup is null ? frame : Apply(frame, lookup);
    }

    private static byte[]? CreateLookup(ResolvedSceneMetadata metadata)
    {
        if (!metadata.IntensityMetadataVerified || metadata.Intensity is not { } intensity)
            return null;

        var lookup = Enumerable.Range(0, 16).Select(value => (byte)value).ToArray();
        for (var index = 0; index < intensity.UsedValues.Count; index++)
            lookup[intensity.UsedValues[index]] = (byte)((intensity.OutputValues[index] * 15 + 127) / 255);
        return lookup;
    }

    private static DmdFrame Apply(DmdFrame frame, byte[] lookup)
    {
        var pixels = frame.Intensities.ToArray();
        for (var index = 0; index < pixels.Length; index++) pixels[index] = lookup[pixels[index]];
        return new DmdFrame(frame.Width, frame.Height, pixels, frame.Mask?.ToArray());
    }
}
