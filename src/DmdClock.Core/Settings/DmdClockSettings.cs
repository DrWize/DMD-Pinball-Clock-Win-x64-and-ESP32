using System.Globalization;

namespace DmdClock.Core.Settings;

public enum DmdColorPreset
{
    Orange = 0,
    Red = 1,
    Plasma = 2,
    Monochrome = 3,
    NeonSunset = 4,
    CyberOcean = 5,
    ToxicArcade = 6,
    Vaporwave = 7,
    Aurora = 8,
    C64BlueRound = 9,
    C64RedRound = 10,
    C64Earthtone = 11,
    C64Metal = 12,
    C64InterlacedBlue = 13,
    C64ExtrudedCyan = 14,
    C64Rainbow = 15,
    Amber = 16,
    Green = 17,
    Blue = 18,
    Cyan = 19,
    Magenta = 20,
    Firestorm = 21,
    ElectricViolet = 22,
    ArcticGlow = 23,
    C64PurpleHalo = 24,
    RasterGreenHalo = 25,
    RasterAmberHalo = 26,
    RasterPurplePulse = 27,
    RasterOceanDepth = 28,
    RasterSunsetBands = 29,
    RasterForestLayers = 30,
    RasterArcticBands = 31,
    RasterCandyStripe = 32
}

public enum PlasmaPalettePreset
{
    Neon = 0,
    Lava = 1,
    Ocean = 2,
    Aurora = 3,
    Custom = 4,
    Toxic = 5,
    Vapor = 6,
    Solar = 7,
    Arctic = 8
}

public enum DmdBackgroundMode
{
    Theme,
    Black,
    Custom
}

public enum HotCoreStyle
{
    Classic,
    Theme,
    DualColor
}

public enum DotDepthStyle
{
    Flat,
    Subtle,
    Deep
}

public static class HotCoreDefinition
{
    public static double GetOpacity(int intensity) =>
        Math.Pow(Math.Clamp(intensity, 0, 15) / 15d, 1.35);

    public static double GetRadiusFactor(int intensity) =>
        0.22 + (0.10 * Math.Clamp(intensity, 0, 15) / 15d);
}

