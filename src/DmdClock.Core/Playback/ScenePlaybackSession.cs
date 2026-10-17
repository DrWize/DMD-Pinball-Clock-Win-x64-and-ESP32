using DmdClock.Core.Rendering;
using DmdClock.Core.Scn;

namespace DmdClock.Core.Playback;

public sealed class ScenePlaybackSession
{
    public const ushort DefaultFrameDelayMs = 100;
    private readonly IReadOnlyList<PlaybackStep> _steps;
    private int _stepIndex;
    private DateTimeOffset _nextFrameAt;
    private TimeSpan _remainingWhenPaused;
    private DateTimeOffset _observedAt;
    private double _elapsedMs;
    private double _sampleStartMs;
    private int _sampleUpdates;
    private double? _measuredFps;
    private int _skippedFrames;
    private bool _manuallyStepped;
    private bool _speedChanged;
    public double Speed { get; private set; } = 1;
    public bool TimingNotSet => Scene.Storyboards.Count == 0 || Storyboard.FrameDelayMs == 0;
    public double ExpectedDurationMs { get; }
    public double AdjustedDurationMs => ExpectedDurationMs / Speed;
    public double CurrentFrameDelayMs => _steps[_stepIndex].Duration.TotalMilliseconds;

    public PlaybackDiagnostics GetDiagnostics(DateTimeOffset now)
    {
        Observe(now);
        return new(CurrentFrameIndex, Scene.Frames.Count, _stepIndex, _steps.Count, IsBlank,
            IsPaused, IsComplete, Speed, TimingNotSet, CurrentFrameDelayMs,
            TimingNotSet ? null : 1000d / Storyboard.FrameDelayMs,
            1000d / RegularFrameDelayMs(Storyboard.FrameDelayMs) * Speed,
            _measuredFps, _skippedFrames, ExpectedDurationMs, AdjustedDurationMs, _elapsedMs,
            IsComplete ? _elapsedMs : null, _manuallyStepped ? "Manually stepped" :
            _speedChanged ? "Speed changed" : IsComplete ? "Completed" : IsPaused ? "Paused" : "Playing",
            _lastSampleStart, _lastSampleEnd, !TimingNotSet && Storyboard.FrameDelayMs == 10);
    }

    private void Observe(DateTimeOffset now)
    {
        if (now < _observedAt) throw new ArgumentOutOfRangeException(nameof(now), "Playback time must be monotonic.");
        if (!IsPaused && !IsComplete) _elapsedMs += (now - _observedAt).TotalMilliseconds;
        _observedAt = now;
    }

    public void SetSpeed(double speed, DateTimeOffset now)
    {
        if (!double.IsFinite(speed) || speed < .1 || speed > 4 || Math.Abs(speed * 10 - Math.Round(speed * 10)) > .000001)
            throw new ArgumentOutOfRangeException(nameof(speed), "Speed must be 0.1–4.0 in 0.1 steps.");
        Observe(now);
        if (speed == Speed) return;
        var remaining = IsPaused ? _remainingWhenPaused : (_nextFrameAt > now ? _nextFrameAt - now : TimeSpan.Zero);
        _remainingWhenPaused = TimeSpan.FromTicks((long)(remaining.Ticks * Speed / speed));
        Speed = speed;
        _nextFrameAt = now + _remainingWhenPaused;
        _speedChanged = true;
        ResetSample();
    }

    private void ResetSample()
    {
        _sampleStartMs = _elapsedMs;
        _sampleUpdates = 0;
        _measuredFps = null;
        _lastSampleStart = null;
        _lastSampleEnd = null;
    }

    public ScenePlaybackSession(ScnScene scene, DateTimeOffset startedAt)
    {
        ArgumentNullException.ThrowIfNull(scene);
        if (scene.Frames.Count == 0)
            throw new ArgumentException("A scene must contain at least one frame.", nameof(scene));

        Scene = scene;
        Storyboard = scene.Storyboards.FirstOrDefault() ??
            new ScnStoryboard(0, false, false, 0, false, 0, false, false, 0, 0, 0);
        _steps = CreateSteps(scene, Storyboard);
        ExpectedDurationMs = _steps.Sum(step => step.Duration.TotalMilliseconds);
        Restart(startedAt);
    }

    public ScnScene Scene { get; }
    public ScnStoryboard Storyboard { get; }
    public int CurrentFrameIndex => _steps[_stepIndex].FrameIndex;
    public DmdFrame CurrentFrame => _steps[_stepIndex].Frame;
    public bool ClockAbove => _steps[_stepIndex].ClockAbove;
    public bool IsBlank => _steps[_stepIndex].IsBlank;
    public bool IsPaused { get; private set; }
    public bool IsComplete { get; private set; }

    public void NotifyFrameSubmitted(DateTimeOffset now)
    {
        Observe(now);
        // Frame composition/submission takes time too. Start the full hold
        // after that work, not before it.
        if (!IsPaused && !IsComplete) ResetDeadline(now);
    }

