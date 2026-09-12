Set-StrictMode -Version Latest

# Keep compilation idempotent when callers import the module with -Force.
if (-not ('DmdClock.SceneIntensityPixelsV1' -as [type])) {
    Add-Type -TypeDefinition @'
namespace DmdClock {
    public static class SceneIntensityPixelsV1 {
        public static long[] Count(byte[] data, int offset, int width, int height, int stride) {
            long[] counts = new long[16];
            for (int y = 0; y < height; y++)
                for (int x = 0; x < width; x++)
                    counts[(data[offset + y * stride + x / 2] >> (4 * (x % 2))) & 15]++;
            return counts;
        }
    }
}
'@
}

function Get-ScnIntensityReport {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipelineByPropertyName)][Alias('FullName')][string]$Path)
    process {
        $file = Get-Item -LiteralPath $Path -ErrorAction Stop
        $data = [IO.File]::ReadAllBytes($file.FullName)
        $offset = 0
        function Read-U16 {
            param([int]$At)
            if ($At -lt 0 -or $At + 2 -gt $data.Length) { throw 'Truncated SCN header.' }
            [int]$data[$At] -bor ([int]$data[$At + 1] -shl 8)
        }
        $version = Read-U16 0
        $frameCount = Read-U16 2
        $storyboards = Read-U16 4
        if ($version -ne 1 -or $frameCount -eq 0) { throw 'Expected SCN v1 with at least one frame.' }
        $offset = 6 + 36 * $storyboards
        $histogram = [long[]]::new(16)
        $frames = @(
            for ($frame = 0; $frame -lt $frameCount; $frame++) {
                $width = Read-U16 $offset
                $height = Read-U16 ($offset + 2)
                $bpp = Read-U16 ($offset + 4)
                $mask = Read-U16 ($offset + 6)
                if ($width -lt 1 -or $height -lt 1 -or $width -gt 128 -or $height -gt 32 -or $bpp -ne 4 -or $mask -gt 1) {
                    throw "Unsupported frame $frame geometry, depth, or mask flag."
                }
                $offset += 8
                $stride = [int][math]::Ceiling($width / 2.0)
                $pixelBytes = $stride * $height
                $maskBytes = $mask * [int][math]::Ceiling($width / 8.0) * $height
                if ($offset + $pixelBytes + $maskBytes -gt $data.Length) { throw "Truncated frame $frame." }
                $counts = [DmdClock.SceneIntensityPixelsV1]::Count($data, $offset, $width, $height, $stride)
                for ($value = 0; $value -lt 16; $value++) {
                    $histogram[$value] += $counts[$value]
                }
                $offset += $pixelBytes + $maskBytes
                $values = @(0..15 | Where-Object { $counts[$_] -gt 0 })
                [pscustomobject]@{ Frame = $frame; Width = $width; Height = $height; HasMask = [bool]$mask; LevelCount = $values.Count; UsedValues = $values; Histogram = $counts }
            }
        )
        if ($offset -ne $data.Length) { throw 'Unexpected trailing SCN data.' }
        $used = @(0..15 | Where-Object { $histogram[$_] -gt 0 })
        [pscustomobject]@{
            Path = $file.FullName
            File = $file.Name
            Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            FrameCount = $frameCount
            LevelCount = $used.Count
            NonzeroLevelCount = @($used | Where-Object { $_ -ne 0 }).Count
            UsedValues = $used
            Histogram = $histogram
            Frames = $frames
        }
    }
}

Export-ModuleMember -Function Get-ScnIntensityReport
