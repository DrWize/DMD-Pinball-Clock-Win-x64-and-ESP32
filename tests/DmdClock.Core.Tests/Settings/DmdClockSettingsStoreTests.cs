using DmdClock.Core.Settings;

namespace DmdClock.Core.Tests.Settings;

public sealed class DmdClockSettingsStoreTests
{
    [Theory]
    [InlineData(DmdColorPreset.NeonSunset)]
    [InlineData(DmdColorPreset.CyberOcean)]
    [InlineData(DmdColorPreset.ToxicArcade)]
    [InlineData(DmdColorPreset.Vaporwave)]
    [InlineData(DmdColorPreset.Aurora)]
    [InlineData(DmdColorPreset.C64BlueRound)]
    [InlineData(DmdColorPreset.C64RedRound)]
    [InlineData(DmdColorPreset.C64Earthtone)]
    [InlineData(DmdColorPreset.C64Metal)]
    [InlineData(DmdColorPreset.C64InterlacedBlue)]
    [InlineData(DmdColorPreset.C64ExtrudedCyan)]
    [InlineData(DmdColorPreset.C64Rainbow)]
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
                PlasmaCycleMilliseconds = 4_321
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
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
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
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }
}
