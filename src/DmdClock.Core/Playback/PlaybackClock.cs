using System.Diagnostics;

namespace DmdClock.Core.Playback;

// Synthetic dates retain compatibility with deterministic session tests; no wall-clock adjustments.
public static class PlaybackClock
{
    private static readonly long Origin = Stopwatch.GetTimestamp();
    public static DateTimeOffset Now => DateTimeOffset.UnixEpoch + Stopwatch.GetElapsedTime(Origin);
}