    public bool Advance(DateTimeOffset now)
    {
        Observe(now);
        if (IsPaused || IsComplete) return false;
        if (now < _nextFrameAt) { UpdateRate(); return false; }
        if (_stepIndex >= _steps.Count - 1)
        {
            IsComplete = true;
            UpdateRate();
            return false;
        }

        // Present every step. A late callback must not consume the next frame's
        // dwell time or jump over intermediate frames to regain wall-clock time.
        _stepIndex++;
        ResetDeadline(now);
        _sampleUpdates++;
        UpdateRate();
        return true;
    }

    private void UpdateRate()
    {
        var interval = _elapsedMs - _sampleStartMs;
        if (interval < 1000) return;
        _measuredFps = _sampleUpdates * 1000d / interval;
        _lastSampleStart = _sampleStartMs;
        _lastSampleEnd = _elapsedMs;
        _sampleStartMs = _elapsedMs;
        _sampleUpdates = 0;
    }

    private double? _lastSampleStart;
    private double? _lastSampleEnd;

    public void Pause(DateTimeOffset now)
    {
        Observe(now);
        if (IsPaused || IsComplete) return;
        ResetSample();
        _remainingWhenPaused = _nextFrameAt > now ? _nextFrameAt - now : TimeSpan.Zero;
        IsPaused = true;
    }

    public void Resume(DateTimeOffset now)
    {
        Observe(now);
        if (!IsPaused || IsComplete) return;
        ResetSample();
        _nextFrameAt = now + _remainingWhenPaused;
        IsPaused = false;
    }

    public void MoveNext(DateTimeOffset now)
    {
        Observe(now);
        _manuallyStepped = true;
        ResetSample();
        if (_stepIndex < _steps.Count - 1) _stepIndex++;
        IsComplete = false;
        ResetDeadline(now);
    }

    public void MovePrevious(DateTimeOffset now)
    {
        Observe(now);
        _manuallyStepped = true;
        ResetSample();
        if (_stepIndex > 0) _stepIndex--;
        IsComplete = false;
        ResetDeadline(now);
    }

    public void Restart(DateTimeOffset now)
    {
        _stepIndex = 0;
        _observedAt = now;
        _elapsedMs = 0;
        _skippedFrames = 0;
        _manuallyStepped = false;
        _speedChanged = false;
        ResetSample();
        IsPaused = false;
        IsComplete = false;
        ResetDeadline(now);
    }

    private void ResetDeadline(DateTimeOffset now)
    {
        _remainingWhenPaused = TimeSpan.FromTicks((long)(_steps[_stepIndex].Duration.Ticks / Speed));
        _nextFrameAt = now + _remainingWhenPaused;
    }

    private static IReadOnlyList<PlaybackStep> CreateSteps(ScnScene scene, ScnStoryboard storyboard)
    {
        var steps = new List<PlaybackStep>(scene.Frames.Count + 2);
        var regularDuration = TimeSpan.FromMilliseconds(RegularFrameDelayMs(storyboard.FrameDelayMs));
        var firstNormalFrame = 0;

        if (storyboard.FirstFrameDelayMs > 0)
        {
            var blank = storyboard.BlankFirstFrame;
            steps.Add(new PlaybackStep(
                blank ? DmdFrameCompositor.CreateBlank() : scene.Frames[0],
                blank ? -1 : 0,
                storyboard.ClockAboveFirstFrame,
                blank,
                Duration(storyboard.FirstFrameDelayMs)));
            if (!blank) firstNormalFrame = 1;
        }

        for (var index = firstNormalFrame; index < scene.Frames.Count; index++)
            steps.Add(new PlaybackStep(scene.Frames[index], index, storyboard.ClockAboveFrames, false, regularDuration));

        if (storyboard.LastFrameDelayMs > 0)
        {
            var blank = storyboard.BlankLastFrame;
            steps.Add(new PlaybackStep(
                blank ? DmdFrameCompositor.CreateBlank() : scene.Frames[^1],
                blank ? -1 : scene.Frames.Count - 1,
                storyboard.ClockAboveLastFrame,
                blank,
                Duration(storyboard.LastFrameDelayMs)));
        }

        return steps;
    }

    // User-approved Windows playback policy. Keep SCN values intact and do not
    // apply the regular-frame override to explicit first/last holds.
    private static ushort RegularFrameDelayMs(ushort milliseconds) =>
        milliseconds is 0 or 10 ? DefaultFrameDelayMs : milliseconds;

    private static TimeSpan Duration(ushort milliseconds) => TimeSpan.FromMilliseconds(milliseconds);

    private sealed record PlaybackStep(DmdFrame Frame, int FrameIndex, bool ClockAbove, bool IsBlank, TimeSpan Duration);
}

