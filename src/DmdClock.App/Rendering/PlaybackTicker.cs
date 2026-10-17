using Avalonia.Threading;

namespace DmdClock.App.Rendering;

// Use a timer-queue wakeup rather than the window-message timer used for the
// idle clock. Coalesce callbacks so a busy UI never accumulates catch-up work.
internal sealed class PlaybackTicker : IDisposable
{
    private readonly Action _tick;
    private readonly Timer _timer;
    private readonly PlaybackTimerResolution _resolution = new();
    private int _pending;
    private volatile bool _disposed;
    public bool IsActive { get; private set; }

    public PlaybackTicker(Action tick)
    {
        _tick = tick;
        _timer = new Timer(_ => QueueTick(), null, Timeout.Infinite, Timeout.Infinite);
    }

    public void SetActive(bool active)
    {
        if (_disposed || IsActive == active) return;
        IsActive = active;
        _resolution.SetActive(active);
        _timer.Change(active ? 1 : Timeout.Infinite, active ? 1 : Timeout.Infinite);
    }

    private void QueueTick()
    {
        if (_disposed || Interlocked.Exchange(ref _pending, 1) != 0) return;
        Dispatcher.UIThread.Post(() =>
        {
            try
            {
                if (!_disposed && IsActive) _tick();
            }
            finally { Volatile.Write(ref _pending, 0); }
        });
    }

    public void Dispose()
    {
        if (_disposed) return;
        SetActive(false);
        _disposed = true;
        _timer.Dispose();
        _resolution.Dispose();
    }
}
