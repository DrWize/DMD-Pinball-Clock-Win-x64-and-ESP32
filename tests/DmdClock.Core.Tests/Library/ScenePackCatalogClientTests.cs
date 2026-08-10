using System.Net;
using System.Text;
using DmdClock.Core.Library;

namespace DmdClock.Core.Tests.Library;

public sealed class ScenePackCatalogClientTests
{
    [Fact]
    public async Task RepositoryCatalog_MatchesRuntimeContract()
    {
        var repositoryRoot = Path.GetFullPath(
            Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));
        var json = await File.ReadAllTextAsync(
            Path.Combine(repositoryRoot, "scenes", "catalog.json"));
        using var client = new HttpClient(new JsonHandler(json));

        var catalog = await new ScenePackCatalogClient(client).DownloadAsync();
        var original = catalog.GetRequiredAvailablePack("dotclk-original", "esp32-s3");

        Assert.Equal(2324, original.SceneCount);
        Assert.Equal(ScenePackDownloader.SourceUrl, original.DownloadUrl);
        Assert.Equal(ScenePackDownloader.SourceSha256, original.ArchiveSha256);
        Assert.False(catalog.Packs.Single(pack => pack.PackId == "drwize-complete").Available);
    }

    [Fact]
    public async Task Download_ValidatesCatalogAndSelectsPackByPlatform()
    {
        var json = """
            {
              "schemaVersion": 1,
              "updatedAt": "2026-08-10T00:00:00Z",
              "packs": [
                {
                  "packId": "dotclk-original",
                  "displayName": "Original DotClk scenes",
                  "description": "Official external source",
                  "available": true,
                  "distributionStatus": "official-external-source",
                  "sourcePageUrl": "https://example.test/source",
                  "downloadUrl": "https://example.test/scenes.zip",
                  "sourceRevision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                  "archiveFormat": "zip",
                  "scenesPathMarker": "/Scenes/",
                  "downloadBytes": 123,
                  "installedBytes": 456,
                  "archiveSha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                  "sceneCount": 2,
                  "supportedPlatforms": ["windows-x64", "osx-arm64", "esp32-s3"]
                }
              ]
            }
            """;
        using var client = new HttpClient(new JsonHandler(json));

        var catalog = await new ScenePackCatalogClient(client).DownloadAsync();
        var pack = catalog.GetRequiredAvailablePack("dotclk-original", "osx-arm64");

        Assert.Equal(1, catalog.SchemaVersion);
        Assert.Equal("https://example.test/scenes.zip", pack.DownloadUrl);
        Assert.Equal(2, pack.SceneCount);
    }

    [Fact]
    public async Task Download_RejectsAvailablePackWithoutVerifiedArchive()
    {
        var json = """
            {
              "schemaVersion": 1,
              "updatedAt": "2026-08-10T00:00:00Z",
              "packs": [
                {
                  "packId": "broken",
                  "displayName": "Broken",
                  "description": "Missing verification",
                  "available": true,
                  "distributionStatus": "unknown",
                  "sourcePageUrl": "https://example.test/source",
                  "downloadUrl": null,
                  "sourceRevision": null,
                  "archiveFormat": "zip",
                  "scenesPathMarker": "/Scenes/",
                  "downloadBytes": null,
                  "installedBytes": 1,
                  "archiveSha256": null,
                  "sceneCount": 1,
                  "supportedPlatforms": ["windows-x64"]
                }
              ]
            }
            """;
        using var client = new HttpClient(new JsonHandler(json));

        await Assert.ThrowsAsync<InvalidDataException>(
            () => new ScenePackCatalogClient(client).DownloadAsync());
    }

    [Fact]
    public async Task Download_RejectsArchiveMetadataForUnavailablePack()
    {
        var json = """
            {
              "schemaVersion": 1,
              "updatedAt": "2026-08-10T00:00:00Z",
              "packs": [
                {
                  "packId": "private",
                  "displayName": "Private",
                  "description": "Not available",
                  "available": false,
                  "distributionStatus": "rights-review-required",
                  "sourcePageUrl": "https://example.test/source",
                  "downloadUrl": null,
                  "sourceRevision": null,
                  "archiveFormat": "zip",
                  "scenesPathMarker": "/Scenes/",
                  "downloadBytes": null,
                  "installedBytes": 1,
                  "archiveSha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                  "sceneCount": 1,
                  "supportedPlatforms": ["windows-x64"]
                }
              ]
            }
            """;
        using var client = new HttpClient(new JsonHandler(json));

        await Assert.ThrowsAsync<InvalidDataException>(
            () => new ScenePackCatalogClient(client).DownloadAsync());
    }

    private sealed class JsonHandler(string json) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Assert.Equal(ScenePackCatalogClient.CatalogUrl, request.RequestUri?.AbsoluteUri);
            var bytes = Encoding.UTF8.GetBytes(json);
            var content = new ByteArrayContent(bytes);
            content.Headers.ContentLength = bytes.Length;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = content });
        }
    }
}
