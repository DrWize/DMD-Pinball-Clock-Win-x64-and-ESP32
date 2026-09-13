# Synthetic frame-dump format

This is a small, versioned DMDClock test format. It does not claim full compatibility with every VPinMAME dump variant. The test files are created specifically for this project and contain no ROM data.

```text
DMD-DUMP 1 width=4 height=2 bpp=2
FRAME timestampMs=0
0123
3210
FRAME timestampMs=40
0123
3010
```

- Version 1 supports two- and four-bit monochrome source frames.
- Each pixel is represented by one hexadecimal character.
- Each frame has a non-negative timestamp in milliseconds.
- Timestamps must be in ascending order.
- Empty lines and lines beginning with `#` are ignored between entries.

The format is used for reproducible tests of parsing, mask matching, palette colorization, and fallback behavior. A future VPinMAME importer should convert external dumps to the same internal `DmdFrameDump` model.
