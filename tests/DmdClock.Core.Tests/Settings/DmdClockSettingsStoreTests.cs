using DmdClock.Core.Settings;

namespace DmdClock.Core.Tests.Settings;

public sealed class DmdClockSettingsStoreTests
{
    [Fact]
    public void ExistingColorEnumValues_RemainSettingsCompatible()
    {
        Assert.Equal(4, (int)DmdColorPreset.NeonSunset);
        Assert.Equal(15, (int)DmdColorPreset.C64Rainbow);
        Assert.Equal(4, (int)PlasmaPalettePreset.Custom);
        Assert.Equal(2, (int)HotCoreStyle.DualColor);
        Assert.Equal(2, (int)DotDepthStyle.Deep);
    }

    [Theory]
    [InlineData(DmdColorPreset.NeonSunset)]
    [InlineData(DmdColorPreset.CyberOcean)]
    [InlineData(DmdColorPreset.ToxicArcade)]
    [InlineData(DmdColorPreset.Vaporwave)]
    [InlineData(DmdColorPreset.Aurora)]
    [InlineData(DmdColorPreset.Firestorm)]
    [InlineData(DmdColorPreset.ElectricViolet)]
    [InlineData(DmdColorPreset.ArcticGlow)]
    [InlineData(DmdColorPreset.C64BlueRound)]
    [InlineData(DmdColorPreset.C64RedRound)]
    [InlineData(DmdColorPreset.C64Earthtone)]
    [InlineData(DmdColorPreset.C64Metal)]
    [InlineData(DmdColorPreset.C64InterlacedBlue)]
    [InlineData(DmdColorPreset.C64ExtrudedCyan)]
    [InlineData(DmdColorPreset.C64Rainbow)]
    [InlineData(DmdColorPreset.C64PurpleHalo)]
    [InlineData(DmdColorPreset.RasterGreenHalo)]
    [InlineData(DmdColorPreset.RasterAmberHalo)]
    [InlineData(DmdColorPreset.RasterPurplePulse)]
    [InlineData(DmdColorPreset.RasterOceanDepth)]
    [InlineData(DmdColorPreset.RasterSunsetBands)]
    [InlineData(DmdColorPreset.RasterForestLayers)]
    [InlineData(DmdColorPreset.RasterArcticBands)]
    [InlineData(DmdColorPreset.RasterCandyStripe)]
    public void Normalize_PreservesMultiColorTheme(DmdColorPreset preset)
    {
        var normalized = (DmdClockSettings.Default with { ColorPreset = preset }).Normalize();
        Assert.Equal(preset, normalized.ColorPreset);
    }

