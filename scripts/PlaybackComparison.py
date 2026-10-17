"""Pure scene selection, evidence validation, and report helpers."""
from decimal import Decimal, InvalidOperation, ROUND_CEILING
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import struct

ROOT = Path(__file__).resolve().parents[1]
STANDARD = ROOT / 'tests/fixtures/playback/Standard50-v1.json'
STANDARD_HASH = 'b0766010703f3de1c0ef2e0bdbdba314abae16b69bf3847cde2830eab79d2706'
STANDARD_FILE_HASH = '516550b4c469e589c37653f5c810004243da75996e08aed8bcd855edbe0f2e94'
TARGETS = ('windows', 'Waveshare7', 'Waveshare349B')


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()).hexdigest()


def expected_steps(data):
    if len(data) < 42:
        raise ValueError('Truncated SCN header')
    version, frames, boards = struct.unpack_from('<3H', data)
    if version != 1 or not 0 < frames <= 512 or boards != 1:
        raise ValueError('Unsupported SCN geometry/storyboard')
    first, _, blank_first, regular, _, last, _, blank_last = struct.unpack_from('<8H', data, 6)
    offset = 42
    for _ in range(frames):
        if len(data) - offset < 8:
            raise ValueError('Truncated SCN frame')
        width, height, bpp, mask = struct.unpack_from('<4H', data, offset)
        if (width, height, bpp) != (128, 32, 4) or mask not in (0, 1):
            raise ValueError('Unsupported SCN frame')
        offset += 8 + 2048 + mask * 512
    if offset != len(data):
        raise ValueError('SCN length mismatch')
    rows = []
    if first:
        rows.append(dict(frame=0, delay=first, blank=bool(blank_first)))
    for frame in range(int(first > 0 and not blank_first), frames):
        rows.append(dict(frame=frame, delay=regular or 100, blank=False))
    if last:
        rows.append(dict(frame=frames - 1, delay=last, blank=bool(blank_last)))
    return rows


def local_inventory(scene_root):
    scene_root = Path(scene_root).resolve()
    metadata_path = scene_root / 'scene-metadata.json'
    metadata = json.loads(metadata_path.read_text(encoding='utf-8-sig')) if metadata_path.exists() else {}
    files = metadata.get('files', {})
    if isinstance(files, list):
        files = {str(item.get('path', '')).lower(): item for item in files}
    entries = []
    for path in sorted(scene_root.rglob('*.scn'), key=lambda p: (p.name.casefold(), str(p))):
        data = path.read_bytes()
        steps = expected_steps(data)
        _, frames, _ = struct.unpack_from('<3H', data)
        first, _, blank_first, regular, _, last, _, blank_last = struct.unpack_from('<8H', data, 6)
        item = files.get(path.name, files.get(path.name.lower(), {})) if isinstance(files, dict) else {}
        game = item.get('game') if isinstance(item, dict) else None
        if not game:
            game = next((p.get('game') for p in metadata.get('prefixes', [])
                if path.name.lower().startswith(p['prefix'].lower())), 'Unknown')
        sha = hashlib.sha256(data).hexdigest()
        entries.append(dict(name=path.name, scenePath=path.relative_to(scene_root).as_posix(), sha256=sha,
            bytes=len(data), frames=frames, steps=len(steps), expectedMs=sum(s['delay'] for s in steps),
            regularDelayMs=regular, firstHoldMs=first, lastHoldMs=last, blankFirst=bool(blank_first),
            blankLast=bool(blank_last), game=game, caseId=hashlib.sha256((path.name + '\0' + sha).encode()).hexdigest()[:24]))
    if len({e['name'].casefold() for e in entries}) != len(entries):
        raise ValueError('Ambiguous duplicate SCN basenames')
    return entries


def sample_count(test_set, size, available):
    if not available:
        raise ValueError('No matching scenes')
    if test_set == 'Standard50':
        if size is not None:
            raise ValueError('Size is valid only for Custom')
        value = 50
    else:
        if test_set not in ('5%', '10%', '50%', 'Custom'):
            raise ValueError('Unknown test set')
        if test_set != 'Custom' and size is not None:
            raise ValueError('Size is valid only for Custom')
        text = str(size).strip() if test_set == 'Custom' and size is not None else test_set
        if text.endswith('%'):
            if not re.fullmatch(r'(?:\d+(?:\.\d+)?|\.\d+)%', text):
                raise ValueError('Invalid percentage')
            try:
                percentage = Decimal(text[:-1])
            except InvalidOperation as error:
                raise ValueError('Invalid percentage') from error
            if not 0 < percentage <= 100:
                raise ValueError('Percentage must be greater than 0 and at most 100')
            value = int((Decimal(available) * percentage / 100).to_integral_value(rounding=ROUND_CEILING))
        elif re.fullmatch(r'[1-9]\d*', text):
            value = int(text)
        else:
            raise ValueError('Custom size must be a positive scene count or percentage, such as 75 or 12.5%')
    if not 1 <= value <= available:
        raise ValueError(f'Requested {value} scenes; only {available} match on all targets')
    return value


