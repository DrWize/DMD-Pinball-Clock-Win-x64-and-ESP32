# DMDClock translations

English is embedded in the application as the guaranteed fallback and default
language. The external `en.json` can override that baseline, and Swedish is in
`sv.json`. Missing, unreadable, or invalid external files are reported in
`%LOCALAPPDATA%\DmdClock\logs\dmdclock.log`; the application continues with the
embedded English strings.

To add a language, copy `template.json` to an ISO 639-1 language code such as `de.json`, translate every empty value without changing the keys, and add the language to the Language menu. The `_comment_*` fields explain each group and may be kept or removed. Files in this folder are included in every published build.
