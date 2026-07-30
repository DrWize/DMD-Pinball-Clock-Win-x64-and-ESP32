using System.Net.Http.Json;
using System.Text.Json.Serialization;

namespace DmdClock.Core.Update;

public sealed record ReleaseUpdateResult(
    string InstalledVersion,
    string LatestVersion,
    Uri ReleasePage,
    bool UpdateAvailable);

public sealed class ReleaseUpdateChecker(HttpClient httpClient)
{
    public const string LatestReleaseApi =
        "https://api.github.com/repos/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/releases/latest";
    public static readonly Uri LatestReleasePage =
        new("https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/releases/latest");

    public async Task<ReleaseUpdateResult?> CheckAsync(
        string installedVersion,
        CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, LatestReleaseApi);
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        request.Headers.UserAgent.ParseAdd("DMDClock-Update-Check");
        using var response = await httpClient.SendAsync(request, cancellationToken);
        response.EnsureSuccessStatusCode();
        var release = await response.Content.ReadFromJsonAsync<LatestRelease>(
            cancellationToken: cancellationToken);
        if (string.IsNullOrWhiteSpace(release?.TagName) ||
            !TryVersion(release.TagName, out var latest) ||
            !TryVersion(installedVersion, out var installed))
        {
            return null;
        }

        return new ReleaseUpdateResult(
            installedVersion,
            release.TagName,
            LatestReleasePage,
            latest > installed);
    }

    public static bool TryVersion(string value, out Version version)
    {
        version = new Version();
        if (string.IsNullOrWhiteSpace(value))
            return false;

        var start = 0;
        while (start < value.Length && !char.IsDigit(value[start]))
            start++;
        if (start == value.Length)
            return false;

        var end = start;
        while (end < value.Length &&
               (char.IsDigit(value[end]) || value[end] == '.'))
            end++;
        var components = value[start..end].Split(
            '.',
            StringSplitOptions.RemoveEmptyEntries);
        if (components.Length < 2 || components.Length > 4 ||
            components.Any(component => !int.TryParse(component, out _)))
            return false;

        var normalized = string.Join('.', components.Take(3));
        if (components.Length == 2)
            normalized += ".0";
        return Version.TryParse(normalized, out version!);
    }

    private sealed record LatestRelease(
        [property: JsonPropertyName("tag_name")] string TagName);
}
