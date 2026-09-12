namespace DmdClock.Core.Library;

public sealed record SceneIntensityMetadata(
    string Sha256,
    int FrameCount,
    IReadOnlyList<int> UsedValues,
    string Mapping,
    IReadOnlyList<int> OutputValues);
