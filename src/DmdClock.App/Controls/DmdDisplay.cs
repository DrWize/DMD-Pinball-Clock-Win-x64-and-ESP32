using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using DmdClock.Core;
using DmdClock.Core.Rendering;
using DmdClock.Core.Settings;

namespace DmdClock.App.Controls;

public sealed class DmdDisplay : Control
{
    private const int PaletteColumns = 128;
    private IBrush[][] _dotBrushes = [];
    private IBrush[][] _glowBrushes = [];
    private DmdFrame? _frame;
    private bool _glowEnabled = true;
    private IBrush _backgroundBrush = Brushes.Black;
    private bool _paletteByRow;
    private bool _plasmaEnabled;
    private byte _plasmaPhase;
    private int _plasmaCycleMilliseconds = PlasmaSpeedDefinition.DefaultCycleMilliseconds;

    private double _zoom = 1d;

    public DmdDisplay()
    {
        ClipToBounds = true;
        SetAppearance(DmdColorPreset.Orange, 100, true, null, "#000000");
    }

    public double Zoom
    {
        get => _zoom;
        set
        {
            _zoom = Math.Clamp(value, 0.05, 50d);
            InvalidateVisual();
        }
    }

    public void SetAppearance(
        DmdColorPreset preset,
        int brightnessPercent,
        bool glowEnabled,
        string? foregroundColor,
        string? backgroundColor,
        PlasmaPalettePreset plasmaPalette = PlasmaPalettePreset.Neon,
        IReadOnlyList<string>? plasmaCustomColors = null,
        int plasmaCycleMilliseconds = PlasmaSpeedDefinition.DefaultCycleMilliseconds)
    {
        brightnessPercent = Math.Clamp(brightnessPercent, 25, 100);
        var palette = preset switch
        {
            DmdColorPreset.Red => Solid(Color.FromRgb(255, 32, 16)),
            DmdColorPreset.Plasma => PlasmaPalette(plasmaPalette, plasmaCustomColors),
            DmdColorPreset.Monochrome => Solid(Color.FromRgb(235, 235, 235)),
            DmdColorPreset.Amber => Solid(Color.FromRgb(255, 176, 0)),
            DmdColorPreset.Green => Solid(Color.FromRgb(57, 255, 90)),
            DmdColorPreset.Blue => Solid(Color.FromRgb(58, 123, 255)),
            DmdColorPreset.Cyan => Solid(Color.FromRgb(37, 230, 255)),
            DmdColorPreset.Magenta => Solid(Color.FromRgb(255, 63, 203)),
            DmdColorPreset.NeonSunset => Gradient(Color.FromRgb(255, 43, 214), Color.FromRgb(255, 209, 102)),
            DmdColorPreset.CyberOcean => Gradient(Color.FromRgb(38, 123, 255), Color.FromRgb(94, 255, 255)),
            DmdColorPreset.ToxicArcade => Gradient(Color.FromRgb(46, 255, 106), Color.FromRgb(245, 255, 87)),
            DmdColorPreset.Vaporwave => Gradient(Color.FromRgb(138, 77, 255), Color.FromRgb(255, 92, 225)),
            DmdColorPreset.Aurora => Gradient(Color.FromRgb(52, 255, 190), Color.FromRgb(180, 112, 255)),
            DmdColorPreset.Firestorm => Gradient(Color.FromRgb(255, 50, 24), Color.FromRgb(255, 210, 63)),
            DmdColorPreset.ElectricViolet => Gradient(Color.FromRgb(79, 70, 229), Color.FromRgb(255, 53, 200)),
            DmdColorPreset.ArcticGlow => Gradient(Color.FromRgb(32, 207, 255), Color.FromRgb(232, 255, 255)),
            DmdColorPreset.C64BlueRound => Raster(C64Blue, C64LightBlue, C64Cyan, C64White, C64Cyan, C64LightBlue, C64Blue),
            DmdColorPreset.C64RedRound => Raster(C64Red, C64LightRed, C64Orange, C64Yellow, C64White, C64Yellow, C64Orange, C64LightRed, C64Red),
            DmdColorPreset.C64Earthtone => Raster(C64Brown, C64Red, C64Orange, C64LightRed, C64Yellow, C64LightRed, C64Orange, C64Red, C64Brown),
            DmdColorPreset.C64Metal => Raster(C64DarkGray, C64Gray, C64LightGray, C64White, C64LightGray, C64Gray, C64DarkGray),
            DmdColorPreset.C64InterlacedBlue => Raster(C64Blue, C64LightBlue, C64Blue, C64Cyan, C64Blue, C64White, C64Blue, C64Cyan, C64Blue, C64LightBlue, C64Blue),
            DmdColorPreset.C64ExtrudedCyan => Raster(C64Blue, C64Cyan, C64White, C64Cyan, C64Blue, C64LightBlue, C64Blue, C64Cyan, C64LightBlue, C64Cyan, C64Blue),
            DmdColorPreset.C64Rainbow => Raster(C64Red, C64Orange, C64Yellow, C64LightGreen, C64Green, C64Cyan, C64LightBlue, C64Blue, C64Purple, C64LightRed),
            DmdColorPreset.C64PurpleHalo => Raster(C64Blue, C64Purple, C64LightRed, C64White, C64LightRed, C64Purple, C64Blue),
            DmdColorPreset.RasterGreenHalo => Raster(C64Green, C64LightGreen, C64Yellow, C64White, C64Yellow, C64LightGreen, C64Green),
            DmdColorPreset.RasterAmberHalo => Raster(C64Brown, C64Orange, C64Yellow, C64White, C64Yellow, C64Orange, C64Brown),
            DmdColorPreset.RasterPurplePulse => Raster(C64Purple, C64LightRed, C64Purple, C64White, C64Purple, C64LightRed, C64Purple),
            DmdColorPreset.RasterOceanDepth => Raster(C64Blue, C64LightBlue, C64Cyan, C64LightBlue, C64White, C64LightBlue, C64Cyan, C64Blue),
            DmdColorPreset.RasterSunsetBands => Raster(C64Purple, C64Red, C64LightRed, C64Orange, C64Yellow, C64LightRed, C64Red),
            DmdColorPreset.RasterForestLayers => Raster(C64Brown, C64Green, C64LightGreen, C64Yellow, C64LightGreen, C64Green, C64Brown),
            DmdColorPreset.RasterArcticBands => Raster(C64Blue, C64Cyan, C64LightGray, C64White, C64LightGray, C64Cyan, C64Blue),
            DmdColorPreset.RasterCandyStripe => Raster(C64Red, C64LightRed, C64White, C64Cyan, C64White, C64LightRed, C64Purple),
            _ => Solid(Color.FromRgb(255, 112, 14))
        };
        _plasmaEnabled = preset == DmdColorPreset.Plasma &&
            string.IsNullOrWhiteSpace(foregroundColor);
        _plasmaCycleMilliseconds = PlasmaSpeedDefinition.Normalize(plasmaCycleMilliseconds);
        _paletteByRow = IsC64RasterPreset(preset);
        if (!string.IsNullOrWhiteSpace(foregroundColor))
        {
            palette = Solid(ParseColor(foregroundColor, palette[^1]));
            _paletteByRow = false;
        }
        _backgroundBrush = new SolidColorBrush(ParseColor(backgroundColor, Colors.Black));
        _dotBrushes = Enumerable.Range(0, PaletteColumns)
            .Select(column => CreateDotBrushes(
                palette[column], brightnessPercent / 100d))
            .ToArray();
        _glowBrushes = Enumerable.Range(0, PaletteColumns)
            .Select(column => CreateGlowBrushes(
                palette[column], brightnessPercent / 100d))
            .ToArray();
        _glowEnabled = glowEnabled;
        InvalidateVisual();
    }

