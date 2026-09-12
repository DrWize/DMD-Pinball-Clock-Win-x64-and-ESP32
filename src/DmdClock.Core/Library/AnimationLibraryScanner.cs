using System.Security.Cryptography;
using System.Text;
using DmdClock.Core.Scn;

namespace DmdClock.Core.Library;

public sealed class AnimationLibraryScanner
{
    public async Task<AnimationLibraryIndex> ScanAsync(
        string rootPath,
        AnimationLibraryIndex? previous = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(rootPath);
        var root = Path.GetFullPath(rootPath);
        if (!Directory.Exists(root))
            throw new DirectoryNotFoundException(root);

        var previousByPath = previous?.Items.ToDictionary(
            static item => NormalizeRelativePath(item.RelativePath),
            StringComparer.OrdinalIgnoreCase) ?? new Dictionary<string, AnimationLibraryItem>(StringComparer.OrdinalIgnoreCase);
        var previousByHash = previous?.Items
            .Where(static item => !string.IsNullOrEmpty(item.Sha256))
            .GroupBy(static item => item.Sha256, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(static group => group.Key, static group => group.First(), StringComparer.OrdinalIgnoreCase) ??
            new Dictionary<string, AnimationLibraryItem>(StringComparer.OrdinalIgnoreCase);

        var files = Directory.EnumerateFiles(root, "*.scn", SearchOption.AllDirectories)
            .Order(NaturalPathComparer.Instance)
            .ToArray();
        var items = new List<AnimationLibraryItem>(files.Length);

        foreach (var file in files)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var info = new FileInfo(file);
            var relativePath = NormalizeRelativePath(Path.GetRelativePath(root, file));
            var lastWrite = new DateTimeOffset(info.LastWriteTimeUtc, TimeSpan.Zero);

            if (previousByPath.TryGetValue(relativePath, out var existing) &&
                existing.FileSize == info.Length && existing.LastWriteUtc == lastWrite &&
                existing.Warnings is not null)
            {
                items.Add(existing);
                continue;
            }

            items.Add(await ReadItemAsync(file, relativePath, info.Length, lastWrite, previousByPath, previousByHash, cancellationToken));
        }

        return new AnimationLibraryIndex(AnimationLibraryIndex.CurrentSchemaVersion, root, DateTimeOffset.UtcNow, items);
    }

    private static async Task<AnimationLibraryItem> ReadItemAsync(
        string fullPath,
        string relativePath,
        long fileSize,
        DateTimeOffset lastWrite,
        IReadOnlyDictionary<string, AnimationLibraryItem> previousByPath,
        IReadOnlyDictionary<string, AnimationLibraryItem> previousByHash,
        CancellationToken cancellationToken)
    {
        var hash = string.Empty;
        ScnScene? scene = null;
        ScnIntensityAnalysis? intensity = null;
        string? error = null;
        IReadOnlyList<ScnDiagnostic> warnings = [];
        try
        {
            await using var stream = new FileStream(fullPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            hash = Convert.ToHexString(await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false));
            stream.Position = 0;
            intensity = ScnIntensityAnalyzer.Analyze(stream);
            stream.Position = 0;
            var inspection = ScnCompatibilityInspector.Inspect(stream);
            scene = inspection.Scene;
            warnings = inspection.Status == ScnCompatibilityStatus.Warned
                ? inspection.Diagnostics
                : [];
            if (inspection.Status == ScnCompatibilityStatus.Rejected)
                error = string.Join(" ", inspection.Diagnostics.Select(static diagnostic =>
                    $"[{diagnostic.Code}] {diagnostic.Message}"));

            var finalInfo = new FileInfo(fullPath);
            if (finalInfo.Length != fileSize || finalInfo.LastWriteTimeUtc != lastWrite.UtcDateTime)
                throw new IOException("File changed while it was being scanned; it will be retried on the next scan.");
        }
        catch (Exception exception) when (exception is (IOException and not ScnFormatException) or UnauthorizedAccessException)
        {
            hash = string.Empty;
            error = exception.Message;
        }
        catch (ScnFormatException)
        {
            var inspection = ScnCompatibilityInspector.Inspect(fullPath);
            error = string.Join(" ", inspection.Diagnostics.Select(static diagnostic =>
                $"[{diagnostic.Code}] {diagnostic.Message}"));
        }
        catch (EndOfStreamException)
        {
            var inspection = ScnCompatibilityInspector.Inspect(fullPath);
            error = string.Join(" ", inspection.Diagnostics.Select(static diagnostic =>
                $"[{diagnostic.Code}] {diagnostic.Message}"));
        }

        var id = previousByPath.TryGetValue(relativePath, out var samePath)
            ? samePath.Id
            : previousByHash.TryGetValue(hash, out var moved)
                ? moved.Id
                : CreateStableId(relativePath);
        var duration = scene is null ? 0 : EstimateDuration(scene);
        return new AnimationLibraryItem(
            id,
            relativePath,
            fileSize,
            lastWrite,
            hash,
            scene?.Frames.Count ?? 0,
            duration,
            error,
            warnings,
            intensity);
    }

    private static long EstimateDuration(ScnScene scene)
    {
        if (scene.Frames.Count == 0) return 0;
        var storyboard = scene.Storyboards.FirstOrDefault();
        var regular = storyboard?.FrameDelayMs > 0 ? storyboard.FrameDelayMs : 100;
        var duration = (long)regular * scene.Frames.Count;
        if (storyboard?.FirstFrameDelayMs > 0) duration += storyboard.FirstFrameDelayMs - regular;
        if (scene.Frames.Count > 1 && storyboard?.LastFrameDelayMs > 0) duration += storyboard.LastFrameDelayMs - regular;
        return Math.Max(duration, 0);
    }

    private static string CreateStableId(string relativePath)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes($"dmdclock:{relativePath.ToUpperInvariant()}"));
        return Convert.ToHexString(bytes.AsSpan(0, 16));
    }

    private static string NormalizeRelativePath(string path) => path.Replace('\\', '/');
}
