"""Timing-only model of local DotClk v1.14, NOT a Teensy firmware execution.

Models Scene.cpp NextFrame/Eof/GetFrameDelay and the DotClk.ino loop condition.
The model omits SD, graphics, interrupts and hardware costs. Cadence is an input.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def original(frames, first, blank_first, regular, last, blank_last, cadence):
    # SpecialProc enum: NA=0, TODO=1, INPROC=2, DONE=3.
    do_first, do_last, current, shown = int(first > 0), int(last > 0), 0, -1
    last_tick = 0
    elapsed = 0
    updates = 0
    # Use nonzero millis() as firmware does after startup, avoiding its 0 sentinel.
    start = 10000
    trace = []
    while True:
        now = start + elapsed
        delay = first if do_first == 2 else last if do_last == 2 else regular
        if last_tick == 0 or now - last_tick > delay:
            if current == frames and do_last in (0, 3):
                break
            last_tick = now if last_tick == 0 else last_tick + delay
            do_first = 2 if do_first == 1 else 3
            if current == frames:
                do_last = 2 if do_last == 1 else 3
            # A failed NextFrame return is ignored by the firmware main loop.
            if do_first == 2 and blank_first:
                shown = -1
            elif current < frames:
                shown = current
                current += 1
            elif do_last == 2 and blank_last:
                shown = -1
            trace.append([elapsed, shown])
            updates += 1
        elapsed += cadence
        if updates > frames + 10 or elapsed > 60_000_000:
            raise RuntimeError('Unexpected model state')
    return dict(completionMs=elapsed, advances=updates, trace=trace)


def windows_expected(frames, first, blank_first, regular, last):
    return first + (frames - int(first > 0 and not blank_first)) * (regular or 100) + last


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('evidence', type=Path, help='Output directory from Compare-PlaybackVersions.py')
    args = parser.parse_args()
    source = ROOT / 'external/DotClk'
    if subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD']).decode().strip() != '5ed33a570f9bbec6e891ae3908a4018e49ebca68':
        raise RuntimeError('Model requires reviewed DotClk snapshot 5ed33a5')
    source_hashes = {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in ('Scene.cpp', 'DotClk.ino')}
    for name in source_hashes:
        committed = subprocess.check_output(['git', '-C', str(source), 'show', f'HEAD:{name}'])
        if hashlib.sha256(committed.replace(b'\r\n', b'\n')).digest() != hashlib.sha256((source / name).read_bytes().replace(b'\r\n', b'\n')).digest():
            raise RuntimeError(f'Original source changed: {name}')
    fixtures = [('regular', 5, 0, False, 100, 0, False),
                ('zero-delay', 5, 0, False, 0, 0, False),
                ('first-last-holds', 5, 50, False, 100, 75, False),
                ('blank-holds', 5, 50, True, 100, 75, True),
                ('fast-frames', 5, 0, False, 5, 0, False)]
    for sample in json.loads((args.evidence / 'initial/results.json').read_text())['wallClock']:
        data = Path(sample['path']).read_bytes()
        _, count, boards = struct.unpack_from('<HHH', data)
        if not boards:
            continue  # Original constructor does not initialize timing without a storyboard.
        # Firmware overwrites its timing fields for each storyboard: last one wins.
        first, _, blank_first, regular, _, last, _, blank_last = struct.unpack_from('<8H', data, 6 + (boards - 1) * 36)
        fixtures.append((Path(sample['path']).name, count, first, bool(blank_first), regular, last, bool(blank_last)))
    results = []
    for name, frames, first, blank_first, regular, last, blank_last in fixtures:
        for cadence in (1, 16, 33, 250):
            expected = windows_expected(frames, first, blank_first, regular, last)
            result = original(frames, first, blank_first, regular, last, blank_last, cadence)
            results.append(dict(name=name, cadenceMs=cadence, frames=frames, regularMs=regular,
                                firstMs=first, lastMs=last, windowsExpectedMs=expected,
                                windowsCompletionMs=(expected + cadence - 1) // cadence * cadence, **result))
    # Independent sanity cases for strict >, absent zero-delay fallback, single-step catch-up, and trailing hold.
    assert original(5, 0, False, 100, 0, False, 1)['completionMs'] == 501
    assert original(5, 0, False, 0, 0, False, 1)['completionMs'] == 5
    assert original(5, 0, False, 5, 0, False, 16)['completionMs'] == 80
    assert original(5, 50, False, 100, 75, False, 1)['completionMs'] == 626
    output = args.evidence / 'original-dotclk-model.json'
    output.write_text(json.dumps(dict(qualification=__doc__, sourceHashes=source_hashes, results=results), indent=2))
    print(f'{len(results)} modeled timing cases; sanity assertions passed. {output}')
    for r in results:
        if r['cadenceMs'] == 16:
            print(f'{r["name"]}: Windows {r["windowsCompletionMs"]} ms; original model {r["completionMs"]} ms')


if __name__ == '__main__':
    main()
