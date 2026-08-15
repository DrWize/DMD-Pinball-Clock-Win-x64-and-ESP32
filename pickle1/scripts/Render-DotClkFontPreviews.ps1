param(
    [string]$FontDirectory = (Join-Path $PSScriptRoot '..\external\DotClk-Resources\Fonts'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\output\font-previews')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function Read-DotClkFont {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $reader = $null
    try {
        $reader = [IO.BinaryReader]::new($stream, [Text.Encoding]::UTF8, $true)
        $version = $reader.ReadUInt16()
        $name = $reader.ReadString()
        $glyphCount = $reader.ReadUInt16()
        $glyphs = @()

        for ($index = 0; $index -lt $glyphCount; $index++) {
            $glyphs += [pscustomobject]@{
                Character = $reader.ReadChar()
                Width = [int]$reader.ReadUInt16()
                Kerning = [int]$reader.ReadUInt16()
                Offset = 0
            }
        }

        $atlasWidth = [int]$reader.ReadUInt16()
        $height = [int]$reader.ReadUInt16()
        $bitsPerPixel = [int]$reader.ReadUInt16()
        $hasMask = [bool]$reader.ReadUInt16()

        if ($version -ne 1 -or $bitsPerPixel -ne 4) {
            throw "Unsupported DotClk font format in '$Path' (version $version, $bitsPerPixel bpp)."
        }

        $offset = 0
        foreach ($glyph in $glyphs) {
            $glyph.Offset = $offset
            $offset += $glyph.Width
        }

        $pixels = New-Object 'byte[,]' $atlasWidth, $height
        $packedDotBytesPerRow = [Math]::Ceiling($atlasWidth / 2.0)
        for ($y = 0; $y -lt $height; $y++) {
            for ($byteIndex = 0; $byteIndex -lt $packedDotBytesPerRow; $byteIndex++) {
                $packed = $reader.ReadByte()
                $x = $byteIndex * 2
                if ($x -lt $atlasWidth) {
                    $pixels[$x, $y] = $packed -band 0x0f
                }
                if (($x + 1) -lt $atlasWidth) {
                    $pixels[($x + 1), $y] = ($packed -shr 4) -band 0x0f
                }
            }
        }

        if ($hasMask) {
            $packedMaskBytesPerRow = [Math]::Ceiling($atlasWidth / 8.0)
            $reader.ReadBytes($packedMaskBytesPerRow * $height) | Out-Null
        }

        return [pscustomobject]@{
            Name = $name
            Version = $version
            Glyphs = $glyphs
            Width = $atlasWidth
            Height = $height
            Pixels = $pixels
        }
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
        $stream.Dispose()
    }
}

function ConvertTo-TextBitmap {
    param(
        [Parameter(Mandatory)]$Font,
        [Parameter(Mandatory)][string]$Text
    )

    $glyphs = @()
    foreach ($character in $Text.ToCharArray()) {
        $glyph = $Font.Glyphs | Where-Object Character -CEQ $character | Select-Object -First 1
        if ($null -eq $glyph) {
            throw "Font '$($Font.Name)' does not contain '$character'."
        }
        $glyphs += $glyph
    }

    $width = 0
    for ($index = 0; $index -lt $glyphs.Count; $index++) {
        $width += $glyphs[$index].Width
        if ($index -lt ($glyphs.Count - 1)) {
            $width -= $glyphs[$index].Kerning
        }
    }

    $pixels = New-Object 'byte[,]' $width, $Font.Height
    $destinationX = 0
    for ($index = 0; $index -lt $glyphs.Count; $index++) {
        $glyph = $glyphs[$index]
        for ($y = 0; $y -lt $Font.Height; $y++) {
            for ($x = 0; $x -lt $glyph.Width; $x++) {
                $targetX = $destinationX + $x
                if ($targetX -ge 0 -and $targetX -lt $width) {
                    $pixels[$targetX, $y] = $Font.Pixels[($glyph.Offset + $x), $y]
                }
            }
        }
        $destinationX += $glyph.Width
        if ($index -lt ($glyphs.Count - 1)) {
            $destinationX -= $glyph.Kerning
        }
    }

    return [pscustomobject]@{ Width = $width; Height = $Font.Height; Pixels = $pixels }
}

function Draw-DotMatrix {
    param(
        [Parameter(Mandatory)][Drawing.Graphics]$Graphics,
        [Parameter(Mandatory)]$Matrix,
        [Parameter(Mandatory)][int]$Left,
        [Parameter(Mandatory)][int]$Top,
        [Parameter(Mandatory)][int]$Scale,
        [Parameter(Mandatory)][int]$CanvasWidth,
        [Parameter(Mandatory)][int]$CanvasHeight
    )

    $panelBrush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, 5, 3, 2))
    $borderPen = [Drawing.Pen]::new([Drawing.Color]::FromArgb(255, 62, 32, 14), 1)
    $dimBrush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, 25, 11, 4))
    try {
        $Graphics.FillRectangle($panelBrush, $Left, $Top, $CanvasWidth * $Scale, $CanvasHeight * $Scale)
        $Graphics.DrawRectangle($borderPen, $Left, $Top, ($CanvasWidth * $Scale) - 1, ($CanvasHeight * $Scale) - 1)

        $matrixLeft = $Left + [int](($CanvasWidth - $Matrix.Width) * $Scale / 2)
        $matrixTop = $Top + [int](($CanvasHeight - $Matrix.Height) * $Scale / 2)
        $dotInset = [Math]::Max(1, [int]($Scale * 0.18))
        $dotSize = $Scale - ($dotInset * 2)

        for ($y = 0; $y -lt $Matrix.Height; $y++) {
            for ($x = 0; $x -lt $Matrix.Width; $x++) {
                $dotX = $matrixLeft + ($x * $Scale) + $dotInset
                $dotY = $matrixTop + ($y * $Scale) + $dotInset
                $value = [int]$Matrix.Pixels[$x, $y]

                if ($value -eq 0) {
                    $Graphics.FillEllipse($dimBrush, $dotX, $dotY, $dotSize, $dotSize)
                    continue
                }

                $red = 175 + [int](80 * $value / 15)
                $green = 45 + [int](125 * $value / 15)
                $blue = 4 + [int](20 * $value / 15)
                $litBrush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, $red, $green, $blue))
                try {
                    $Graphics.FillEllipse($litBrush, $dotX, $dotY, $dotSize, $dotSize)
                }
                finally {
                    $litBrush.Dispose()
                }
            }
        }
    }
    finally {
        $dimBrush.Dispose()
        $borderPen.Dispose()
        $panelBrush.Dispose()
    }
}