public sealed record DmdClockSettings(
    int SchemaVersion,
    bool AutomaticCycle,
    bool RandomPlayback,
    int ClockDisplaySeconds,
    int AnimationsPerCycle,
    int AnimationGapSeconds,
    DmdColorPreset? ColorPreset,
    int? BrightnessPercent,
    bool? GlowEnabled,
    bool? ShowAnimationInfo,
    string? Language,
    string? ClockFormat,
    string? DateFormat,
    bool? ShowSeconds,
    bool? ShowTitleBar,
    string? ClockFontFile,
    string? DateFontFile,
    string? ForegroundColor,
    string? BackgroundColor,
    int? WindowScalePercent,
    int? FullscreenZoomPercent,
    string? AnimationDirectory = null,
    PlasmaPalettePreset? PlasmaPalette = null,
    string[]? PlasmaCustomColors = null,
    int? PlasmaCycleMilliseconds = null,
    DmdBackgroundMode? BackgroundMode = null,
    bool? HotCoreEnabled = null,
    HotCoreStyle? HotCoreStyle = null,
    string? HotCoreColor = null,
    DotDepthStyle? DotDepth = null)
{
    public const int CurrentSchemaVersion = 1;

    public static DmdClockSettings Default { get; } = new(
        CurrentSchemaVersion, true, false, 30, 1, 0, DmdColorPreset.Orange, 100, true, true, "en", "24", "yyyy-MM-dd", true, true, null, null, null, "#000000", 100, 100);

    public DmdClockSettings Normalize() => this with
    {
        SchemaVersion = CurrentSchemaVersion,
        ClockDisplaySeconds = Math.Clamp(ClockDisplaySeconds, 5, 3600),
        AnimationsPerCycle = Math.Clamp(AnimationsPerCycle, 1, 20),
        AnimationGapSeconds = Math.Clamp(AnimationGapSeconds, 0, 3600),
        ColorPreset = ColorPreset is { } preset && Enum.IsDefined(preset) ? preset : DmdColorPreset.Orange,
        BrightnessPercent = Math.Clamp(BrightnessPercent ?? 100, 25, 100),
        GlowEnabled = GlowEnabled ?? true,
        ShowAnimationInfo = ShowAnimationInfo ?? true,
        Language = Language is "sv" ? "sv" : "en",
        ClockFormat = ClockFormat is "12" ? "12" : "24",
        DateFormat = DateFormat is "dd/MM/yyyy" or "MM/dd/yyyy" or "dd.MM.yyyy" ? DateFormat : "yyyy-MM-dd",
        ShowSeconds = ShowSeconds ?? true,
        ShowTitleBar = ShowTitleBar ?? true,
        ClockFontFile = NormalizeFontFile(ClockFontFile),
        DateFontFile = NormalizeFontFile(DateFontFile),
        ForegroundColor = NormalizeColor(ForegroundColor),
        BackgroundColor = NormalizeColor(BackgroundColor) ?? "#000000",
        WindowScalePercent = NormalizeScale(WindowScalePercent),
        FullscreenZoomPercent = NormalizeScale(FullscreenZoomPercent),
        AnimationDirectory = NormalizeDirectory(AnimationDirectory),
        PlasmaPalette = PlasmaPalette is { } plasmaPalette && Enum.IsDefined(plasmaPalette)
            ? plasmaPalette
            : PlasmaPalettePreset.Neon,
        PlasmaCustomColors = NormalizePlasmaColors(PlasmaCustomColors),
        PlasmaCycleMilliseconds = PlasmaSpeedDefinition.Normalize(PlasmaCycleMilliseconds),
        BackgroundMode = BackgroundMode is { } backgroundMode && Enum.IsDefined(backgroundMode)
            ? backgroundMode
            : InferBackgroundMode(),
        HotCoreEnabled = HotCoreEnabled ?? false,
        HotCoreStyle = HotCoreStyle is { } hotCoreStyle && Enum.IsDefined(hotCoreStyle)
            ? hotCoreStyle
            : global::DmdClock.Core.Settings.HotCoreStyle.Classic,
        HotCoreColor = NormalizeColor(HotCoreColor) ?? "#FFF2B0",
        DotDepth = DotDepth is { } dotDepth && Enum.IsDefined(dotDepth)
            ? dotDepth
            : DotDepthStyle.Flat
    };

    private static string? NormalizeFontFile(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var normalized = value.Trim().Replace('\\', '/').TrimStart('/');
        return normalized.Split('/').Any(part => part is ".." or "") ? null : normalized;
    }

    private static string? NormalizeColor(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var normalized = value.Trim();
        if (normalized.Length != 7 || normalized[0] != '#' ||
            !uint.TryParse(normalized.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out _))
            return null;
        return normalized.ToUpperInvariant();
    }

    private static int NormalizeScale(int? value)
    {
        var clamped = Math.Clamp(value ?? 100, 5, 5000);
        return (int)Math.Round(clamped / 5d) * 5;
    }

    private static string? NormalizeDirectory(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        try
        {
            return Path.IsPathFullyQualified(value.Trim())
                ? Path.GetFullPath(value.Trim())
                : null;
        }
        catch (Exception exception) when (
            exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return null;
        }
    }

    private static string[] NormalizePlasmaColors(string[]? colors)
    {
        var fallback = PlasmaPaletteDefinition.GetStops(PlasmaPalettePreset.Neon);
        if (colors is not { Length: PlasmaPaletteDefinition.ColorStopCount })
            return fallback;

        var normalized = colors.Select(NormalizeColor).ToArray();
        return normalized.All(static color => color is not null)
            ? normalized.Select(static color => color!).ToArray()
            : fallback;
    }

    private DmdBackgroundMode InferBackgroundMode() =>
        !string.IsNullOrWhiteSpace(BackgroundColor) &&
        !string.Equals(BackgroundColor, "#000000", StringComparison.OrdinalIgnoreCase)
            ? DmdBackgroundMode.Custom
            : DmdBackgroundMode.Theme;
}

public static class PlasmaPaletteDefinition
{
    public const int ColorStopCount = 4;

