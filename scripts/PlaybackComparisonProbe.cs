// Standalone probe compiled against historical and current source by Compare-PlaybackVersions.py.
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using DmdClock.Core;
using DmdClock.Core.Playback;
using DmdClock.Core.Scn;

var manifest = JsonSerializer.Deserialize<List<SceneInput>>(File.ReadAllText(args[0]))!;
var deterministic = new List<RunResult>();
var wallCandidates = new List<(string Path, ScnScene Scene, long Expected)>();
var frames = Enumerable.Range(0, 5).Select(i => new DmdFrame(128, 32, Enumerable.Repeat((byte)i, 4096).ToArray())).ToArray();
var fixtures = new List<(string Name, ScnScene Scene)>
{
    ("regular", new(1, [Board(0, false, 100, 0, false)], frames)),
    ("zero-delay", new(1, [Board(0, false, 0, 0, false)], frames)),
    ("no-storyboard", new(1, [], frames)),
    ("first-last-holds", new(1, [Board(50, false, 100, 75, false)], frames)),
    ("blank-holds", new(1, [Board(50, true, 100, 75, true)], frames)),
    ("fast-frames", new(1, [Board(0, false, 5, 0, false)], frames)),
    ("single-frame", new(1, [Board(50, false, 100, 75, false)], [frames[0]])),
    ("multiple-storyboards", new(1, [Board(50, false, 100, 75, false), Board(0, false, 1, 0, false)], frames))
};
foreach (var fixture in fixtures)
    foreach (var cadence in new[] { 1, 16, 33, 250 })
        deterministic.Add(Run(fixture.Name, fixture.Scene, cadence));
foreach (var input in manifest)
{
    if (Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(input.path))).ToLowerInvariant() != input.sha256)
        throw new Exception($"Scene changed: {input.path}");
    ScnScene scene;
    try { scene = ScnReader.Read(input.path); }
    catch (ScnFormatException) { throw; }
    if (scene.Frames.Count == 0) throw new Exception($"Empty scene: {input.path}");
    var expected = Expected(scene);
    foreach (var cadence in new[] { 16, 250 })
        deterministic.Add(Run(input.path, scene, cadence));
    if (expected is >= 1000 and <= 2000 && scene.Frames.Count >= 5)
        wallCandidates.Add((input.path, scene, expected));
}
// Choose scenes with distinct delays where possible, using identical deterministic ordering in each snapshot.
var selected = wallCandidates.GroupBy(x => x.Scene.Storyboards.FirstOrDefault()?.FrameDelayMs ?? 0)
    .OrderBy(x => x.Key).Select(x => x.First()).Take(3).ToArray();
var wallClock = new List<object>();
foreach (var sample in selected)
{
    var sw = Stopwatch.StartNew();
    var clockProperty = typeof(ScenePlaybackSession).Assembly.GetType("DmdClock.Core.Playback.PlaybackClock")?.GetProperty("Now");
    DateTimeOffset Now() => clockProperty is null ? DateTimeOffset.UtcNow : (DateTimeOffset)clockProperty.GetValue(null)!;
    var start = Now();
    var session = new ScenePlaybackSession(sample.Scene, start);
    long nextTick = 16;
    int callbacks = 0, updates = 0, maxJump = 0;
    while (!session.IsComplete)
    {
        var wait = nextTick - sw.Elapsed.TotalMilliseconds;
        if (wait > 1) Thread.Sleep((int)wait);
        while (sw.Elapsed.TotalMilliseconds < nextTick) Thread.SpinWait(20);
        var before = session.CurrentFrameIndex;
        if (session.Advance(Now())) updates++;
        maxJump = Math.Max(maxJump, session.CurrentFrameIndex - before);
        callbacks++;
        nextTick += 16;
        if (sw.ElapsedMilliseconds > sample.Expected + 10000) throw new Exception("Wall-clock timeout");
    }
    wallClock.Add(new { path = sample.Path, expectedMs = sample.Expected, measuredMs = sw.Elapsed.TotalMilliseconds, callbacks, updates, maxJump });
}
var controlScene = fixtures[0].Scene;
var origin = DateTimeOffset.UnixEpoch;
var paused = new ScenePlaybackSession(controlScene, origin);
paused.Pause(origin.AddMilliseconds(5));
paused.Advance(origin.AddMilliseconds(5005));
paused.Resume(origin.AddMilliseconds(5005));
paused.Advance(origin.AddMilliseconds(5099));
if (paused.CurrentFrameIndex != 0) throw new Exception("Pause remaining time mismatch");
paused.Advance(origin.AddMilliseconds(5100));
if (paused.CurrentFrameIndex != 1) throw new Exception("Resume deadline mismatch");
paused.Restart(origin.AddMilliseconds(6000));
paused.Advance(origin.AddMilliseconds(6099));
if (paused.CurrentFrameIndex != 0) throw new Exception("Restart deadline mismatch");
paused.Advance(origin.AddMilliseconds(6100));
if (paused.CurrentFrameIndex != 1) throw new Exception("Restart advance mismatch");
paused.MoveNext(origin.AddMilliseconds(6200));
paused.MovePrevious(origin.AddMilliseconds(6200));
if (paused.CurrentFrameIndex != 1) throw new Exception("Manual step mismatch");
var controls = new { pauseResume = "passed", restart = "passed", manualStep = "passed", defaultSpeed = typeof(ScenePlaybackSession).GetProperty("Speed")?.GetValue(paused) ?? 1d };
File.WriteAllText(args[1], JsonSerializer.Serialize(new { deterministic, wallClock, controls }, new JsonSerializerOptions { WriteIndented = true }));

static ScnStoryboard Board(ushort first, bool blankFirst, ushort regular, ushort last, bool blankLast) => new(first, false, blankFirst, regular, false, last, false, blankLast, 0, 0, 0);
static long Expected(ScnScene scene)
{
    var s = scene.Storyboards.FirstOrDefault() ?? Board(0, false, 100, 0, false);
    return s.FirstFrameDelayMs + (scene.Frames.Count - (s.FirstFrameDelayMs > 0 && !s.BlankFirstFrame ? 1 : 0)) * (long)(s.FrameDelayMs == 0 ? 100 : s.FrameDelayMs) + s.LastFrameDelayMs;
}
static RunResult Run(string name, ScnScene scene, int cadence)
{
    var origin = DateTimeOffset.UnixEpoch;
    var session = new ScenePlaybackSession(scene, origin);
    var expected = Expected(scene);
    var trace = new StringBuilder();
    void Record(long ms, bool changed) => trace.Append($"{ms}:{session.CurrentFrameIndex}:{session.IsBlank}:{session.ClockAbove}:{session.IsComplete}:{changed};");
    Record(0, false);
    long elapsed = 0;
    int updates = 0, maxJump = 0;
    while (!session.IsComplete)
    {
        elapsed += cadence;
        var before = session.CurrentFrameIndex;
        bool changed = session.Advance(origin.AddMilliseconds(elapsed));
        if (changed) updates++;
        maxJump = Math.Max(maxJump, session.CurrentFrameIndex - before);
        if (changed || session.IsComplete) Record(elapsed, changed);
        if (elapsed > expected + cadence) throw new Exception($"Duration mismatch: {name}");
    }
    if (elapsed != (expected + cadence - 1) / cadence * cadence) throw new Exception($"Completion mismatch: {name}");
    var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(trace.ToString())));
    return new(name, cadence, expected, elapsed, updates, maxJump, hash);
}
record SceneInput(string path, string sha256);
record RunResult(string name, int cadenceMs, long expectedMs, long completionMs, int updates, int maxJump, string traceSha256);