$resolvedFontDirectory = [IO.Path]::GetFullPath($FontDirectory)
$resolvedOutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($resolvedOutputDirectory) | Out-Null

$titleFont = [Drawing.Font]::new('Segoe UI Semibold', 26, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
$labelFont = [Drawing.Font]::new('Segoe UI', 14, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
$infoFont = [Drawing.Font]::new('Consolas', 13, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
$titleBrush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, 245, 174, 73))
$textBrush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, 202, 188, 174))
$backgroundBrush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, 19, 16, 14))

try {
    foreach ($fontPath in Get-ChildItem -LiteralPath $resolvedFontDirectory -Filter '*.fnt' | Sort-Object Name) {
        $font = Read-DotClkFont -Path $fontPath.FullName
        $sample = ConvertTo-TextBitmap -Font $font -Text '12:34:56'
        $atlas = [pscustomobject]@{ Width = $font.Width; Height = $font.Height; Pixels = $font.Pixels }
        $characters = -join ($font.Glyphs | ForEach-Object Character)

        $bitmap = [Drawing.Bitmap]::new(1000, 500, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
            $graphics.FillRectangle($backgroundBrush, 0, 0, $bitmap.Width, $bitmap.Height)

            $graphics.DrawString($font.Name, $titleFont, $titleBrush, 38, 23)
            $graphics.DrawString("DotClk v$($font.Version) | $($font.Height) dots high | $($font.Glyphs.Count) glyphs", $infoFont, $textBrush, 40, 62)

            $graphics.DrawString('CLOCK SAMPLE — 12:34:56', $labelFont, $textBrush, 40, 94)
            Draw-DotMatrix -Graphics $graphics -Matrix $sample -Left 116 -Top 119 -Scale 6 -CanvasWidth 128 -CanvasHeight 32

            $graphics.DrawString("COMPLETE GLYPH ATLAS — $characters", $labelFont, $textBrush, 40, 329)
            Draw-DotMatrix -Graphics $graphics -Matrix $atlas -Left (500 - [int]($font.Width * 5 / 2)) -Top 356 -Scale 5 -CanvasWidth $font.Width -CanvasHeight $font.Height

            $outputPath = Join-Path $resolvedOutputDirectory ($font.Name.ToLowerInvariant() + '.png')
            $bitmap.Save($outputPath, [Drawing.Imaging.ImageFormat]::Png)
            Write-Output $outputPath
        }
        finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }
}
finally {
    $backgroundBrush.Dispose()
    $textBrush.Dispose()
    $titleBrush.Dispose()
    $infoFont.Dispose()
    $labelFont.Dispose()
    $titleFont.Dispose()
}
