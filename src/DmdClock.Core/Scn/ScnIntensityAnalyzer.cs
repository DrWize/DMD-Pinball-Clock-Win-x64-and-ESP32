using System.Buffers.Binary;

namespace DmdClock.Core.Scn;

/// <summary>Reads raw 4-bit scene values without applying playback geometry limits.</summary>
public static class ScnIntensityAnalyzer
{
    private const ushort SupportedVersion = 1;
    private const int StoryboardBytes = 36;
    private const int MaxItemCount = 10_000;

    public static ScnIntensityAnalysis Analyze(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        using var stream = File.OpenRead(path);
        return Analyze(stream);
    }

    public static ScnIntensityAnalysis Analyze(Stream stream)
    {
        ArgumentNullException.ThrowIfNull(stream);
        var version = ReadUInt16(stream);
        if (version != SupportedVersion) throw new ScnFormatException($"Unsupported SCN version {version}; expected {SupportedVersion}.");
        var frameCount = ReadUInt16(stream);
        var storyboardCount = ReadUInt16(stream);
        if (frameCount > MaxItemCount || storyboardCount > MaxItemCount) throw new ScnFormatException("SCN declares too many frames or storyboards.");
        Skip(stream, checked(storyboardCount * StoryboardBytes));
        var histogram = new long[16];
        for (var frame = 0; frame < frameCount; frame++) ReadFrame(stream, histogram);
        if (stream.CanSeek && stream.Position != stream.Length) throw new ScnFormatException($"SCN contains {stream.Length - stream.Position} unexpected trailing bytes.");
        var used = Enumerable.Range(0, 16).Where(index => histogram[index] != 0).ToArray();
        return new ScnIntensityAnalysis(frameCount, used, used.Count(static value => value != 0), histogram);
    }

    private static void ReadFrame(Stream stream, long[] histogram)
    {
        var width = ReadUInt16(stream); var height = ReadUInt16(stream); var bpp = ReadUInt16(stream); var masked = ReadUInt16(stream);
        if (width == 0 || height == 0 || bpp != 4 || (masked != 0 && masked != 1)) throw new ScnFormatException("SCN frame has unsupported intensity geometry or mask flag.");
        var pixels = checked((int)width * height);
        for (var offset = 0; offset < pixels; offset += 2)
        {
            var packed = ReadByte(stream);
            histogram[packed & 0x0f]++;
            if (offset + 1 < pixels) histogram[packed >> 4]++;
        }
        if (masked == 1) Skip(stream, (pixels + 7) / 8);
    }

    private static ushort ReadUInt16(Stream stream) { Span<byte> bytes = stackalloc byte[2]; stream.ReadExactly(bytes); return BinaryPrimitives.ReadUInt16LittleEndian(bytes); }
    private static byte ReadByte(Stream stream) { var value = stream.ReadByte(); return value < 0 ? throw new EndOfStreamException() : (byte)value; }
    private static void Skip(Stream stream, int count) { Span<byte> buffer = stackalloc byte[256]; while (count > 0) { var size = Math.Min(count, buffer.Length); stream.ReadExactly(buffer[..size]); count -= size; } }
}
