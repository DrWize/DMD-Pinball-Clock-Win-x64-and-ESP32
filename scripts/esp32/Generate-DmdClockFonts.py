#!/usr/bin/env python3
"""Generate deterministic ESP32 C assets from the canonical DotClk v1 fonts."""

from __future__ import annotations

import argparse
import hashlib
import struct
import sys
from dataclasses import dataclass
from pathlib import Path


FONT_FILES = ("ALTERN8.fnt", "FISHY.fnt", "TREK.fnt", "TWILIGHT.fnt")
GOLDEN_TEXT = "23:59:58"
GOLDEN_FRAME_SHA256 = {
    "altern8": "A87AE1EF24885B19466492E06F95FDBE4791E6D907F1A404489394942C3AF2E0",
    "fishy": "FF4EE5C591FBE7F0877B855B8B2397065DB8EDACC2FDFC18A02E7741D69C2376",
    "trek": "6C3823E996C9009C0085D03F9851FC778724860820F3B30EE392297D681229A5",
    "twilight": "D615E36C396CA7B1DF802A4CD20517329FAE7D2E9AF378C97AB4A9FA2906EB00",
}


@dataclass(frozen=True)
class Glyph:
    character: int
    width: int
    kerning: int
    offset: int


@dataclass(frozen=True)
class Font:
    identifier: str
    name: str
    source_file: str
    source_sha256: str
    glyphs: tuple[Glyph, ...]
    atlas_width: int
    height: int
    intensity_stride: int
    mask_stride: int
    intensities: bytes
    mask: bytes


class Reader:
    def __init__(self, data: bytes, source: Path) -> None:
        self.data = data
        self.source = source
        self.offset = 0

    def read(self, size: int) -> bytes:
        end = self.offset + size
        if end > len(self.data):
            raise ValueError(f"{self.source.name}: truncated DotClk font")
        value = self.data[self.offset:end]
        self.offset = end
        return value

    def u16(self) -> int:
        return struct.unpack("<H", self.read(2))[0]

    def seven_bit_int(self) -> int:
        result = 0
        shift = 0
        while shift < 35:
            byte = self.read(1)[0]
            result |= (byte & 0x7F) << shift
            if byte & 0x80 == 0:
                return result
            shift += 7
        raise ValueError(f"{self.source.name}: invalid .NET string length")

    def string(self) -> str:
        return self.read(self.seven_bit_int()).decode("utf-8")

    def character(self) -> str:
        first = self.read(1)[0]
        if first < 0x80:
            encoded = bytes((first,))
        elif first & 0xE0 == 0xC0:
            encoded = bytes((first,)) + self.read(1)
        elif first & 0xF0 == 0xE0:
            encoded = bytes((first,)) + self.read(2)
        elif first & 0xF8 == 0xF0:
            encoded = bytes((first,)) + self.read(3)
        else:
            raise ValueError(f"{self.source.name}: invalid UTF-8 character")
        value = encoded.decode("utf-8")
        if len(value) != 1 or ord(value) > 0x7F:
            raise ValueError(
                f"{self.source.name}: ESP32 clock fonts require single-byte ASCII glyphs"
            )
        return value


def parse_font(path: Path) -> Font:
    data = path.read_bytes()
    reader = Reader(data, path)
    version = reader.u16()
    if version != 1:
        raise ValueError(f"{path.name}: unsupported DotClk version {version}")
    name = reader.string()
    if not name:
        raise ValueError(f"{path.name}: empty font name")
    glyph_count = reader.u16()
    if not 1 <= glyph_count <= 256:
        raise ValueError(f"{path.name}: invalid glyph count {glyph_count}")

    glyphs: list[Glyph] = []
    seen: set[int] = set()
    atlas_offset = 0
    for _ in range(glyph_count):
        character = ord(reader.character())
        width = reader.u16()
        kerning = reader.u16()
        if width == 0 or width > 255 or kerning >= width or kerning > 255:
            raise ValueError(f"{path.name}: invalid glyph metrics")
        if character in seen:
            raise ValueError(f"{path.name}: duplicate glyph {chr(character)!r}")
        seen.add(character)
        glyphs.append(Glyph(character, width, kerning, atlas_offset))
        atlas_offset += width

    atlas_width = reader.u16()
    height = reader.u16()
    bits_per_pixel = reader.u16()
    has_mask = reader.u16()
    if atlas_width != atlas_offset or not 1 <= atlas_width <= 4096:
        raise ValueError(f"{path.name}: invalid atlas width {atlas_width}")
    if not 1 <= height <= 32:
        raise ValueError(f"{path.name}: invalid font height {height}")
    if bits_per_pixel != 4 or has_mask != 1:
        raise ValueError(f"{path.name}: expected a four-bit font with a mask")

    intensity_stride = (atlas_width + 1) // 2
    mask_stride = (atlas_width + 7) // 8
    intensities = reader.read(intensity_stride * height)
    mask = reader.read(mask_stride * height)
    if reader.offset != len(data):
        raise ValueError(f"{path.name}: unexpected trailing data")

    return Font(
        identifier=name.lower(),
        name=name,
        source_file=path.name,
        source_sha256=hashlib.sha256(data).hexdigest().upper(),
        glyphs=tuple(glyphs),
        atlas_width=atlas_width,
        height=height,
        intensity_stride=intensity_stride,
        mask_stride=mask_stride,
        intensities=intensities,
        mask=mask,
    )


