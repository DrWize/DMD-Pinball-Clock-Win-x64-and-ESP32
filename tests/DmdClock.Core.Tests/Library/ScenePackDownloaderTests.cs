using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using DmdClock.Core.Library;

namespace DmdClock.Core.Tests.Library;

public sealed class ScenePackDownloaderTests
{
    [Fact]
    public async Task DownloadAndInstall_ExtractsOnlyScenesAndReportsProgress()
    {
        var destination = NewTemporaryPath();
        try
        {
            var archive = CreateArchive(
                ("DotClk-Resources-master/Scenes/RD0001.scn", [1, 2, 3]),
                ("DotClk-Resources-master/Scenes/sub/demo.SCN", [4, 5]),
                ("DotClk-Resources-master/Fonts/font.fnt", [6]));
            const string downloadUrl = "https://example.test/scenes.zip";
            using var client = new HttpClient(new ArchiveHandler(downloadUrl, archive));
            var progressValues = new List<ScenePackDownloadProgress>();
            var progress = new ImmediateProgress<ScenePackDownloadProgress>(progressValues.Add);
            var pack = new ScenePackCatalogEntry(
                "test-pack", "Test pack", "Test scenes", true, "test-only",
                "https://example.test/source", downloadUrl, new string('a', 40),
                "zip", "/Scenes/", archive.Length, 5,
                Convert.ToHexString(SHA256.HashData(archive)).ToLowerInvariant(), 2,
                ["windows-x64"]);

            var result = await new ScenePackDownloader(client)
                .DownloadAndInstallAsync(pack, destination, progress);

            Assert.Equal(2, result.SceneCount);
            Assert.Equal(archive.Length, result.DownloadedBytes);
            Assert.Equal([1, 2, 3], await File.ReadAllBytesAsync(Path.Combine(destination, "RD0001.scn")));
            Assert.Equal([4, 5], await File.ReadAllBytesAsync(Path.Combine(destination, "sub", "demo.SCN")));
            Assert.False(File.Exists(Path.Combine(destination, "font.fnt")));
            Assert.Contains(progressValues, value => value.Percentage == 100);
        }
        finally
        {
            DeleteParent(destination);
        }
    }

    [Fact]
    public async Task ExtractScenesAtomically_ReplacesOldPackOnlyAfterSuccessfulExtraction()
    {
        var destination = NewTemporaryPath();
        var archivePath = destination + ".zip";
        try
        {
            Directory.CreateDirectory(destination);
            await File.WriteAllTextAsync(Path.Combine(destination, "old.scn"), "old");
            await File.WriteAllBytesAsync(archivePath, CreateArchive(
                ("repo/Scenes/new.scn", [7, 8, 9])));

            var count = await ScenePackDownloader.ExtractScenesAtomicallyAsync(archivePath, destination);

            Assert.Equal(1, count);
            Assert.False(File.Exists(Path.Combine(destination, "old.scn")));
            Assert.Equal([7, 8, 9], await File.ReadAllBytesAsync(Path.Combine(destination, "new.scn")));
        }
        finally
        {
            if (File.Exists(archivePath)) File.Delete(archivePath);
            DeleteParent(destination);
        }
    }

    [Fact]
    public async Task ExtractScenesAtomically_InstallsMetadataWithScenes()
    {
        var destination = NewTemporaryPath();
        var archivePath = destination + ".zip";
        var metadataPath = destination + ".metadata.json";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            await File.WriteAllBytesAsync(archivePath, CreateArchive(
                ("repo/Scenes/new.scn", [7, 8, 9])));
            await File.WriteAllTextAsync(metadataPath, """{"schemaVersion":1}""");

            var count = await ScenePackDownloader.ExtractScenesAtomicallyAsync(
                archivePath, destination, metadataPath: metadataPath);

            Assert.Equal(1, count);
            Assert.Equal(
                """{"schemaVersion":1}""",
                await File.ReadAllTextAsync(Path.Combine(
                    destination, SceneMetadataStore.DefaultFileName)));
        }
        finally
        {
            if (File.Exists(archivePath)) File.Delete(archivePath);
            if (File.Exists(metadataPath)) File.Delete(metadataPath);
            DeleteParent(destination);
        }
    }

    [Fact]
    public async Task ExtractScenesAtomically_RejectsTraversalAndPreservesExistingPack()
    {
        var destination = NewTemporaryPath();
        var archivePath = destination + ".zip";
        try
        {
            Directory.CreateDirectory(destination);
            await File.WriteAllTextAsync(Path.Combine(destination, "old.scn"), "old");
            await File.WriteAllBytesAsync(archivePath, CreateArchive(
                ("repo/Scenes/../../outside.scn", [1])));

            await Assert.ThrowsAsync<InvalidDataException>(
                () => ScenePackDownloader.ExtractScenesAtomicallyAsync(archivePath, destination));

            Assert.Equal("old", await File.ReadAllTextAsync(Path.Combine(destination, "old.scn")));
            Assert.False(File.Exists(Path.Combine(Path.GetDirectoryName(destination)!, "outside.scn")));
        }
        finally
        {
            if (File.Exists(archivePath)) File.Delete(archivePath);
            DeleteParent(destination);
        }
    }

    private static byte[] CreateArchive(params (string Path, byte[] Contents)[] files)
    {
        using var output = new MemoryStream();
        using (var archive = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true))
        {
            foreach (var file in files)
            {
                var entry = archive.CreateEntry(file.Path);
                using var target = entry.Open();
                target.Write(file.Contents);
            }
        }
        return output.ToArray();
    }

    private static string NewTemporaryPath()
    {
        var parent = Path.Combine(Path.GetTempPath(), $"dmdclock-scene-pack-tests-{Guid.NewGuid():N}");
        return Path.Combine(parent, "DotClk");
    }

    private static void DeleteParent(string destination)
    {
        var parent = Path.GetDirectoryName(destination);
        if (parent is not null && Directory.Exists(parent)) Directory.Delete(parent, recursive: true);
    }

    private sealed class ArchiveHandler(string expectedUrl, byte[] archive) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Assert.Equal(expectedUrl, request.RequestUri?.AbsoluteUri);
            var content = new ByteArrayContent(archive);
            content.Headers.ContentLength = archive.Length;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = content });
        }
    }

    private sealed class ImmediateProgress<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }
}
