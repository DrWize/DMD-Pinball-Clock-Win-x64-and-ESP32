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
                "test-pack", "Test pack", "Test scenes", "test-1", "Test-Pack", true, [],
                true, "test-only",
                "https://example.test/source", downloadUrl, new string('a', 40),
                "zip", "/Scenes/", archive.Length, 5,
                Convert.ToHexString(SHA256.HashData(archive)).ToLowerInvariant(), 2,
                ["windows-x64"]);

            var result = await new ScenePackDownloader(client)
                .DownloadAndInstallAsync(pack, destination, progress);

            Assert.Equal(2, result.SceneCount);
            Assert.Equal("test-pack", result.PackId);
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
    public async Task DownloadAndInstall_KeepsManagedPackDirectoriesIsolated()
    {
        var parent = Path.Combine(Path.GetTempPath(), $"dmdclock-two-packs-{Guid.NewGuid():N}");
        var originalDestination = Path.Combine(parent, "DotCLK-Orig");
        var largeDestination = Path.Combine(parent, "DMD-Large");
        try
        {
            var originalArchive = CreateArchive(("original/Scenes/original.scn", [1]));
            var largeArchive = CreateArchive(
                ("large/Scenes/original.scn", [1]),
                ("large/Scenes/extra.scn", [2]));
            const string originalUrl = "https://example.test/original.zip";
            const string largeUrl = "https://example.test/large.zip";
            var original = CreatePack(
                "dotclk-original", "Original DotCLK-Orig", "DotCLK-Orig",
                originalUrl, originalArchive, 1, preferred: true);
            var large = CreatePack(
                "drwize-complete", "DMD-Large", "DMD-Large",
                largeUrl, largeArchive, 2, preferred: false);

            using (var client = new HttpClient(new ArchiveHandler(originalUrl, originalArchive)))
                await new ScenePackDownloader(client)
                    .DownloadAndInstallAsync(original, originalDestination);
            using (var client = new HttpClient(new ArchiveHandler(largeUrl, largeArchive)))
                await new ScenePackDownloader(client)
                    .DownloadAndInstallAsync(large, largeDestination);
            var originalUpdateArchive = CreateArchive(
                ("original/Scenes/original.scn", [9]));
            var originalUpdate = CreatePack(
                "dotclk-original", "Original DotCLK-Orig", "DotCLK-Orig",
                originalUrl, originalUpdateArchive, 1, preferred: true);
            using (var client = new HttpClient(
                new ArchiveHandler(originalUrl, originalUpdateArchive)))
                await new ScenePackDownloader(client)
                    .DownloadAndInstallAsync(originalUpdate, originalDestination);

            Assert.Single(Directory.GetFiles(originalDestination, "*.scn"));
            Assert.Equal([9], await File.ReadAllBytesAsync(
                Path.Combine(originalDestination, "original.scn")));
            Assert.Equal(2, Directory.GetFiles(largeDestination, "*.scn").Length);
            Assert.Equal([2], await File.ReadAllBytesAsync(
                Path.Combine(largeDestination, "extra.scn")));
            Assert.False(File.Exists(Path.Combine(originalDestination, "extra.scn")));
        }
        finally
        {
            if (Directory.Exists(parent)) Directory.Delete(parent, recursive: true);
        }
    }

    [Fact]
    public async Task DownloadAndInstall_RejectsCorruptArchiveWithoutChangingInstalledPack()
    {
        var destination = NewTemporaryPath();
        const string downloadUrl = "https://example.test/corrupt.zip";
        try
        {
            Directory.CreateDirectory(destination);
            await File.WriteAllTextAsync(Path.Combine(destination, "installed.scn"), "keep");
            var archive = CreateArchive(("repo/Scenes/new.scn", [1, 2, 3]));
            var pack = CreatePack(
                "dotclk-original", "Original DotCLK-Orig", "DotCLK-Orig",
                downloadUrl, archive, 1, preferred: true) with
            {
                ArchiveSha256 = new string('0', 64)
            };
            using var client = new HttpClient(new ArchiveHandler(downloadUrl, archive));

            await Assert.ThrowsAsync<InvalidDataException>(() =>
                new ScenePackDownloader(client).DownloadAndInstallAsync(pack, destination));

            Assert.Equal("keep", await File.ReadAllTextAsync(
                Path.Combine(destination, "installed.scn")));
            Assert.False(File.Exists(Path.Combine(destination, "new.scn")));
        }
        finally
        {
            DeleteParent(destination);
        }
    }

    [Fact]
    public async Task DownloadAndInstall_CancellationDoesNotChangeInstalledPack()
    {
        var destination = NewTemporaryPath();
        const string downloadUrl = "https://example.test/cancel.zip";
        try
        {
            Directory.CreateDirectory(destination);
            await File.WriteAllTextAsync(Path.Combine(destination, "installed.scn"), "keep");
            var scene = new byte[256 * 1024];
            new Random(42).NextBytes(scene);
            var archive = CreateArchive(("repo/Scenes/large.scn", scene));
            var pack = CreatePack(
                "dotclk-original", "Original DotCLK-Orig", "DotCLK-Orig",
                downloadUrl, archive, 1, preferred: true);
            using var cancellation = new CancellationTokenSource();
            var progress = new ImmediateProgress<ScenePackDownloadProgress>(
                value =>
                {
                    if (value.BytesDownloaded > 0) cancellation.Cancel();
                });
            using var client = new HttpClient(new ArchiveHandler(downloadUrl, archive));

            await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
                new ScenePackDownloader(client).DownloadAndInstallAsync(
                    pack, destination, progress, cancellation.Token));

            Assert.Equal("keep", await File.ReadAllTextAsync(
                Path.Combine(destination, "installed.scn")));
            Assert.False(File.Exists(Path.Combine(destination, "large.scn")));
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

    private static ScenePackCatalogEntry CreatePack(
        string packId,
        string displayName,
        string managedDirectory,
        string downloadUrl,
        byte[] archive,
        int sceneCount,
        bool preferred) =>
        new(
            packId, displayName, "Test scenes", "test-1", managedDirectory,
            preferred, [], true, "test-only", "https://example.test/source",
            downloadUrl, new string('a', 40), "zip", "/Scenes/", archive.Length,
            archive.Length, Convert.ToHexString(SHA256.HashData(archive)).ToLowerInvariant(),
            sceneCount, ["windows-x64", "osx-arm64"]);

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