    public void SetEffectTime(long elapsedMilliseconds)
    {
        if (!_plasmaEnabled)
            return;

        var phase = PlasmaField.PhaseAtMilliseconds(
            elapsedMilliseconds,
            _plasmaCycleMilliseconds);
        if (phase == _plasmaPhase)
            return;

        _plasmaPhase = phase;
        InvalidateVisual();
    }

    public DmdFrame? Frame
    {
        get => _frame;
        set
        {
            _frame = value;
            InvalidateVisual();
        }
    }

    public override void Render(DrawingContext context)
    {
        base.Render(context);
        context.FillRectangle(_backgroundBrush, Bounds);

        var frame = Frame;
        if (frame is null)
            return;

        var cellSize = Math.Min(Bounds.Width / frame.Width, Bounds.Height / frame.Height) * Zoom;
        var displayWidth = cellSize * frame.Width;
        var displayHeight = cellSize * frame.Height;
        var originX = (Bounds.Width - displayWidth) / 2;
        var originY = (Bounds.Height - displayHeight) / 2;
        var radius = cellSize * 0.34;
        var glowRadius = cellSize * 0.47;
        var pixels = frame.Intensities.Span;

        for (var y = 0; y < frame.Height; y++)
        for (var x = 0; x < frame.Width; x++)
        {
            var intensity = pixels[(y * frame.Width) + x];
            if (intensity == 0)
                continue;

            var center = new Point(originX + ((x + 0.5) * cellSize), originY + ((y + 0.5) * cellSize));
            int paletteColumn;
            if (_plasmaEnabled)
            {
                paletteColumn = PlasmaField.GetPaletteIndex(
                    x, y, frame.Width, frame.Height, _plasmaPhase);
            }
            else
            {
                var paletteCoordinate = _paletteByRow ? y : x;
                var paletteExtent = _paletteByRow ? frame.Height : frame.Width;
                paletteColumn = Math.Clamp(
                    (paletteCoordinate * PaletteColumns) / paletteExtent,
                    0,
                    PaletteColumns - 1);
            }
            if (_glowEnabled)
                context.DrawEllipse(_glowBrushes[paletteColumn][intensity], null, center, glowRadius, glowRadius);
            context.DrawEllipse(_dotBrushes[paletteColumn][intensity], null, center, radius, radius);
        }
    }