def c_bytes(data: bytes) -> str:
    rows = []
    for offset in range(0, len(data), 12):
        rows.append("    " + ", ".join(f"0x{value:02x}" for value in data[offset:offset + 12]))
    return ",\n".join(rows)


def intensity_at(font: Font, glyph: Glyph, x: int, y: int) -> int:
    atlas_x = glyph.offset + x
    packed = font.intensities[y * font.intensity_stride + atlas_x // 2]
    return packed & 0x0F if atlas_x % 2 == 0 else (packed >> 4) & 0x0F


def render_golden(font: Font) -> bytes:
    by_character = {glyph.character: glyph for glyph in font.glyphs}
    glyphs = [by_character[ord(character)] for character in GOLDEN_TEXT]
    text_width = sum(glyph.width for glyph in glyphs) - sum(
        glyph.kerning for glyph in glyphs[:-1]
    )
    frame = bytearray(128 * 32)
    cursor_x = (128 - text_width) // 2
    origin_y = (32 - font.height) // 2
    for glyph in glyphs:
        for y in range(font.height):
            for x in range(glyph.width):
                frame[(origin_y + y) * 128 + cursor_x + x] = intensity_at(
                    font, glyph, x, y
                )
        cursor_x += glyph.width - glyph.kerning
    return bytes(frame)


def verify_desktop_golden(fonts: tuple[Font, ...]) -> None:
    for font in fonts:
        actual = hashlib.sha256(render_golden(font)).hexdigest().upper()
        expected = GOLDEN_FRAME_SHA256[font.identifier]
        if actual != expected:
            raise ValueError(
                f"{font.source_file}: logical 128x32 frame differs from desktop golden "
                f"for {GOLDEN_TEXT!r}: expected {expected}, got {actual}"
            )


def generate_header() -> str:
    return """// Generated by scripts/esp32/Generate-DmdClockFonts.py. Do not edit.
#pragma once

#include <stddef.h>

#include "dmd_font_internal.h"

extern const dmd_font_asset_t dmd_generated_fonts[];
extern const size_t dmd_generated_font_count;
"""


def generate_source(fonts: tuple[Font, ...]) -> str:
    parts = [
        "// Generated by scripts/esp32/Generate-DmdClockFonts.py. Do not edit.\n",
        '#include "dmd_fonts_generated.h"\n',
    ]
    for font in fonts:
        symbol = font.identifier
        parts.append(f"\nstatic const dmd_font_glyph_t {symbol}_glyphs[] = {{\n")
        for glyph in font.glyphs:
            parts.append(
                f"    {{0x{glyph.character:02x}, {glyph.width}, {glyph.kerning}, {glyph.offset}}},\n"
            )
        parts.append("};\n")
        parts.append(
            f"\nstatic const uint8_t {symbol}_intensities[] = {{\n{c_bytes(font.intensities)}\n}};\n"
        )
        parts.append(
            f"\nstatic const uint8_t {symbol}_mask[] = {{\n{c_bytes(font.mask)}\n}};\n"
        )

    parts.append("\nconst dmd_font_asset_t dmd_generated_fonts[] = {\n")
    for font in fonts:
        symbol = font.identifier
        parts.append(
            "    {"
            f'"{font.identifier}", "{font.name}", "{font.source_file}", '
            f'"{font.source_sha256}", {font.height}, {font.atlas_width}, '
            f"{font.intensity_stride}, {font.mask_stride}, {len(font.glyphs)}, "
            f"{symbol}_glyphs, {symbol}_intensities, {symbol}_mask"
            "},\n"
        )
    parts.append("};\n")
    parts.append(
        "const size_t dmd_generated_font_count =\n"
        "    sizeof(dmd_generated_fonts) / sizeof(dmd_generated_fonts[0]);\n"
    )
    return "".join(parts)


def write_or_check(path: Path, expected: str, check: bool) -> bool:
    current = path.read_text(encoding="utf-8") if path.exists() else None
    if current == expected:
        return True
    if check:
        print(f"stale or missing generated font asset: {path}", file=sys.stderr)
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(expected, encoding="utf-8", newline="\n")
    print(f"generated {path}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    try:
        fonts = tuple(parse_font(args.source_dir / name) for name in FONT_FILES)
        verify_desktop_golden(fonts)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"font generation failed: {error}", file=sys.stderr)
        return 1
    ok = write_or_check(
        args.output_dir / "dmd_fonts_generated.h", generate_header(), args.check
    )
    ok = write_or_check(
        args.output_dir / "dmd_fonts_generated.c", generate_source(fonts), args.check
    ) and ok
    if ok:
        action = "verified" if args.check else "generated"
        print(f"{action} {len(fonts)} DotClk fonts")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
