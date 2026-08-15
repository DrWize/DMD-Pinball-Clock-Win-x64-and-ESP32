"""Generate a deterministic ESP32/QEMU metadata projection from the canonical catalog."""

import json
import pathlib
import sys


def main() -> int:
    if len(sys.argv) < 4:
        raise SystemExit(
            "usage: New-DmdSceneMetadataSubset.py INPUT OUTPUT SCENE [SCENE ...]"
        )
    source = pathlib.Path(sys.argv[1])
    destination = pathlib.Path(sys.argv[2])
    selected = {name.casefold() for name in sys.argv[3:]}
    with source.open("r", encoding="utf-8") as stream:
        document = json.load(stream)
    if document.get("schemaVersion") != 1:
        raise ValueError("expected scene metadata schemaVersion 1")
    projection = {
        "schemaVersion": 1,
        "prefixes": document.get("prefixes", []),
        "files": [
            item
            for item in document.get("files", [])
            if pathlib.PurePosixPath(item["path"]).name.casefold() in selected
        ],
    }
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("w", encoding="utf-8", newline="\n") as stream:
        json.dump(projection, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
