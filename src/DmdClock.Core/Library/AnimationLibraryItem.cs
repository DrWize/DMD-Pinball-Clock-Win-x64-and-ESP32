namespace DmdClock.Core.Library;

public sealed record AnimationLibraryItem(
    string Id,
    string RelativePath,
    long FileSize,
    DateTimeOffset LastWriteUtc,
    string Sha256,
    int FrameCount,
    long EstimatedDurationMs,
    string? Error,
    IReadOnlyList<DmdClock.Core.Scn.ScnDiagnostic>? Warnings = null,
    DmdClock.Core.Scn.ScnIntensityAnalysis? Intensity = null)
{
    public bool IsValid => Error is null;
}
