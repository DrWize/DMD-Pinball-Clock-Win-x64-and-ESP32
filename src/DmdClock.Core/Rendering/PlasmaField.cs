namespace DmdClock.Core.Rendering;

/// <summary>
/// Generates a classic four-wave plasma using only integer arithmetic in the
/// per-pixel path. The same 256-step phase and lookup-table algorithm is suitable
/// for a small LED-matrix controller such as an ESP32.
/// </summary>
public static class PlasmaField
{
    public const int PhaseSteps = 256;
    public const int PaletteSize = 128;
    public const int DefaultCycleMilliseconds = 8_000;

    private const int WaveAmplitude = 127;
    private const int WaveCount = 4;
    private const int MinimumWaveSum = -(WaveAmplitude * WaveCount);
    private const int WaveRange = WaveAmplitude * WaveCount * 2;
    private static readonly sbyte[] Sine = CreateSineTable();

    public static byte PhaseAtMilliseconds(
        long elapsedMilliseconds,
        int cycleMilliseconds = DefaultCycleMilliseconds)
    {
        if (cycleMilliseconds <= 0)
            throw new ArgumentOutOfRangeException(nameof(cycleMilliseconds));

        var position = Math.Max(0, elapsedMilliseconds) % cycleMilliseconds;
        return (byte)((position * PhaseSteps) / cycleMilliseconds);
    }

    public static int GetPaletteIndex(
        int x,
        int y,
        int width,
        int height,
        byte phase)
    {
        if ((uint)x >= (uint)width)
            throw new ArgumentOutOfRangeException(nameof(x));
        if ((uint)y >= (uint)height)
            throw new ArgumentOutOfRangeException(nameof(y));

        var horizontal = Sine[(x * 5 + phase) & 0xff];
        var vertical = Sine[(y * 11 - phase) & 0xff];
        var diagonal = Sine[((x + y) * 3 + (phase >> 1)) & 0xff];

        // Fast octagonal distance approximation: max(dx,dy) + min(dx,dy)/2.
        // Coordinates are doubled so half-cell centres remain integral.
        var dx = Math.Abs((x * 2) - (width - 1));
        var dy = Math.Abs((y * 2) - (height - 1));
        var maximum = Math.Max(dx, dy);
        var minimum = Math.Min(dx, dy);
        var radius = maximum + (minimum >> 1);
        var radial = Sine[(radius * 3 - phase) & 0xff];

        var sum = horizontal + vertical + diagonal + radial;
        return ((sum - MinimumWaveSum) * (PaletteSize - 1)) / WaveRange;
    }

    private static sbyte[] CreateSineTable()
    {
        var table = new sbyte[PhaseSteps];
        for (var index = 0; index < table.Length; index++)
        {
            var radians = index * Math.Tau / PhaseSteps;
            table[index] = (sbyte)Math.Round(Math.Sin(radians) * WaveAmplitude);
        }

        return table;
    }
}
