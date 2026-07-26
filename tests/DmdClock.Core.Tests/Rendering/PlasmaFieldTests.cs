using DmdClock.Core.Rendering;

namespace DmdClock.Core.Tests.Rendering;

public sealed class PlasmaFieldTests
{
    [Fact]
    public void PhaseAtMilliseconds_WrapsAtCycleBoundary()
    {
        Assert.Equal(0, PlasmaField.PhaseAtMilliseconds(0));
        Assert.Equal(128, PlasmaField.PhaseAtMilliseconds(4_000));
        Assert.Equal(0, PlasmaField.PhaseAtMilliseconds(8_000));
        Assert.Equal(0, PlasmaField.PhaseAtMilliseconds(-1));
    }

    [Fact]
    public void GetPaletteIndex_AlwaysReturnsValidIndex()
    {
        foreach (var phase in new byte[] { 0, 1, 64, 127, 192, 255 })
        for (var y = 0; y < 32; y++)
        for (var x = 0; x < 128; x++)
        {
            var index = PlasmaField.GetPaletteIndex(x, y, 128, 32, phase);
            Assert.InRange(index, 0, PlasmaField.PaletteSize - 1);
        }
    }

    [Fact]
    public void GetPaletteIndex_IsDeterministicAndChangesWithPhase()
    {
        var first = PlasmaField.GetPaletteIndex(37, 11, 128, 32, 42);
        var repeated = PlasmaField.GetPaletteIndex(37, 11, 128, 32, 42);
        var advanced = PlasmaField.GetPaletteIndex(37, 11, 128, 32, 106);

        Assert.Equal(first, repeated);
        Assert.NotEqual(first, advanced);
    }

    [Theory]
    [InlineData(0, 0, 0, 49)]
    [InlineData(37, 11, 42, 55)]
    [InlineData(127, 31, 255, 78)]
    [InlineData(64, 16, 128, 75)]
    public void GetPaletteIndex_MatchesEsp32TestVectors(
        int x,
        int y,
        byte phase,
        int expected)
    {
        Assert.Equal(
            expected,
            PlasmaField.GetPaletteIndex(x, y, 128, 32, phase));
    }

    [Fact]
    public void GetPaletteIndex_RejectsCoordinatesOutsideMatrix()
    {
        Assert.Throws<ArgumentOutOfRangeException>(
            () => PlasmaField.GetPaletteIndex(-1, 0, 128, 32, 0));
        Assert.Throws<ArgumentOutOfRangeException>(
            () => PlasmaField.GetPaletteIndex(128, 0, 128, 32, 0));
    }
}
