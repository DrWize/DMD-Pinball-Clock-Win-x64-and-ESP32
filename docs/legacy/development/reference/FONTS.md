# Bundled fonts

Files in this directory are copied into application publish output under `fonts/`.

## Inter

- File: `Inter/InterVariable.ttf`
- Use: bundled text font with broad Unicode coverage, including Swedish characters
- Source: https://github.com/rsms/inter
- Source commit: `353b61b9f4430d5f420d56605a6e7993e0941470`
- SHA-256: `4989B125924991B90D05B2D16E0E388C48F7D5BB8B30539BBF9C755278D0CCAF`
- License: SIL Open Font License 1.1; see `Inter/OFL-1.1.txt`

## Original DotClk clock fonts

`DotClk/ALTERN8.fnt`, `FISHY.fnt`, `TREK.fnt`, and `TWILIGHT.fnt` are the original
DotClk clock resources. They are embedded into the application assembly and are not
copied to the external `fonts/` directory. The application preserves the original
digit and clock glyphs and supplies its own dot-matrix date separators where a font
does not contain them.

- Original author/repository: sigmafx, https://github.com/sigmafx/DotClk-Resources
- Source directory: `Fonts/`
- Source commit: `11211af85a2ade66d05d961839773a05a01bddcc`
- Format: DotClk version 1, four-bit bitmap font
- Upstream repository does not currently include an explicit license file

The project currently keeps these four files embedded so the original clock faces
work without a separate download. This is an explicit temporary project decision,
not a claim that the files have an open-source or redistribution license. Their
origin and unchanged file hashes are recorded below.

| File | SHA-256 |
| --- | --- |
| `ALTERN8.fnt` | `46D81724040A5F530E86F914FC4F62CC5BD8AF6190049D7EB07FA67C2E9F3682` |
| `FISHY.fnt` | `346BFABF4FAEA5A0B273C964A3B8332558CABA72DAE6DA11388521D8E5FF9B1D` |
| `TREK.fnt` | `1EBDE4F395170AAC2F73A2C4E3CE64D03392B0C5C4BE8569C8CEEA390F260360` |
| `TWILIGHT.fnt` | `3BEFF77C0283B38FED4506AEC0225CA7CA53259E12AB1672A79A5C3CC1BE52BC` |

