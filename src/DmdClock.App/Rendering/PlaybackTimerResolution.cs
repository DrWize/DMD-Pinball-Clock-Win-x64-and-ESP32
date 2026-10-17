using System.Runtime.InteropServices;

namespace DmdClock.App.Rendering;

// UI-thread owned. Pair the Windows request exactly once with its release;
// never retain the high-frequency request during idle or paused playback.
internal sealed class PlaybackTimerResolution : IDisposable
{
    private bool _requested;
    private bool _acquired;

    public void SetActive(bool active)
    {
        if (_requested == active) return;
        _requested = active;
        if (!OperatingSystem.IsWindows()) return;
        if (active)
            _acquired = TimeBeginPeriod(1) == 0;
        else if (_acquired)
        {
            TimeEndPeriod(1);
            _acquired = false;
        }
    }

    public void Dispose() => SetActive(false);

    [DllImport("winmm.dll", EntryPoint = "timeBeginPeriod", ExactSpelling = true)]
    private static extern uint TimeBeginPeriod(uint period);

    [DllImport("winmm.dll", EntryPoint = "timeEndPeriod", ExactSpelling = true)]
    private static extern uint TimeEndPeriod(uint period);
}
