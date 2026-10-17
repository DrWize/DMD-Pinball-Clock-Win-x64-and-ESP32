using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

namespace DmdClock.App.Diagnostics;

public sealed record PlaybackCommand(string Action, double? Speed = null, string? ScenePath = null);
public sealed record CapturedImage(string MimeType, string Base64, int Width, int Height);
public sealed record SceneResult(string File, DmdClock.Core.Playback.PlaybackDiagnostics Timing);
public sealed record DebugState(int ApiVersion, string AppVersion, Guid CaptureId, DateTimeOffset CapturedAt,
    string DisplayMode, bool DebugEnabled, bool Paused, double Speed, SceneResult? Scene, SceneResult? LastSceneResult);
public sealed record DebugCapture(DebugState State, CapturedImage Screenshot);
public sealed record PngCapture(DebugState State, byte[] Png, int Width, int Height);

public sealed class DebugApiServer : IAsyncDisposable
{
    private readonly WebApplication _app;
    public DebugApiServer(int port, string token, Func<Task<DebugState>> state,
        Func<PlaybackCommand, Task<DebugState>> command, Func<bool, Task<PngCapture>> capture)
    {
        if (string.IsNullOrWhiteSpace(token)) throw new ArgumentException("API token is required.", nameof(token));
        if (port is < 1024 or > 65535) throw new ArgumentOutOfRangeException(nameof(port));
        var builder = WebApplication.CreateSlimBuilder(new WebApplicationOptions { Args = [] });
        builder.Logging.ClearProviders(); // Never log request headers or credentials.
        builder.WebHost.ConfigureKestrel(options =>
        {
            options.ListenAnyIP(port);
            options.Limits.MaxRequestBodySize = 4096;
            options.Limits.RequestHeadersTimeout = TimeSpan.FromSeconds(10);
        });
        _app = builder.Build();
        var expected = SHA256.HashData(Encoding.UTF8.GetBytes("Bearer " + token));
        _app.Use(async (context, next) =>
        {
            context.Response.Headers.CacheControl = "no-store";
            var provided = SHA256.HashData(Encoding.UTF8.GetBytes(context.Request.Headers.Authorization.ToString()));
            if (!CryptographicOperations.FixedTimeEquals(expected, provided))
            {
                context.Response.StatusCode = 401;
                return;
            }
            try { await next(context); }
            catch (ArgumentException) { context.Response.StatusCode = 400; }
            catch (JsonException) { context.Response.StatusCode = 400; }
            catch (InvalidOperationException) { context.Response.StatusCode = 409; }
        });
        _app.MapGet("/api/state", async () => Results.Json(await state()));
        _app.MapPost("/api/playback", async (HttpContext context) =>
        {
            var request = await context.Request.ReadFromJsonAsync<PlaybackCommand>();
            return request is null ? Results.BadRequest() : Results.Json(await command(request));
        });
        _app.MapGet("/api/screenshot", async (HttpContext context) =>
        {
            var shot = await capture(IncludeDebug(context));
            context.Response.Headers["X-Capture-Id"] = shot.State.CaptureId.ToString();
            return Results.File(shot.Png, "image/png");
        });
        _app.MapGet("/api/capture", async (HttpContext context) =>
        {
            var shot = await capture(IncludeDebug(context));
            return Results.Json(new DebugCapture(shot.State,
                new("image/png", Convert.ToBase64String(shot.Png), shot.Width, shot.Height)));
        });
    }

    private static bool IncludeDebug(HttpContext context)
    {
        var value = context.Request.Query["includeDebug"].ToString();
        if (value.Length == 0) return false;
        return bool.TryParse(value, out var result) ? result : throw new ArgumentException("Invalid includeDebug.");
    }

    public Task StartAsync() => _app.StartAsync();
    public async ValueTask DisposeAsync()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try { await _app.StopAsync(timeout.Token); }
        finally { await _app.DisposeAsync(); }
    }
}