def validate_entries(entries, inventory):
    lookup = {e['name'].casefold(): e for e in inventory}
    if len(lookup) != len(inventory):
        raise ValueError('Ambiguous duplicate inventory names')
    if not entries or len({e['name'].casefold() for e in entries}) != len(entries):
        raise ValueError('Empty manifest or duplicate scene identities')
    result = []
    for frozen in entries:
        live = lookup.get(frozen['name'].casefold())
        if live is None or any(live.get(k) != frozen.get(k) for k in
                ('name', 'scenePath', 'sha256', 'bytes', 'frames', 'steps', 'expectedMs', 'caseId')):
            raise ValueError(f'Missing or changed reference scene: {frozen["name"]}')
        result.append(dict(live, category=frozen.get('category', 'custom')))
    return result


def select_entries(inventory, test_set='Standard50', size=None, seed=50, standard_path=STANDARD):
    standard = json.loads(Path(standard_path).read_text())
    if standard.get('id') != 'Standard50-v1':
        raise ValueError('Unexpected permanent reference-set identity')
    validate_reference(standard, standard_path)
    anchors = validate_entries(standard['entries'], inventory)
    count = sample_count(test_set, size, len(inventory))
    seen = {e['name'] for e in anchors}
    rest = [dict(e, category='expanded') for e in inventory if e['name'] not in seen]
    rest.sort(key=lambda e: (hashlib.sha256(f'{seed}:{e["caseId"]}'.encode()).hexdigest(), e['name']))
    return (anchors + rest)[:count]


def validate_reference(manifest, path=None):
    if manifest.get('id') == 'Standard50-v1' and (canonical_hash(manifest) != STANDARD_HASH or
            (path is not None and digest(path) != STANDARD_FILE_HASH)):
        raise ValueError('Standard50-v1 changed; create a new reference-set version instead')


def align(local, cards):
    lookups = {}
    for board, entries in cards.items():
        if len({e['name'].casefold() for e in entries}) != len(entries):
            raise ValueError(f'Duplicate card filenames: {board}')
        lookups[board] = {e['name'].casefold(): e for e in entries}
    matching, issues = [], []
    for entry in local:
        failures = [board for board, lookup in lookups.items() if entry['name'].casefold() not in lookup or
            any(lookup[entry['name'].casefold()][k] != entry[k] for k in ('name', 'sha256', 'bytes'))]
        if failures:
            issues.append(dict(name=entry['name'], targets=failures))
        else:
            matching.append(dict(entry, indices={board: lookup[entry['name'].casefold()]['index'] for board, lookup in lookups.items()}))
    return matching, dict(localCount=len(local), matchingCount=len(matching), issues=issues,
        cardCounts={board: len(values) for board, values in cards.items()})


def validate_hardware(data, entry, target, identity, run_id, stage, repetition, detailed, scene_root):
    rows = [json.loads(line) for line in data.decode('utf-8').splitlines()]
    if len(rows) < 3:
        raise ValueError('Incomplete hardware log')
    header, result, commit = rows[0], rows[-2], rows[-1]
    expected_header = dict(kind='header', schemaVersion=1, runId=run_id, stage=stage, caseId=entry['caseId'],
        repeat=repetition, board=target, firmware=identity['firmware'], elfSha256=identity['elfSha256'],
        sha256=entry['sha256'], steps=entry['steps'], frames=entry['frames'], detailed=detailed,
        colorPreset=0, brightness=100, glowStrength=50, showSeconds=False, showInformation=False)
    if any(header.get(k) != v for k, v in expected_header.items()):
        raise ValueError('Hardware log identity/settings mismatch')
    if commit != dict(kind='commit', count=entry['steps']) or result.get('kind') != 'result' or result.get('status') != 'Completed' or result.get('count') != entry['steps']:
        raise ValueError('Missing or invalid committed completion')
    if not 0 <= header['loadStartUs'] <= header['loadEndUs'] <= header['commandUs'] <= result['start'] < result['end']:
        raise ValueError('Invalid loading/playback boundaries')
    expected = expected_steps((Path(scene_root) / entry['scenePath']).read_bytes())
    steps = rows[1:-2]
    if detailed:
        if len(steps) != len(expected):
            raise ValueError('Missing frame/step evidence')
        previous = None
        for n, (actual, wanted) in enumerate(zip(steps, expected)):
            if actual.get('kind') != 'step' or actual.get('n') != n or any(actual[k] != wanted[k] for k in ('frame', 'delay')):
                raise ValueError('Frame or delay sequence mismatch')
            if not actual['loop'] <= actual['decoded'] <= actual['painted'] <= result['end']:
                raise ValueError('Invalid step timestamps')
            if previous is not None and actual['loop'] < previous['painted']:
                raise ValueError('Nonmonotonic rendering trace')
            previous = actual
        if result['start'] != steps[0]['decoded']:
            raise ValueError('Incorrect playback start')
    elif steps:
        raise ValueError('Summary-only capture unexpectedly contains detailed samples')
    return dict(target=target, name=entry['name'], caseId=entry['caseId'], sha256=entry['sha256'], repeat=repetition,
        detailed=detailed, expectedMs=entry['expectedMs'], actualMs=(result['end'] - result['start']) / 1000,
        loadMs=(header['loadEndUs'] - header['loadStartUs']) / 1000, steps=entry['steps'], frames=entry['frames'],
        skipped=0, coveredSteps=entry['steps'], status='Completed', firmware=identity['firmware'])


