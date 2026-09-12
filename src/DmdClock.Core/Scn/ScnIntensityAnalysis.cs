namespace DmdClock.Core.Scn;

public sealed record ScnIntensityAnalysis(
    int FrameCount,
    IReadOnlyList<int> UsedValues,
    int NonzeroLevelCount,
    IReadOnlyList<long> Histogram);