    private static IBrush[] CreateDotBrushes(Color color, double brightness) => Enumerable.Range(0, 16)
        .Select(level =>
        {
            var amount = level / 15d;
            var factor = (0.12 + (0.88 * amount)) * brightness;
            return (IBrush)new SolidColorBrush(Color.FromRgb(
                Scale(color.R, factor),
                Scale(color.G, factor),
                Scale(color.B, factor)));
        })
        .ToArray();

    private static IBrush[] CreateGlowBrushes(Color color, double brightness) => Enumerable.Range(0, 16)
        .Select(level => (IBrush)new SolidColorBrush(Color.FromArgb(
            Scale(72, level / 15d * brightness), color.R, color.G, color.B)))
        .ToArray();

    private static byte Scale(byte value, double factor) => (byte)Math.Clamp(Math.Round(value * factor), 0, 255);

    private static Color Interpolate(Color start, Color end, double amount) => Color.FromRgb(
        (byte)Math.Round(start.R + ((end.R - start.R) * amount)),
        (byte)Math.Round(start.G + ((end.G - start.G) * amount)),
        (byte)Math.Round(start.B + ((end.B - start.B) * amount)));

    private static Color ParseColor(string? value, Color fallback)
    {
        try { return string.IsNullOrWhiteSpace(value) ? fallback : Color.Parse(value); }
        catch (FormatException) { return fallback; }
    }

    private static Color[] Solid(Color color) => Enumerable.Repeat(color, PaletteColumns).ToArray();

    private static Color[] Gradient(Color low, Color high) => Enumerable.Range(0, PaletteColumns)
        .Select(index => Interpolate(low, high, index / (PaletteColumns - 1d)))
        .ToArray();

    private static Color[] Raster(params Color[] bands) => Enumerable.Range(0, PaletteColumns)
        .Select(index => bands[Math.Min((index * bands.Length) / PaletteColumns, bands.Length - 1)])
        .ToArray();

    private static Color[] PlasmaPalette(
        PlasmaPalettePreset preset,
        IReadOnlyList<string>? customColors)
    {
        var stopValues = PlasmaPaletteDefinition.GetStops(preset, customColors);
        var stops = stopValues
            .Select(value => ParseColor(value, Color.FromRgb(120, 100, 255)))
            .Append(ParseColor(stopValues[0], Color.FromRgb(120, 100, 255)))
            .ToArray();
        var palette = new Color[PaletteColumns];
        var segmentLength = PaletteColumns / (stops.Length - 1d);
        for (var index = 0; index < palette.Length; index++)
        {
            var position = index / segmentLength;
            var segment = Math.Min((int)position, stops.Length - 2);
            palette[index] = Interpolate(stops[segment], stops[segment + 1], position - segment);
        }

        return palette;
    }

    private static bool IsC64RasterPreset(DmdColorPreset preset) => preset is
        DmdColorPreset.C64BlueRound or DmdColorPreset.C64RedRound or DmdColorPreset.C64Earthtone or
        DmdColorPreset.C64Metal or DmdColorPreset.C64InterlacedBlue or DmdColorPreset.C64ExtrudedCyan or
        DmdColorPreset.C64Rainbow or DmdColorPreset.C64PurpleHalo or
        DmdColorPreset.RasterGreenHalo or DmdColorPreset.RasterAmberHalo or
        DmdColorPreset.RasterPurplePulse or DmdColorPreset.RasterOceanDepth or
        DmdColorPreset.RasterSunsetBands or DmdColorPreset.RasterForestLayers or
        DmdColorPreset.RasterArcticBands or DmdColorPreset.RasterCandyStripe;

    // Colodore-style approximations of the fixed Commodore 64 palette.
    private static readonly Color C64White = Color.FromRgb(0xFF, 0xFF, 0xFF);
    private static readonly Color C64Red = Color.FromRgb(0x68, 0x37, 0x2B);
    private static readonly Color C64Cyan = Color.FromRgb(0x70, 0xA4, 0xB2);
    private static readonly Color C64Purple = Color.FromRgb(0x6F, 0x3D, 0x86);
    private static readonly Color C64Green = Color.FromRgb(0x58, 0x8D, 0x43);
    private static readonly Color C64Blue = Color.FromRgb(0x35, 0x28, 0x79);
    private static readonly Color C64Yellow = Color.FromRgb(0xB8, 0xC7, 0x6F);
    private static readonly Color C64Orange = Color.FromRgb(0x6F, 0x4F, 0x25);
    private static readonly Color C64Brown = Color.FromRgb(0x43, 0x39, 0x00);
    private static readonly Color C64LightRed = Color.FromRgb(0x9A, 0x67, 0x59);
    private static readonly Color C64DarkGray = Color.FromRgb(0x44, 0x44, 0x44);
    private static readonly Color C64Gray = Color.FromRgb(0x6C, 0x6C, 0x6C);
    private static readonly Color C64LightGreen = Color.FromRgb(0x9A, 0xD2, 0x84);
    private static readonly Color C64LightBlue = Color.FromRgb(0x6C, 0x5E, 0xB5);
    private static readonly Color C64LightGray = Color.FromRgb(0x95, 0x95, 0x95);
}
