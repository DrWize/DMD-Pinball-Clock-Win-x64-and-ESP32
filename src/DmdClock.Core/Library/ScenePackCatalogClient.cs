using System.Net.Http.Headers;
using System.Text.Json;

namespace DmdClock.Core.Library;

public sealed class ScenePackCatalogClient
{
    public const string CatalogUrl =
        "https://raw.githubusercontent.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/master/scenes/catalog.json";
    public const long MaximumCatalogBytes = 1024 * 1024;

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        AllowTrailingCommas = false,
        ReadCommentHandling = JsonCommentHandling.Disallow
    };

    private readonly HttpClient _httpClient;

    public ScenePackCatalogClient(HttpClient httpClient)
    {
        ArgumentNullException.ThrowIfNull(httpClient);
        _httpClient = httpClient;
    }

    public async Task<ScenePackCatalog> DownloadAsync(CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, CatalogUrl);
        request.Headers.UserAgent.Add(new ProductInfoHeaderValue("DMDClock", "1.0"));
        using var response = await _httpClient.SendAsync(
            request, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
            .ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength is > MaximumCatalogBytes)
            throw new InvalidDataException("The scene-pack catalog exceeds the 1 MB safety limit.");

        await using var source = await response.Content.ReadAsStreamAsync(cancellationToken)
            .ConfigureAwait(false);
        using var bounded = new MemoryStream();
        var buffer = new byte[81920];
        while (true)
        {
            var read = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (read == 0) break;
            if (bounded.Length + read > MaximumCatalogBytes)
                throw new InvalidDataException("The scene-pack catalog exceeded the 1 MB safety limit.");
            await bounded.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
        }
        bounded.Position = 0;
        var catalog = await JsonSerializer.DeserializeAsync<ScenePackCatalog>(
            bounded, JsonOptions, cancellationToken).ConfigureAwait(false) ??
            throw new InvalidDataException("The scene-pack catalog is empty.");
        Validate(catalog);
        return catalog;
    }

    private static void Validate(ScenePackCatalog catalog)
    {
        if (catalog.SchemaVersion != ScenePackCatalog.CurrentSchemaVersion)
            throw new InvalidDataException(
                $"Unsupported scene-pack catalog schema {catalog.SchemaVersion}; expected {ScenePackCatalog.CurrentSchemaVersion}.");
        if (catalog.Packs is null || catalog.Packs.Count == 0)
            throw new InvalidDataException("The scene-pack catalog does not contain any packs.");
        if (catalog.Packs.GroupBy(item => item.PackId, StringComparer.OrdinalIgnoreCase)
            .Any(group => group.Count() > 1))
            throw new InvalidDataException("The scene-pack catalog contains duplicate pack IDs.");

        foreach (var pack in catalog.Packs)
        {
            if (string.IsNullOrWhiteSpace(pack.PackId) ||
                string.IsNullOrWhiteSpace(pack.DisplayName) ||
                string.IsNullOrWhiteSpace(pack.Description) ||
                string.IsNullOrWhiteSpace(pack.DistributionStatus) ||
                !IsHttps(pack.SourcePageUrl) ||
                pack.ArchiveFormat != "zip" ||
                pack.ScenesPathMarker != "/Scenes/" ||
                pack.InstalledBytes <= 0 ||
                pack.SceneCount <= 0 ||
                pack.SupportedPlatforms is null ||
                pack.SupportedPlatforms.Count == 0)
                throw new InvalidDataException($"Scene pack '{pack.PackId}' has invalid required fields.");

            if (pack.Available &&
                (!IsHttps(pack.DownloadUrl) ||
                 pack.DownloadBytes is not > 0 ||
                 pack.SourceRevision?.Length != 40 ||
                 !pack.SourceRevision.All(Uri.IsHexDigit) ||
                 pack.ArchiveSha256?.Length != 64 ||
                 !pack.ArchiveSha256.All(Uri.IsHexDigit)))
                throw new InvalidDataException(
                    $"Available scene pack '{pack.PackId}' lacks a verified HTTPS archive.");
            if (!pack.Available &&
                (pack.DownloadUrl is not null ||
                 pack.SourceRevision is not null ||
                 pack.DownloadBytes is not null ||
                 pack.ArchiveSha256 is not null))
                throw new InvalidDataException(
                    $"Unavailable scene pack '{pack.PackId}' must not expose archive metadata.");
        }
    }

    private static bool IsHttps(string? value) =>
        Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps;
}
