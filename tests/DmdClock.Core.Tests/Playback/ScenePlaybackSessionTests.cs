using DmdClock.Core.Playback;
using DmdClock.Core.Scn;

namespace DmdClock.Core.Tests.Playback;

public sealed class ScenePlaybackSessionTests
{
    [Fact]
    public void FrameHoldStartsAfterSubmissionAndIncludesFinalFrame()
    {
        var frame = new DmdFrame(128, 32, new byte[4096]);
        var session = new ScenePlaybackSession(new ScnScene(1, [], [frame, frame]), DateTimeOffset.UnixEpoch);
        var start = DateTimeOffset.UnixEpoch;
        session.NotifyFrameSubmitted(start.AddMilliseconds(7));
        Assert.False(session.Advance(start.AddMilliseconds(106)));
        Assert.True(session.Advance(start.AddMilliseconds(107)));
        session.NotifyFrameSubmitted(start.AddMilliseconds(111));
        Assert.False(session.Advance(start.AddMilliseconds(210)));
        Assert.False(session.IsComplete);
        Assert.False(session.Advance(start.AddMilliseconds(211)));
        Assert.True(session.IsComplete);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(10)]
    [InlineData(25)]
    public void LateCallbackDoesNotSkipOrShortenTheNextFrame(int delay)
    {
        var frame = new DmdFrame(128, 32, new byte[4096]);
        var scene = new ScnScene(1, [new ScnStoryboard(0, false, false, (ushort)delay, false, 0, false, false, 0, 0, 0)],
            [frame, frame, frame]);
        AssertEveryFrameGetsItsDwell(scene, delay is 0 or 10 ? 100 : delay);
    }

    [Fact]
    public void MissingStoryboardUsesOneHundredMillisecondsWithoutSkipping()
    {
        var frame = new DmdFrame(128, 32, new byte[4096]);
        AssertEveryFrameGetsItsDwell(new ScnScene(1, [], [frame, frame, frame]), 100);
    }

    private static void AssertEveryFrameGetsItsDwell(ScnScene scene, int delay)
    {
        var start = DateTimeOffset.UnixEpoch;
        var session = new ScenePlaybackSession(scene, start);
        Assert.False(session.Advance(start.AddMilliseconds(delay - 1)));
        // A one-second stall must advance by exactly one frame, even if the
        // entire file timeline would already have elapsed under catch-up.
        var late = start.AddSeconds(1);
        Assert.True(session.Advance(late));
        Assert.Equal(1, session.CurrentFrameIndex);
        Assert.False(session.Advance(late));
        Assert.False(session.Advance(late.AddMilliseconds(delay - 1)));
        Assert.True(session.Advance(late.AddMilliseconds(delay)));
        Assert.Equal(2, session.CurrentFrameIndex);
        Assert.False(session.IsComplete);
        Assert.False(session.Advance(late.AddMilliseconds(2 * delay - 1)));
        Assert.False(session.Advance(late.AddMilliseconds(2 * delay)));
        Assert.True(session.IsComplete);
        Assert.Equal(0, session.GetDiagnostics(late.AddMilliseconds(2 * delay)).SkippedFrames);
    }

    [Fact]
    public void Advance_UsesFrameTimingAndCompletes()
    {
        using var data = TestScnFile.Create(frameCount: 3, frameDelayMs: 100);
        var scene = ScnReader.Read(data);
        var start = DateTimeOffset.UnixEpoch;
        var session = new ScenePlaybackSession(scene, start);

        Assert.False(session.Advance(start.AddMilliseconds(9)));
        Assert.True(session.Advance(start.AddMilliseconds(10)));
        Assert.Equal(1, session.CurrentFrameIndex);
        Assert.False(session.Advance(start.AddMilliseconds(109)));
        Assert.True(session.Advance(start.AddMilliseconds(110)));
        Assert.Equal(2, session.CurrentFrameIndex);
        Assert.True(session.Advance(start.AddMilliseconds(210)));
        Assert.Equal(2, session.CurrentFrameIndex);
        Assert.False(session.IsComplete);
        Assert.False(session.Advance(start.AddMilliseconds(230)));
        Assert.True(session.IsComplete);
    }

    [Fact]
    public void Pause_PreservesRemainingFrameTime()
    {
        using var data = TestScnFile.Create(frameCount: 2, frameDelayMs: 100);
        var session = new ScenePlaybackSession(ScnReader.Read(data), DateTimeOffset.UnixEpoch);

        session.Pause(DateTimeOffset.UnixEpoch.AddMilliseconds(5));
        Assert.False(session.Advance(DateTimeOffset.UnixEpoch.AddSeconds(5)));
        session.Resume(DateTimeOffset.UnixEpoch.AddSeconds(5));

        Assert.False(session.Advance(DateTimeOffset.UnixEpoch.AddSeconds(5).AddMilliseconds(4)));
        Assert.True(session.Advance(DateTimeOffset.UnixEpoch.AddSeconds(5).AddMilliseconds(5)));
    }

    [Fact]
    public void Constructor_CreatesBlankFirstAndLastSpecialSteps()
    {
        var frame = new DmdFrame(128, 32, Enumerable.Repeat((byte)5, 128 * 32).ToArray());
        var storyboard = new ScnStoryboard(50, false, true, 100, false, 75, true, true, 0, 0, 0);
        var scene = new ScnScene(1, [storyboard], [frame]);
        var start = DateTimeOffset.UnixEpoch;
        var session = new ScenePlaybackSession(scene, start);

        Assert.True(session.IsBlank);
        Assert.Equal(-1, session.CurrentFrameIndex);
        Assert.True(session.Advance(start.AddMilliseconds(50)));
        Assert.False(session.IsBlank);
        Assert.True(session.Advance(start.AddMilliseconds(150)));
        Assert.True(session.IsBlank);
        Assert.True(session.ClockAbove);
    }
}
