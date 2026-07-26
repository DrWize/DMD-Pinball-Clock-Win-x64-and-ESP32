using System.Globalization;

namespace DmdClock.Core.Settings;

public enum DmdColorPreset
{
    Orange,
    Red,
    Plasma,
    Monochrome,
    NeonSunset,
    CyberOcean,
    ToxicArcade,
    Vaporwave,
    Aurora,
    C64BlueRound,
    C64RedRound,
    C64Earthtone,
    C64Metal,
    C64InterlacedBlue,
    C64ExtrudedCyan,
    C64Rainbow
}

public enum PlasmaPalettePreset
{
    Neon,
    Lava,
    Ocean,
    Aurora,
    Custom
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
    int? PlasmaCycleMilliseconds = null)
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
        PlasmaCycleMilliseconds = PlasmaSpeedDefinition.Normalize(PlasmaCycleMilliseconds)
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
