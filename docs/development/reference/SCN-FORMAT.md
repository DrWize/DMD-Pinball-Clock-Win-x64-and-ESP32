# SCN version 1 format

All multi-byte integers are unsigned 16-bit little-endian values. This description is derived from the original DotClk SceneEditor source and verified against the local DotClk-Resources collection.

## File header (6 bytes)

1. Version
2. Dotmap/frame count
3. Storyboard count

## Storyboard (36 bytes each)

Eight 16-bit values describe first-frame delay/layer/blank, normal-frame delay/layer, and last-frame delay/layer/blank. They are followed by one-byte clock style, custom X and custom Y values, then 17 reserved bytes.

### Timing diagnostics

A zero first-frame or last-frame delay means that the corresponding special step is not present and is valid according to the original firmware. A zero regular frame delay is warned only when at least one regular animation frame uses it; DMDClock applies its 100 ms fallback in that case. A missing storyboard is also accepted with a warning and the same default delay.

Compatibility inspection rejects unsupported SCN versions, truncated or structurally damaged data, unsupported frame geometry, invalid flags, empty animations, and unexpected trailing data. Reports and application logs include a diagnostic code, filename, and reason.

## Dotmap/frame

The 8-byte header contains width, height, bits per pixel and a 0/1 mask flag. Current resources use 128 × 32 pixels at 4 bpp.

Pixel data is row-major. Each byte contains two pixels: the low nibble is the left/first pixel and the high nibble the right/second pixel. Intensity values range from 0 to 15.

When the mask flag is set, a one-bit-per-pixel row-major mask follows. The least-significant bit represents the first pixel in each group of eight.
