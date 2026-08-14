using DmdClock.Core.Clock;
using System.Security.Cryptography;

namespace DmdClock.Core.Tests.Clock;

public sealed class ClockFrameFactoryTests
{
    [Theory]
    [InlineData(false, true, "FC47F8CC3CED7E870ADF2AC52D7E23109C9A01A1E344DB2432DDEFB0F368BC25")]
    [InlineData(false, false, "ABECE4848BA4C57FF4812D79FCB15ECBEE598DD4C3F6B2EF235B4962B8DD8E2A")]
    [InlineData(true, true, "93E4D1B572DEFFB991AC624ACE838117C71070947EB97AC62861CA6DC1A4BE98")]
    [InlineData(true, false, "ADEF70163A4B7A491D278886E8EA3A84CCDED93B3A2724914502554AAAB337FF")]
    public void Create_MatchesEsp32IntensityAndMaskGolden(
        bool twelveHour,
        bool showSeconds,
        string expected)
    {
        var time = new DateTimeOffset(2026, 8, 14, 23, 59, 58, TimeSpan.Zero);
        Assert.Equal(expected, FrameHash(ClockFrameFactory.Create(time, twelveHour, showSeconds)));
    }

    [Fact]
    public void CreateCompactTime_MatchesEsp32ClippedGolden()
    {
        var time = new DateTimeOffset(2026, 8, 14, 23, 59, 58, TimeSpan.Zero);
        Assert.Equal(
            "8B9603CD213E4F33282E9DA100781C255B662A415970A3BD353FA4BF16FCB93F",
            FrameHash(ClockFrameFactory.CreateCompactTime(time, 20, 10, twelveHour: true)));
    }

    [Fact]
    public void Create_ProducesValidDmdFrame()
    {
        var frame = ClockFrameFactory.Create(new DateTimeOffset(2026, 7, 22, 23, 45, 59, TimeSpan.Zero));

        Assert.Equal(128, frame.Width);
        Assert.Equal(32, frame.Height);
        Assert.Equal(128 * 32, frame.Intensities.Length);
        Assert.Contains((byte)15, frame.Intensities.ToArray());
        Assert.All(frame.Intensities.ToArray(), static value => Assert.InRange(value, (byte)0, (byte)15));
    }

    [Fact]
    public void CreateDate_ProducesValidDmdFrame()
    {
        var frame = ClockFrameFactory.CreateDate(new DateTimeOffset(2026, 7, 22, 23, 45, 59, TimeSpan.Zero));

        Assert.Equal(128, frame.Width);
        Assert.Equal(32, frame.Height);
        Assert.Contains((byte)15, frame.Intensities.ToArray());
    }

    [Theory]
    [InlineData("yyyy-MM-dd")]
    [InlineData("dd/MM/yyyy")]
    [InlineData("MM/dd/yyyy")]
    [InlineData("dd.MM.yyyy")]
    public void CreateDate_SupportsCommonFormats(string format)
    {
        var frame = ClockFrameFactory.CreateDate(new DateTimeOffset(2026, 7, 23, 13, 5, 9, TimeSpan.Zero), format);
        Assert.Contains((byte)15, frame.Intensities.ToArray());
    }

    [Fact]
    public void Create_SupportsTwelveHourClock()
    {
        var frame = ClockFrameFactory.Create(new DateTimeOffset(2026, 7, 23, 13, 5, 9, TimeSpan.Zero), twelveHour: true);
        Assert.Contains((byte)15, frame.Intensities.ToArray());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Create_CanHideSecondsInBothClockFormats(bool twelveHour)
    {
        var frame = ClockFrameFactory.Create(
            new DateTimeOffset(2026, 7, 23, 13, 5, 9, TimeSpan.Zero),
            twelveHour,
            showSeconds: false);

        Assert.Equal(128, frame.Width);
        Assert.Equal(32, frame.Height);
        Assert.Contains((byte)15, frame.Intensities.ToArray());
    }

    [Fact]
    public void CreateInformation_HandlesLongNamesAndSwedishCharacters()
    {
        var frame = ClockFrameFactory.CreateInformation(
            "Indiana Jones: The Pinball Adventure",
            "Återkomst från templet – sekvens 123");

        Assert.Equal(128, frame.Width);
        Assert.Equal(32, frame.Height);
        Assert.Equal(128 * 32, frame.Intensities.Length);
        Assert.Contains((byte)15, frame.Intensities.ToArray());
    }

    [Fact]
    public void CreateInformation_UsesFallbackTextForMissingMetadata()
    {
        var frame = ClockFrameFactory.CreateInformation(null, " ");

        Assert.Contains((byte)15, frame.Intensities.ToArray());
    }

    private static string FrameHash(DmdFrame frame)
    {
        var intensities = frame.Intensities.ToArray();
        var mask = Assert.IsType<ReadOnlyMemory<byte>>(frame.Mask).ToArray();
        return Convert.ToHexString(SHA256.HashData([.. intensities, .. mask]));
    }
}
