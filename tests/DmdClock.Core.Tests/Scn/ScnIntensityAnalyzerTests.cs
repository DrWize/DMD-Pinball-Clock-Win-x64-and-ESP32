using DmdClock.Core.Scn;

namespace DmdClock.Core.Tests.Scn;

public sealed class ScnIntensityAnalyzerTests
{
    [Fact]
    public void Analyze_CountsRawValuesIncludingMaskedPixels()
    {
        using var stream = TestScnFile.Create(includeMask: true, frameCount: 1);

        var result = ScnIntensityAnalyzer.Analyze(stream);

        Assert.Equal(1, result.FrameCount);
        Assert.Equal(new[] { 0, 1, 10 }, result.UsedValues);
        Assert.Equal(2, result.NonzeroLevelCount);
        Assert.Equal(4094, result.Histogram[0]);
        Assert.Equal(1, result.Histogram[1]);
        Assert.Equal(1, result.Histogram[10]);
    }

    [Fact]
    public void Analyze_RejectsTrailingData()
    {
        using var stream = TestScnFile.Create();
        stream.Position = stream.Length;
        stream.WriteByte(0);
        stream.Position = 0;

        Assert.Throws<ScnFormatException>(() => ScnIntensityAnalyzer.Analyze(stream));
    }

    [Fact]
    public void Analyze_ExcludesOddWidthPaddingAndIncludesMaskedPixels()
    {
        using var stream = CreateOddWidthMaskedScene();

        var result = ScnIntensityAnalyzer.Analyze(stream);

        Assert.Equal(new[] { 1, 2, 3 }, result.UsedValues);
        Assert.Equal(1, result.Histogram[1]);
        Assert.Equal(1, result.Histogram[2]);
        Assert.Equal(1, result.Histogram[3]);
        Assert.Equal(0, result.Histogram[15]);
    }

    private static MemoryStream CreateOddWidthMaskedScene()
    {
        var stream = new MemoryStream();
        using (var writer = new BinaryWriter(stream, System.Text.Encoding.UTF8, leaveOpen: true))
        {
            writer.Write((ushort)1); writer.Write((ushort)1); writer.Write((ushort)1);
            writer.Write(new byte[36]);
            writer.Write((ushort)3); writer.Write((ushort)1); writer.Write((ushort)4); writer.Write((ushort)1);
            writer.Write((byte)0x21); writer.Write((byte)0xf3); // high nibble is packed-row padding.
            writer.Write((byte)0x07);
        }
        stream.Position = 0;
        return stream;
    }
}
