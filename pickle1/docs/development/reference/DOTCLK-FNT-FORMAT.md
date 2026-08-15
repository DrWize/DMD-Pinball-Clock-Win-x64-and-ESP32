# DotClk `.fnt` format

DMDClock supports the version-1 bitmap fonts produced by the original DotClk Font
Editor. Integers are little-endian. Strings and characters use the .NET
`BinaryWriter`/`BinaryReader` UTF-8 representation.

## File layout

1. `UInt16` format version (`1`)
2. length-prefixed font name
3. `UInt16` glyph count
4. one glyph-metrics record per glyph:
   - encoded character
   - `UInt16` glyph width
   - `UInt16` kerning overlap
5. dotmap header:
   - `UInt16` atlas width
   - `UInt16` font height
   - `UInt16` bits per pixel (`4`)
   - `UInt16` mask-present flag (`0` or `1`)
6. four-bit intensity atlas, row-major:
   - two pixels per byte
   - left pixel in the low nibble
   - right pixel in the high nibble
   - each row occupies `ceil(width / 2)` bytes
7. optional one-bit transparency mask, row-major:
   - eight pixels per byte
   - leftmost pixel in the least-significant bit
   - each row occupies `ceil(width / 8)` bytes

The atlas stores the glyphs consecutively in metrics-record order. A glyph offset is
the sum of the widths of all preceding glyphs. Text width is the sum of glyph widths
minus each glyph's kerning value except after the final glyph.

## Application behavior

The reader rejects unknown versions, duplicate characters, impossible metrics,
unsupported pixel depths, mismatched atlas dimensions, invalid mask flags, and
truncated data. The four bundled clock fonts retain their original bitmaps and masks.
For date formats, DMDClock creates small dot-matrix `-`, `.`, or `/` separators only
when the selected original font does not contain the required character.
