using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Text.Json;
using DmdClock.App.Diagnostics;

namespace DmdClock.Core.Tests.Playback;

public sealed class DebugApiTests
{
    [Fact]
    public async Task AuthenticatedApiReturnsConsistentCaptureAndValidatesCommands()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        var state = new DebugState(1, "test", Guid.NewGuid(), DateTimeOffset.UtcNow, "animation", true, false, 1, null, null);
        bool? included = null;
        string? loadedScene = null;
        await using var server = new DebugApiServer(port, "test-secret", () => Task.FromResult(state), command =>
        {
            if (command.Action == "load-scene")
            {
                loadedScene = command.ScenePath;
                return Task.FromResult(state);
            }
            if (command.Action == "restart") throw new InvalidOperationException();
            if (command.Action != "pause") throw new ArgumentException();
            return Task.FromResult(state with { Paused = true });
        }, debug =>
        {
            included = debug;
            return Task.FromResult(new PngCapture(state, [137, 80, 78, 71], 128, 32));
        });
        await server.StartAsync();
        using var client = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{port}") };
        foreach (var path in new[] { "state", "capture", "screenshot" })
            Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/api/" + path)).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.PostAsJsonAsync("/api/playback", new { action = "pause" })).StatusCode);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", "wrong");
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/api/state")).StatusCode);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", "test-secret");
        Assert.Equal(state, await client.GetFromJsonAsync<DebugState>("/api/state"));
        var capture = await client.GetFromJsonAsync<DebugCapture>("/api/capture?includeDebug=true");
        Assert.NotNull(capture);
        Assert.Equal(state, capture.State);
        Assert.True(included);
        Assert.Equal(new byte[] { 137, 80, 78, 71 }, Convert.FromBase64String(capture.Screenshot.Base64));
        var png = await client.GetAsync("/api/screenshot");
        Assert.Equal("image/png", png.Content.Headers.ContentType!.MediaType);
        Assert.Equal(state.CaptureId.ToString(), png.Headers.GetValues("X-Capture-Id").Single());
        Assert.False(included);
        Assert.Equal("no-store", png.Headers.CacheControl!.ToString());
        Assert.False(png.Headers.Contains("Access-Control-Allow-Origin"));
        Assert.Equal(HttpStatusCode.BadRequest, (await client.GetAsync("/api/capture?includeDebug=nope")).StatusCode);
        var paused = await client.PostAsJsonAsync("/api/playback", new { action = "pause" });
        Assert.True((await paused.Content.ReadFromJsonAsync<DebugState>())!.Paused);
        var loaded = await client.PostAsJsonAsync("/api/playback", new { action = "load-scene", scenePath = "LAST_ACTION_HERO_010.scn" });
        Assert.Equal(HttpStatusCode.OK, loaded.StatusCode);
        Assert.Equal("LAST_ACTION_HERO_010.scn", loadedScene);
        Assert.Equal(HttpStatusCode.Conflict, (await client.PostAsJsonAsync("/api/playback", new { action = "restart" })).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await client.PostAsJsonAsync("/api/playback", new { action = "unknown" })).StatusCode);
        using var malformed = new StringContent("{", System.Text.Encoding.UTF8, "application/json");
        Assert.Equal(HttpStatusCode.BadRequest, (await client.PostAsync("/api/playback", malformed)).StatusCode);
    }
}