def validate_windows(raw, entry, repetition, detailed, scene_root):
    timing, trace = raw['timing'], raw['trace']
    samples = trace['samples']
    if (raw['name'], raw['sha256'], raw['repeat'], raw['detailed']) != (entry['name'], entry['sha256'], repetition, detailed):
        raise ValueError('Windows identity mismatch')
    if timing['speed'] != 1 or timing['status'] != 'Completed' or not timing['completed'] or timing['totalSteps'] != entry['steps'] or timing['expectedDurationMs'] != entry['expectedMs']:
        raise ValueError('Invalid Windows completion')
    if isinstance(timing.get('actualDurationMs'), bool) or not isinstance(timing.get('actualDurationMs'), (int, float)) or not math.isfinite(timing['actualDurationMs']) or timing['actualDurationMs'] <= 0:
        raise ValueError('Invalid Windows measured duration')
    frequency = trace['frequency']
    if isinstance(frequency, bool) or not isinstance(frequency, (int, float)) or not math.isfinite(frequency) or frequency <= 0:
        raise ValueError('Invalid Windows timestamp frequency')
    if not samples or samples[0]['step'] != 0 or samples[-1]['step'] != entry['steps'] - 1 or not samples[-1]['completed']:
        raise ValueError('Missing Windows trace boundaries')
    expected = expected_steps((Path(scene_root) / entry['scenePath']).read_bytes())
    previous = None
    for position, sample in enumerate(samples):
        ticks = sample['ticks']
        if isinstance(ticks, bool) or not isinstance(ticks, (int, float)) or not math.isfinite(ticks) or ticks < 0 or (sample['completed'] and position != len(samples) - 1):
            raise ValueError('Invalid Windows timestamp/completion boundary')
        if not 0 <= sample['step'] < len(expected):
            raise ValueError('Invalid Windows step')
        wanted = expected[sample['step']]
        if sample['frame'] != (-1 if wanted['blank'] else wanted['frame']) or sample['blank'] != wanted['blank']:
            raise ValueError('Windows rendered frame mismatch')
        if previous and (sample['ticks'] < previous['ticks'] or sample['step'] < previous['step']):
            raise ValueError('Nonmonotonic Windows trace')
        previous = sample
    covered = len({s['step'] for s in samples}) if detailed else None
    if detailed and entry['steps'] - covered != timing['skippedFrames']:
        raise ValueError('Windows skipped-step counter disagrees with trace')
    return dict(target='windows', name=entry['name'], caseId=entry['caseId'], sha256=entry['sha256'], repeat=repetition,
        detailed=detailed, expectedMs=entry['expectedMs'], actualMs=timing['actualDurationMs'], loadMs=trace.get('loadMs'),
        steps=entry['steps'], frames=entry['frames'], skipped=timing['skippedFrames'], coveredSteps=covered,
        status='Completed', firmware=raw['appVersion'])


def compare_pairs(rows, entries):
    groups = {}
    for row in rows:
        groups.setdefault((row['caseId'], row['target']), {})[row['repeat']] = row
    comparisons = []
    for entry in entries:
        for reference, compared in (('Waveshare7', 'windows'), ('Waveshare349B', 'windows'), ('Waveshare7', 'Waveshare349B')):
            left, right = groups.get((entry['caseId'], reference), {}), groups.get((entry['caseId'], compared), {})
            pairs = [r for r in range(3) if r in left and r in right]
            differences = [right[r]['actualMs'] - left[r]['actualMs'] for r in pairs]
            positive = sum(d > 50 and d / left[r]['actualMs'] * 100 > 5 for r, d in zip(pairs, differences))
            negative = sum(d < -50 and -d / left[r]['actualMs'] * 100 > 5 for r, d in zip(pairs, differences))
            complete = len(pairs) == 3
            comparisons.append(dict(caseId=entry['caseId'], name=entry['name'], reference=reference, compared=compared,
                complete=complete, confirmedDuration=complete and max(positive, negative) >= 2,
                repeatedSkippedSteps=complete and any(sum(side[r]['skipped'] > 0 for r in pairs) >= 2 for side in (left, right)),
                referenceMedianMs=statistics.median(left[r]['actualMs'] for r in pairs) if pairs else None,
                comparedMedianMs=statistics.median(right[r]['actualMs'] for r in pairs) if pairs else None,
                pairedDifferencesMs=differences))
    return comparisons