    public static string[] GetStops(
        PlasmaPalettePreset preset,
        IReadOnlyList<string>? customColors = null) => preset switch
    {
        PlasmaPalettePreset.Lava => ["#4A0010", "#E02020", "#FF7A00", "#FFE060"],
        PlasmaPalettePreset.Ocean => ["#001040", "#0055D8", "#00C8FF", "#B8FFFF"],
        PlasmaPalettePreset.Aurora => ["#180050", "#7A38FF", "#20E8A0", "#D8FF70"],
        PlasmaPalettePreset.Toxic => ["#082A12", "#16A34A", "#A3FF12", "#F5FF75"],
        PlasmaPalettePreset.Vapor => ["#24005E", "#7A38FF", "#FF41DC", "#41E9FF"],
        PlasmaPalettePreset.Solar => ["#3D0500", "#D82900", "#FF8A00", "#FFF0A0"],
        PlasmaPalettePreset.Arctic => ["#001B3D", "#0077B6", "#48CAE4", "#E0FBFF"],
        PlasmaPalettePreset.Custom when customColors is { Count: ColorStopCount } =>
            customColors.ToArray(),
        _ => ["#2D0C6E", "#3250FF", "#1EEBFF", "#FF41DC"]
    };
}

public static class PlasmaSpeedDefinition
{
    public const int MinimumCycleMilliseconds = 1_000;
    public const int MaximumCycleMilliseconds = 60_000;
    public const int DefaultCycleMilliseconds = 8_000;
    public const int StepMilliseconds = 250;

    public static int Normalize(int? milliseconds)
    {
        var clamped = Math.Clamp(
            milliseconds ?? DefaultCycleMilliseconds,
            MinimumCycleMilliseconds,
            MaximumCycleMilliseconds);
        return (int)Math.Round(clamped / (double)StepMilliseconds) * StepMilliseconds;
    }
}

public static class DmdThemeBackgroundDefinition
{
    public static string GetColor(
        DmdColorPreset preset,
        PlasmaPalettePreset plasmaPalette = PlasmaPalettePreset.Neon) => preset switch
    {
        DmdColorPreset.Orange => "#140700",
        DmdColorPreset.Amber => "#140D00",
        DmdColorPreset.Red => "#160200",
        DmdColorPreset.Green => "#031408",
        DmdColorPreset.Blue => "#030916",
        DmdColorPreset.Cyan => "#001216",
        DmdColorPreset.Magenta => "#160313",
        DmdColorPreset.Monochrome => "#0A0A0A",
        DmdColorPreset.Plasma => plasmaPalette switch
        {
            PlasmaPalettePreset.Lava => "#160200",
            PlasmaPalettePreset.Ocean => "#001020",
            PlasmaPalettePreset.Aurora => "#080020",
            PlasmaPalettePreset.Toxic => "#020C05",
            PlasmaPalettePreset.Vapor => "#100022",
            PlasmaPalettePreset.Solar => "#130200",
            PlasmaPalettePreset.Arctic => "#001018",
            _ => "#100022"
        },
        DmdColorPreset.NeonSunset => "#180020",
        DmdColorPreset.CyberOcean => "#001528",
        DmdColorPreset.ToxicArcade => "#071B0F",
        DmdColorPreset.Vaporwave => "#160B2D",
        DmdColorPreset.Aurora => "#061A2B",
        DmdColorPreset.Firestorm => "#220600",
        DmdColorPreset.ElectricViolet => "#0D0624",
        DmdColorPreset.ArcticGlow => "#00161F",
        _ => "#000000"
    };

    public static string Resolve(DmdClockSettings settings)
    {
        var mode = settings.BackgroundMode ?? DmdBackgroundMode.Theme;
        return mode switch
        {
            DmdBackgroundMode.Black => "#000000",
            DmdBackgroundMode.Custom => settings.BackgroundColor ?? "#000000",
            _ => GetColor(
                settings.ColorPreset ?? DmdColorPreset.Orange,
                settings.PlasmaPalette ?? PlasmaPalettePreset.Neon)
        };
    }
}
