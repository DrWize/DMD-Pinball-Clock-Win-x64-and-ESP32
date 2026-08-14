using DmdClock.App.Rendering;
using DmdClock.Core.Scn;
using System.Security.Cryptography;

namespace DmdClock.Core.Tests.Rendering;

public sealed class EmbeddedDotClkFontsTests
{
    public static TheoryData<string, string, string> Esp32GoldenFrames => new()
    {
        { "DotClk/ALTERN8.fnt", "23:59:58", "ED44FBAA9D94C8E7E50BF6024AF5F47690352EC82D2EA418CC80643458BD0C27" },
        { "DotClk/ALTERN8.fnt", "11:59:58 PM", "2EFE00CC367DA06D1EAE00171E81A688EC419F3A2F1C6AA20FC75EA2F1633CD6" },
        { "DotClk/ALTERN8.fnt", "2026-07/23.", "9E0C6487FE8F1B01D7077F214CCF994C93AB488804EAC7231BFBC1C4606FEF3E" },
        { "DotClk/ALTERN8.fnt", "2?3", "A4D45B72CA85A8A3C741D40D97C8FD7393B4EBABE6171F2E042C64A9DBC47A26" },
        { "DotClk/FISHY.fnt", "23:59:58", "5CC14E5C7B87FA3C800EF5A1B677474364A72C2A7FD6045403D8A6010DCF7E00" },
        { "DotClk/FISHY.fnt", "11:59:58 PM", "04925F1C0369FCC61B2E69C0AA2763DF2CF347A86B842AB116882390A15975DA" },
        { "DotClk/FISHY.fnt", "2026-07/23.", "309E4004A92D8733F4E2A61F75D182C7BB0B42101181B8A005BDEF274D7C574F" },
        { "DotClk/FISHY.fnt", "2?3", "D7122F5D8B5C4F7FA873D6C77583449E252408E658731FAD5A0A64DE9E49D2E4" },
        { "DotClk/TREK.fnt", "23:59:58", "719E9F585413BEB71E19961E1C78860CE780D69AF919393C36405398EA76425C" },
        { "DotClk/TREK.fnt", "11:59:58 PM", "48CD334ABAB402A66298E6F2F0D2084AC8DC073E6136A42EA529092725F59E48" },
        { "DotClk/TREK.fnt", "2026-07/23.", "52A458B50585E2828BC52684F157E8EBC28A4AB3471E640EB302F14CF59B327F" },
        { "DotClk/TREK.fnt", "2?3", "559761392418F286B059C1DBC7971567FA4EB05ABD13EFB3D26653D186A7EA50" },
        { "DotClk/TWILIGHT.fnt", "23:59:58", "55D3C75EAE2A583698EF77ECE9FCC8A959FCF3DC22E551EA71E910584DD5E5BC" },
        { "DotClk/TWILIGHT.fnt", "11:59:58 PM", "8F06834079449A6181460C464375E71F662D7ACF4A0852704359494F636F6A65" },
        { "DotClk/TWILIGHT.fnt", "2026-07/23.", "CBBA354466DCF5665A44FBFDF7F2B05996761F46AC6345A8AD8C9198919E754F" },
        { "DotClk/TWILIGHT.fnt", "2?3", "A422FC7CF3160A7DD87D4AC7739C2970FBD90D7A549F4AA0720189E981AD8032" },
    };

    public static TheoryData<string> Fonts
    {
        get
        {
            var data = new TheoryData<string>();
            foreach (var id in EmbeddedDotClkFonts.Ids) data.Add(id);
            return data;
        }
    }

    public static TheoryData<string, string> DateSamples
    {
        get
        {
            var data = new TheoryData<string, string>();
            foreach (var id in EmbeddedDotClkFonts.Ids)
            foreach (var text in new[] { "2026-07-23", "23/07/2026", "07/23/2026", "23.07.2026" })
                data.Add(id, text);
            return data;
        }
    }

    [Theory]
    [MemberData(nameof(Fonts))]
    public void Create_RendersTwentyFourAndTwelveHourTime(string id)
    {
        AssertUsableFrame(EmbeddedDotClkFonts.Create("23:59:58", id));
        AssertUsableFrame(EmbeddedDotClkFonts.Create("11:59:58 PM", id));
    }

    [Theory]
    [MemberData(nameof(DateSamples))]
    public void Create_RendersEveryDateFormat(string id, string text)
    {
        AssertUsableFrame(EmbeddedDotClkFonts.Create(text, id));
    }

    [Theory]
    [MemberData(nameof(Esp32GoldenFrames))]
    public void Create_MatchesEsp32IntensityAndMaskGolden(
        string id,
        string text,
        string expected)
    {
        var frame = EmbeddedDotClkFonts.Create(text, id);
        var intensities = frame.Intensities.ToArray();
        var mask = Assert.IsType<ReadOnlyMemory<byte>>(frame.Mask).ToArray();
        Assert.Equal(expected, Convert.ToHexString(SHA256.HashData([.. intensities, .. mask])));
    }

    private static void AssertUsableFrame(DmdClock.Core.DmdFrame frame)
    {
        Assert.Equal(ScnReader.DisplayWidth, frame.Width);
        Assert.Equal(ScnReader.DisplayHeight, frame.Height);
        Assert.Contains(frame.Intensities.ToArray(), intensity => intensity > 0);
        Assert.All(frame.Intensities.ToArray(), intensity => Assert.InRange(intensity, (byte)0, (byte)15));
        Assert.NotNull(frame.Mask);
    }
}
