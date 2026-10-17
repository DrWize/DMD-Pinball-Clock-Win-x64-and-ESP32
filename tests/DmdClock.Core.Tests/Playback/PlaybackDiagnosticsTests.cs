using DmdClock.Core.Playback;
using DmdClock.Core.Scn;

namespace DmdClock.Core.Tests.Playback;

public sealed class PlaybackDiagnosticsTests
{
    private static readonly DateTimeOffset Start = DateTimeOffset.UnixEpoch;
    private static ScnScene Scene(ushort delay = 100, ushort first = 0, ushort last = 0, bool blank = false) =>
        new(1, [new(first, false, blank, delay, false, last, false, blank, 0, 0, 0)],
            Enumerable.Range(0, 3).Select(_ => new DmdFrame(128, 32, new byte[4096])).ToArray());

    [Fact]
    public void DurationMatchesPlaybackStepsIncludingBlankHolds()
    {
        var normal = new ScenePlaybackSession(Scene(first: 50, last: 75), Start);
        Assert.Equal(325, normal.ExpectedDurationMs);
        var blank = new ScenePlaybackSession(Scene(first: 50, last: 75, blank: true), Start);
        Assert.Equal(425, blank.ExpectedDurationMs);
        foreach (var time in new[] { 50, 150, 250, 350 })
            Assert.True(blank.Advance(Start.AddMilliseconds(time)));
        Assert.False(blank.Advance(Start.AddMilliseconds(425)));
        Assert.True(blank.IsComplete);
    }

    [Fact]
    public void MissingOrZeroTimingUsesExplicitFallback()
    {
        var scene = Scene(0);
        foreach (var value in new[] { scene, new ScnScene(1, [], scene.Frames) })
        {
            var d = new ScenePlaybackSession(value, Start).GetDiagnostics(Start);
            Assert.True(d.TimingNotSet);
            Assert.Null(d.FileFps);
            Assert.Equal(10, d.AdjustedTargetFps);
            Assert.Equal(10, d.FallbackFps);
            Assert.Equal(100, d.FrameDelayMs);
            Assert.Equal(300, d.ExpectedDurationMs);
        }
    }

    [Theory]
    [InlineData(.1, 3000)]
    [InlineData(.5, 600)]
    [InlineData(1, 300)]
    [InlineData(4, 75)]
    public void SpeedScalesWholeScene(double speed, double duration)
    {
        var session = new ScenePlaybackSession(Scene(), Start);
        session.SetSpeed(speed, Start);
        session.Restart(Start);
        Assert.Equal(duration, session.AdjustedDurationMs);
        session.Advance(Start.AddMilliseconds(duration / 3));
        session.Advance(Start.AddMilliseconds(duration * 2 / 3));
        session.Advance(Start.AddMilliseconds(duration - 1));
        Assert.False(session.IsComplete);
        session.Advance(Start.AddMilliseconds(duration));
        Assert.True(session.IsComplete);
        var d = session.GetDiagnostics(Start.AddDays(1));
        Assert.Equal(duration, d.ActualDurationMs);
        Assert.Equal("Completed", d.Status);
    }

    [Fact]
    public void SpeedChangePreservesRemainingProportionWhilePaused()
    {
        var session = new ScenePlaybackSession(Scene(), Start);
        session.Pause(Start.AddMilliseconds(25));
        session.SetSpeed(.5, Start.AddSeconds(1));
        session.Resume(Start.AddSeconds(2));
        Assert.False(session.Advance(Start.AddMilliseconds(2149)));
        Assert.True(session.Advance(Start.AddMilliseconds(2150)));
        var d = session.GetDiagnostics(Start.AddMilliseconds(2150));
        Assert.Equal(175, d.ElapsedMs);
        Assert.Equal("Speed changed", d.Status);
    }

    [Fact]
    public void SpeedChangePreservesRemainingProportionWhilePlaying()
    {
        var session = new ScenePlaybackSession(Scene(), Start);
        session.SetSpeed(2, Start.AddMilliseconds(50));
        Assert.False(session.Advance(Start.AddMilliseconds(74)));
        Assert.True(session.Advance(Start.AddMilliseconds(75)));
    }

