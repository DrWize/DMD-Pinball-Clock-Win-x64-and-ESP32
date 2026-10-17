namespace DmdClock.Core.Playback;

public sealed record PlaybackDiagnostics(
    int FrameIndex, int TotalFrames, int StepIndex, int TotalSteps, bool IsBlank,
    bool Paused, bool Completed, double Speed, bool TimingNotSet, double FrameDelayMs,
    double? FileFps, double AdjustedTargetFps, double? MeasuredFrameUpdatesPerSecond,
    int SkippedFrames, double ExpectedDurationMs, double AdjustedDurationMs,
    double ElapsedMs, double? ActualDurationMs, string Status,
    double? SampleStartActiveMs, double? SampleEndActiveMs, bool TimingAdjusted = false)
{
    public string TimingSource => TimingNotSet ? "fallback" : TimingAdjusted ? "override" : "file";
    public string TimingLabel => TimingNotSet ? "Timing not set" : TimingAdjusted ? "10 ms played at 100 ms" : "From file";
    public double? FallbackFps => TimingNotSet ? 1000d / ScenePlaybackSession.DefaultFrameDelayMs : null;
    public double AdjustedFrameDelayMs => FrameDelayMs / Speed;
}