    [Fact]
    public async Task SaveAndLoad_RoundTripsNormalizedSettings()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"dmdclock-settings-{Guid.NewGuid():N}");
        var path = Path.Combine(directory, "settings.json");
        var animationDirectory = Path.Combine(directory, "animations");
        var store = new DmdClockSettingsStore();
        try
        {
            var settings = new DmdClockSettings(
                1, true, true, 1, 99, 9999, DmdColorPreset.Plasma, 999, false, false, "sv", "12", "dd/MM/yyyy", false, false,
                "Inter/InterVariable.ttf", "../outside.otf", "#1a2b3c", "invalid", -100, 99999)
            {
                AnimationDirectory = animationDirectory,
                PlasmaPalette = PlasmaPalettePreset.Custom,
                PlasmaCustomColors = ["#102030", "#a0b0c0", "#445566", "#abcdef"],
                PlasmaCycleMilliseconds = 4_321,
                HotCoreEnabled = true,
                HotCoreStyle = HotCoreStyle.DualColor,
                HotCoreColor = "#ffeedd",
                DotDepth = DotDepthStyle.Deep
            };
            await store.SaveAtomicAsync(settings, path);
            var loaded = await store.LoadAsync(path);

            Assert.True(loaded.RandomPlayback);
            Assert.Equal(5, loaded.ClockDisplaySeconds);
            Assert.Equal(20, loaded.AnimationsPerCycle);
            Assert.Equal(3600, loaded.AnimationGapSeconds);
            Assert.Equal(DmdColorPreset.Plasma, loaded.ColorPreset);
            Assert.Equal(100, loaded.BrightnessPercent);
            Assert.False(loaded.GlowEnabled);
            Assert.False(loaded.ShowAnimationInfo);
            Assert.Equal("sv", loaded.Language);
            Assert.Equal("12", loaded.ClockFormat);
            Assert.Equal("dd/MM/yyyy", loaded.DateFormat);
            Assert.False(loaded.ShowSeconds);
            Assert.False(loaded.ShowTitleBar);
            Assert.Equal("Inter/InterVariable.ttf", loaded.ClockFontFile);
            Assert.Null(loaded.DateFontFile);
            Assert.Equal("#1A2B3C", loaded.ForegroundColor);
            Assert.Equal("#000000", loaded.BackgroundColor);
            Assert.Equal(5, loaded.WindowScalePercent);
            Assert.Equal(5000, loaded.FullscreenZoomPercent);
            Assert.Equal(Path.GetFullPath(animationDirectory), loaded.AnimationDirectory);
            Assert.Equal(PlasmaPalettePreset.Custom, loaded.PlasmaPalette);
            var customColors = Assert.IsType<string[]>(loaded.PlasmaCustomColors);
            Assert.Equal(
                ["#102030", "#A0B0C0", "#445566", "#ABCDEF"],
                customColors);
            Assert.Equal(4_250, loaded.PlasmaCycleMilliseconds);
            Assert.True(loaded.HotCoreEnabled);
            Assert.Equal(HotCoreStyle.DualColor, loaded.HotCoreStyle);
            Assert.Equal("#FFEEDD", loaded.HotCoreColor);
            Assert.Equal(DotDepthStyle.Deep, loaded.DotDepth);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void Normalize_InvalidHotCoreValues_UsesSafeClassicFlatDefaults()
    {
        var normalized = (DmdClockSettings.Default with
        {
            HotCoreEnabled = null,
            HotCoreStyle = (HotCoreStyle)999,
            HotCoreColor = "not-a-color",
            DotDepth = (DotDepthStyle)999
        }).Normalize();

        Assert.False(normalized.HotCoreEnabled);
        Assert.Equal(HotCoreStyle.Classic, normalized.HotCoreStyle);
        Assert.Equal("#FFF2B0", normalized.HotCoreColor);
        Assert.Equal(DotDepthStyle.Flat, normalized.DotDepth);
    }

    [Fact]
    public void HotCoreDefinition_AllSixteenLevelsStayMonotonic()
    {
        var opacities = Enumerable.Range(0, 16).Select(HotCoreDefinition.GetOpacity).ToArray();
        var radii = Enumerable.Range(0, 16).Select(HotCoreDefinition.GetRadiusFactor).ToArray();

        Assert.Equal(0, opacities[0]);
        Assert.Equal(1, opacities[^1], precision: 8);
        Assert.All(Enumerable.Range(1, 15), level =>
        {
            Assert.True(opacities[level] > opacities[level - 1]);
            Assert.True(radii[level] > radii[level - 1]);
        });
    }

    [Fact]
    public void Normalize_InvalidPlasmaPaletteFallsBackToNeon()
    {
        var settings = DmdClockSettings.Default with
        {
            PlasmaPalette = (PlasmaPalettePreset)999,
            PlasmaCustomColors = ["bad", "#112233"]
        };

        var normalized = settings.Normalize();

        Assert.Equal(PlasmaPalettePreset.Neon, normalized.PlasmaPalette);
        Assert.Equal(
            PlasmaPaletteDefinition.GetStops(PlasmaPalettePreset.Neon),
            normalized.PlasmaCustomColors);
    }

    [Theory]
    [InlineData(PlasmaPalettePreset.Neon)]
    [InlineData(PlasmaPalettePreset.Lava)]
    [InlineData(PlasmaPalettePreset.Ocean)]
    [InlineData(PlasmaPalettePreset.Aurora)]
    [InlineData(PlasmaPalettePreset.Toxic)]
    [InlineData(PlasmaPalettePreset.Vapor)]
    [InlineData(PlasmaPalettePreset.Solar)]
    [InlineData(PlasmaPalettePreset.Arctic)]
    public void PlasmaPaletteDefinition_ReturnsFourColorStops(PlasmaPalettePreset preset)
    {
        var colors = PlasmaPaletteDefinition.GetStops(preset);

        Assert.Equal(PlasmaPaletteDefinition.ColorStopCount, colors.Length);
        Assert.All(colors, color => Assert.Matches("^#[0-9A-F]{6}$", color));
    }

    [Theory]
    [InlineData(null, 8_000)]
    [InlineData(100, 1_000)]
    [InlineData(4_321, 4_250)]
    [InlineData(99_000, 60_000)]
    public void PlasmaSpeedDefinition_NormalizesForSharedIntegerTiming(
        int? value,
        int expected)
    {
        Assert.Equal(expected, PlasmaSpeedDefinition.Normalize(value));
    }

    [Fact]
    public void ThemeBackground_ChangesWithThemeWhenThemeModeIsSelected()
    {
        var settings = DmdClockSettings.Default with
        {
            ColorPreset = DmdColorPreset.NeonSunset,
            BackgroundMode = DmdBackgroundMode.Theme,
            BackgroundColor = "#123456"
        };

        Assert.Equal("#180020", DmdThemeBackgroundDefinition.Resolve(settings));
        Assert.Equal(
            "#220600",
            DmdThemeBackgroundDefinition.Resolve(settings with { ColorPreset = DmdColorPreset.Firestorm }));
    }

    [Fact]
    public void CustomBackground_IsPreservedAcrossThemeChanges()
    {
        var settings = DmdClockSettings.Default with
        {
            ColorPreset = DmdColorPreset.NeonSunset,
            BackgroundMode = DmdBackgroundMode.Custom,
            BackgroundColor = "#123456"
        };

        Assert.Equal("#123456", DmdThemeBackgroundDefinition.Resolve(settings));
        Assert.Equal(
            "#123456",
            DmdThemeBackgroundDefinition.Resolve(settings with { ColorPreset = DmdColorPreset.C64Rainbow }));
    }

    [Fact]
    public void BlackBackground_RemainsBlackAcrossThemeChanges()
    {
        var settings = DmdClockSettings.Default with
        {
            ColorPreset = DmdColorPreset.Plasma,
            BackgroundMode = DmdBackgroundMode.Black,
            BackgroundColor = "#123456"
        };

        Assert.Equal("#000000", DmdThemeBackgroundDefinition.Resolve(settings));
    }

    [Fact]
    public async Task Load_OlderSchemaOneFileWithoutAnimationGap_UsesNoGap()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"dmdclock-settings-{Guid.NewGuid():N}");
        var path = Path.Combine(directory, "settings.json");
        Directory.CreateDirectory(directory);
        try
        {
            await File.WriteAllTextAsync(path,
                """{"schemaVersion":1,"automaticCycle":true,"randomPlayback":false,"clockDisplaySeconds":30,"animationsPerCycle":3}""");

            var loaded = await new DmdClockSettingsStore().LoadAsync(path);

            Assert.Equal(0, loaded.AnimationGapSeconds);
            Assert.Equal(3, loaded.AnimationsPerCycle);
            Assert.Equal(DmdColorPreset.Orange, loaded.ColorPreset);
            Assert.Equal(100, loaded.BrightnessPercent);
            Assert.True(loaded.GlowEnabled);
            Assert.True(loaded.ShowAnimationInfo);
            Assert.Equal("en", loaded.Language);
            Assert.Equal("24", loaded.ClockFormat);
            Assert.Equal("yyyy-MM-dd", loaded.DateFormat);
            Assert.True(loaded.ShowSeconds);
            Assert.True(loaded.ShowTitleBar);
            Assert.Null(loaded.ForegroundColor);
            Assert.Equal("#000000", loaded.BackgroundColor);
            Assert.Equal(100, loaded.WindowScalePercent);
            Assert.Equal(100, loaded.FullscreenZoomPercent);
            Assert.Null(loaded.AnimationDirectory);
            Assert.False(loaded.HotCoreEnabled);
            Assert.Equal(HotCoreStyle.Classic, loaded.HotCoreStyle);
            Assert.Equal("#FFF2B0", loaded.HotCoreColor);
            Assert.Equal(DotDepthStyle.Flat, loaded.DotDepth);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }
}