    [Fact]
    public void LateCallbacksPreserveEveryStepAndMeasureApplicationUpdates()
    {
        var scene = Scene(10);
        scene = scene with { Frames = Enumerable.Range(0, 200).Select(_ => scene.Frames[0]).ToArray() };
        var session = new ScenePlaybackSession(scene, Start);
        for (var time = 200; time <= 1000; time += 200) session.Advance(Start.AddMilliseconds(time));
        var d = session.GetDiagnostics(Start.AddMilliseconds(1000));
        Assert.Equal(5, d.MeasuredFrameUpdatesPerSecond);
        Assert.Equal(0, d.SkippedFrames);
        Assert.Equal(5, d.StepIndex);
        Assert.Equal(0, d.SampleStartActiveMs);
        Assert.Equal(1000, d.SampleEndActiveMs);
    }

    [Fact]
    public void TenMillisecondOverridePreservesFileTimingAndSpecialHolds()
    {
        var session = new ScenePlaybackSession(Scene(10, first: 10, last: 10, blank: true), Start);
        var initial = session.GetDiagnostics(Start);
        Assert.Equal(10, session.Storyboard.FrameDelayMs);
        Assert.Equal(100, initial.FileFps);
        Assert.Equal(10, initial.AdjustedTargetFps);
        Assert.True(initial.TimingAdjusted);
        Assert.Equal("override", initial.TimingSource);
        Assert.Equal(320, initial.ExpectedDurationMs);
        Assert.Equal(10, initial.FrameDelayMs);
        Assert.True(session.Advance(Start.AddMilliseconds(10)));
        Assert.Equal(100, session.CurrentFrameDelayMs);
        session.SetSpeed(2, Start.AddMilliseconds(10));
        var scaled = session.GetDiagnostics(Start.AddMilliseconds(10));
        Assert.Equal(20, scaled.AdjustedTargetFps);
        Assert.Equal(50, scaled.AdjustedFrameDelayMs);
    }

    [Theory]
    [InlineData(9)]
    [InlineData(11)]
    [InlineData(80)]
    [InlineData(90)]
    [InlineData(100)]
    public void OtherExplicitRegularDelaysRemainUnchanged(ushort delay)
    {
        var d = new ScenePlaybackSession(Scene(delay), Start).GetDiagnostics(Start);
        Assert.Equal(delay, d.FrameDelayMs);
        Assert.Equal(3 * delay, d.ExpectedDurationMs);
        Assert.False(d.TimingAdjusted);
        Assert.Equal("file", d.TimingSource);
    }

    [Fact]
    public void ManualStepsStayAtBoundariesAndQualifyDuration()
    {
        var session = new ScenePlaybackSession(Scene(), Start);
        session.Pause(Start);
        session.MovePrevious(Start);
        Assert.Equal(0, session.CurrentFrameIndex);
        for (var i = 0; i < 10; i++) session.MoveNext(Start);
        Assert.Equal(2, session.CurrentFrameIndex);
        Assert.False(session.IsComplete);
        var d = session.GetDiagnostics(Start.AddHours(1));
        Assert.Equal(0, d.ElapsedMs);
        Assert.Null(d.MeasuredFrameUpdatesPerSecond);
        Assert.Equal("Manually stepped", d.Status);
    }

    [Fact]
    public void LongHoldReportsZeroUpdatesAndCompletedTimeDoesNotGrow()
    {
        var session = new ScenePlaybackSession(Scene(first: 3000), Start);
        session.Advance(Start.AddSeconds(1));
        Assert.Equal(0, session.GetDiagnostics(Start.AddSeconds(1)).MeasuredFrameUpdatesPerSecond);
        Assert.True(session.Advance(Start.AddMilliseconds(3000)));
        Assert.True(session.Advance(Start.AddMilliseconds(3100)));
        session.Advance(Start.AddMilliseconds(3200));
        Assert.True(session.IsComplete);
        Assert.Equal(3200, session.GetDiagnostics(Start.AddHours(1)).ActualDurationMs);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(4.1)]
    [InlineData(.15)]
    [InlineData(double.NaN)]
    public void RejectsInvalidSpeeds(double speed) =>
        Assert.Throws<ArgumentOutOfRangeException>(() => new ScenePlaybackSession(Scene(), Start).SetSpeed(speed, Start));
}
