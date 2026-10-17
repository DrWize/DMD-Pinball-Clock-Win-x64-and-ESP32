"""Reproducible current Windows/ESP32 playback comparison. No cloud services."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import statistics
import threading
import time
import urllib.request
import uuid

import CurrentPlaybackNative as NATIVE
import PlaybackComparison as COMMON

ROOT = COMMON.ROOT
PORTS = {'Waveshare7': 'COM4', 'Waveshare349B': 'COM3'}
STOP = threading.Event()


def now():
    return datetime.now(timezone.utc).isoformat()


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=True) + '\n', encoding='utf-8')
    temporary.replace(path)


def load(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


@contextmanager
def run_lock(out):
    import msvcrt
    out.mkdir(parents=True, exist_ok=True)
    with (out / 'runner.lock').open('a+b') as lock:
        if not lock.tell():
            lock.write(b'0'); lock.flush()
        lock.seek(0)
        try:
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as error:
            raise RuntimeError('A live controller owns this run; do not start another controller.') from error
        try:
            save(out / 'controller.json', dict(pid=os.getpid(), state='running', atUtc=now()))
            yield
        finally:
            save(out / 'controller.json', dict(pid=os.getpid(), state='stopped', atUtc=now()))
            lock.seek(0); msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)


class Link:
    def __init__(self, port, board, events=None):
        try:
            import serial
        except ImportError as error:
            raise RuntimeError('pyserial is required. Use the pinned ESP-IDF Python or install pyserial in your Python environment.') from error
        self.board, self.port_name, self.events = board, port, events
        self.pending = b''
        self.serial = serial.Serial(port=None, baudrate=115200, timeout=.2, write_timeout=2)
        self.serial.dtr = False; self.serial.rts = False; self.serial.port = port
        try:
            self.serial.open()
            self.wifi = self.request('hello', prefix='DMDWIFI:')[1]
            if self.wifi.get('board') != board:
                raise RuntimeError(f'{port} is not the selected {board}; no capture commands sent')
            self.identity = self.request('hello')[1]
            if (self.identity.get('board'), self.identity.get('mac')) != (board, self.wifi.get('mac')):
                raise RuntimeError('Timing identity does not match device identity')
            if not self.identity.get('sdAvailable') or len(self.identity.get('elfSha256', '')) != 64:
                raise RuntimeError('Timing capture requires a readable scene card and a valid firmware build identity')
        except BaseException:
            self.serial.close()
            raise

    def close(self):
        self.serial.close()

    def request(self, op, prefix='DMDTIMING:', timeout=15, **arguments):
        request = dict(protocol=1, id=uuid.uuid4().hex, op=op, **arguments)
        wire = (prefix + json.dumps(request, separators=(',', ':')) + '\n').encode()
        if len(wire) > 1024:
            raise ValueError('Serial request exceeds 1024 bytes')
        started = time.monotonic()
        try:
            self.serial.write(b'\n')
            for offset in range(0, len(wire), 32):
                self.serial.write(wire[offset:offset + 32]); time.sleep(.01)
            items = []
            last_progress = time.monotonic()
            while time.monotonic() - last_progress < timeout:
                chunk = self.serial.read(self.serial.in_waiting or 1)
                self.pending += chunk
                while b'\n' in self.pending:
                    line, self.pending = self.pending.split(b'\n', 1)
                    if not line.startswith(prefix.encode()):
                        continue
                    try:
                        response = json.loads(line[len(prefix):])
                    except (ValueError, UnicodeError):
                        continue
                    if not isinstance(response, dict) or response.get('id') != request['id']:
                        continue
                    if response.get('protocol') != 1:
                        raise RuntimeError('Unsupported capture protocol')
                    last_progress = time.monotonic()
                    if response.get('ok') is not True:
                        reason = response.get('error', 'unknown')
                        raise RuntimeError(f'{self.board}: {op} rejected: {reason}')
                    if prefix == 'DMDWIFI:' or response.get('done') is True:
                        if self.events:
                            with self.events.open('a', encoding='utf-8') as log:
                                log.write(json.dumps(dict(atUtc=now(), board=self.board, operation=op,
                                    elapsedSeconds=time.monotonic() - started, records=len(items), ok=True)) + '\n')
                        return items, response
                    items.append(response)
                    if op == 'inventory' and len(items) % 250 == 0:
                        print(f'{self.board}: verified {len(items)} card scenes...', flush=True)
                if len(self.pending) > 65536:
                    raise RuntimeError('Oversized or unterminated serial response')
            raise TimeoutError(f'{self.board}: no {prefix} reply for {op}. Install timing-capable firmware; older .3 Wi-Fi firmware does not support capture.')
        except OSError as error:
            raise RuntimeError(f'{self.board} COM transport failed. Close other serial monitors and check the cable; no automatic reset was performed.') from error

    def begin(self, run_id):
        # Startup's network-status screen must be gone before measuring a scene.
        remaining = max(0, 23 - self.identity.get('uptimeSeconds', 0))
        if remaining:
            time.sleep(remaining)
        wifi = self.request('hello', prefix='DMDWIFI:')[1]
        if (wifi.get('board'), wifi.get('mac')) != (self.board, self.identity['mac']):
            raise ValueError('Device identity changed before capture')
        self.wifi = wifi
        self.request('begin', session=run_id)

    def end(self, run_id):
        self.request('end', session=run_id)
        state = self.request('status')[1]
        if state['enabled'] or state['active']:
            raise RuntimeError('Capture remains enabled after cleanup')
        wifi = self.request('hello', prefix='DMDWIFI:')[1]
        if wifi['mac'] != self.wifi['mac'] or (self.wifi.get('ssid') and wifi.get('ssid') != self.wifi.get('ssid')) or (self.wifi.get('connected') and not wifi.get('connected')):
            raise RuntimeError('Wi-Fi identity/connection changed during capture; inspect the device')
        return dict(disabled=True, firmware=state['firmware'], mac=state['mac'],
            wifiConnected=wifi.get('connected'), ntpSynced=wifi.get('ntpSynced'), atUtc=now())

    def inventory(self, run_id, index=None):
        args = dict(session=run_id)
        if index is not None:
            args['index'] = index
        items, end = self.request('inventory', timeout=120, **args)
        expected = set(range(end['count'])) if index is None else {index}
        present = {row.get('index') for row in items}
        if any(row.get('type') != 'scene' for row in items) or len(present) != len(items) or not present <= expected:
            raise ValueError('Incomplete card inventory')
        # A damaged serial line is never accepted. Rehash explicitly missing
        # indices instead of repeating the entire card traversal.
        if index is None:
            for missing in sorted(expected - present):
                print(f'{self.board}: retrying missing inventory index {missing}', flush=True)
                items.extend(self.inventory(run_id, missing))
        if len(items) != end['count']:
            raise ValueError('Incomplete card inventory')
        return sorted(items, key=lambda row: row['index'])

    def get(self, run_id, stage, entry, repetition):
        items, end = self.request('get', timeout=30, session=run_id, stage=stage, caseId=entry['caseId'], repeat=repetition)
        if not end.get('found'):
            return None
        data = ''.join(row['line'] for row in items).encode('utf-8')
        if len(data) != end['bytes'] or hashlib.sha256(data).hexdigest() != end['sha256']:
            raise ValueError('Transferred SD log failed length/SHA-256 validation')
        return data


def verify_identity(link, expected):
    for key in ('board', 'mac', 'firmware', 'elfSha256'):
        if link.identity.get(key) != expected.get(key):
            raise ValueError(f'{link.board} {key} changed; prepare a new run for another device or firmware build')


def build_hashes(folder):
    source = folder / 'source'
    binary = source / 'src/DmdClock.App/bin/Release/net10.0'
    return dict(sources=load(folder / 'source-hashes.json'), binaries={str(p.relative_to(source)): COMMON.digest(p)
        for p in binary.rglob('*') if p.is_file()})


def verify_frozen(out, config):
    if COMMON.canonical_hash({k: v for k, v in config.items() if k not in ('ports', 'inputsHash')}) != config.get('inputsHash'):
        raise ValueError('Frozen run inputs/settings changed; prepare a new directory for different inputs')
    if COMMON.digest(out / 'manifest.json') != config['manifestHash']:
        raise ValueError('Frozen scene manifest changed')
    if COMMON.digest(out / 'frozen-builds.json') != config['buildsHash']:
        raise ValueError('Frozen build record changed')
    builds = load(out / 'frozen-builds.json')
    source = out / 'windows/source'
    for group in ('sources', 'binaries'):
        for name, sha in builds['windows'][group].items():
            if COMMON.digest(source / name) != sha:
                raise ValueError(f'Frozen Windows {group} changed: {name}')
    entries = load(out / 'manifest.json')['entries']
    for entry in entries:
        path = Path(config['sceneRoot']) / entry['scenePath']
        if COMMON.digest(path) != entry['sha256'] or COMMON.digest(out / 'windows/fixtures' / entry['name']) != entry['sha256']:
            raise ValueError(f'Frozen scene content changed: {entry["name"]}')
    return entries, builds


def prepare(args, out):
    if (out / 'run.json').exists():
        raise ValueError('Run already prepared. Use Run/Resume, or choose a new output directory.')
    if args.manifest and (args.test_set is not None or args.size is not None):
        raise ValueError('Manifest reuse cannot be combined with test-set/size selection')
    test_set = args.test_set or 'Standard50'
    if not args.manifest:
        COMMON.sample_count(test_set, args.size, 2 ** 31 - 1)  # reject malformed inputs before hardware access
    local = COMMON.local_inventory(args.scene_root)
    reference = load(args.manifest or COMMON.STANDARD)
    COMMON.validate_reference(reference, args.manifest or COMMON.STANDARD)
    COMMON.validate_entries(reference['entries'], local)
    run_id = uuid.uuid4().hex
    ports = dict(Waveshare7=args.port7 or 'COM4', Waveshare349B=args.port349b or 'COM3')
    links, identities, cards, cleanup = {}, {}, {}, {}
    try:
        for board, port in ports.items():
            links[board] = Link(port, board, out / f'{board}-protocol-events.jsonl')
            identities[board] = dict(links[board].identity)
            links[board].begin(run_id)
        def inventory(board):
            value = links[board].inventory(run_id)
            save(out / f'{board}-inventory.json', value)
            print(f'{board}: hashed {len(value)} scene files', flush=True)
            return board, value
        with ThreadPoolExecutor(max_workers=2) as pool:
            for board, values in pool.map(inventory, ports):
                cards[board] = values
    finally:
        for board, link in links.items():
            try:
                cleanup[board] = link.end(run_id)
            except Exception as error:
                cleanup[board] = dict(disabled=False, error=str(error))
            finally:
                link.close()
        save(out / 'prepare-cleanup.json', cleanup)
    if len(cleanup) != 2 or not all(v.get('disabled') for v in cleanup.values()):
        raise RuntimeError('Preparation cleanup failed; inspect prepare-cleanup.json')
    finish_prepare(args, out, run_id, ports, local, cards, identities)


def finish_prepare(args, out, run_id, ports, local, cards, identities):
    test_set = args.test_set or 'Standard50'
    aligned, alignment = COMMON.align(local, cards)
    save(out / 'alignment.json', alignment)
    if args.manifest:
        reference = load(args.manifest)
        COMMON.validate_reference(reference, args.manifest)
        selected = COMMON.validate_entries(reference['entries'], aligned)
        selection = dict(testSet='Manifest', sourceManifestHash=COMMON.digest(args.manifest), sourceManifestId=reference.get('id'))
        manifest_source = args.manifest
    else:
        selected = COMMON.select_entries(aligned, test_set, args.size, args.seed)
        selection = dict(testSet=test_set, size=args.size, seed=args.seed, referenceId='Standard50-v1',
            referenceHash=COMMON.digest(COMMON.STANDARD))
        manifest_source = COMMON.STANDARD if test_set == 'Standard50' else None
    indices = {board: {e['caseId']: e['indices'][board] for e in selected} for board in ports}
    entries = [{k: v for k, v in e.items() if k != 'indices'} for e in selected]
    manifest = dict(schemaVersion=1, id='Frozen-' + COMMON.canonical_hash(entries)[:16],
        selection=selection, matchingLibraryCount=len(aligned), poolHash=COMMON.canonical_hash([(e['name'], e['sha256']) for e in aligned]), entries=entries)
    if manifest_source:
        (out / 'manifest.json').write_bytes(Path(manifest_source).read_bytes())
        entries = load(out / 'manifest.json')['entries']
    else:
        save(out / 'manifest.json', manifest)
    selection['matchingLibraryCount'] = len(aligned)
    selection['poolHash'] = COMMON.canonical_hash([(e['name'], e['sha256']) for e in aligned])
    print(f'Frozen {len(entries)} scenes from {len(aligned)} matching files. Building isolated native Windows app...', flush=True)
    NATIVE.prepare(out / 'windows')
    fixtures = out / 'windows/fixtures'; fixtures.mkdir(exist_ok=True)
    for entry in entries:
        shutil.copyfile(Path(args.scene_root) / entry['scenePath'], fixtures / entry['name'])
    save(out / 'frozen-builds.json', dict(boards=identities, windows=build_hashes(out / 'windows')))
    config = dict(schemaVersion=1, runId=run_id, preparedAtUtc=now(), sceneRoot=str(Path(args.scene_root).resolve()),
        ports=ports, cardIndices=indices, manifestHash=COMMON.digest(out / 'manifest.json'),
        buildsHash=COMMON.digest(out / 'frozen-builds.json'), repetitions=3, thresholdPercent=5, thresholdMs=50,
        settings=dict(colorPreset=0, brightness=100, esp32GlowStrength=50, windowsGlowEnabled=True, showSeconds=False, showInformation=False, speed=1),
        renderingPolicy='ESP32 glow 50%; Windows normal glow enabled (Windows has no percentage control); no renderer changes',
        clockPolicy='Normal clocks retained; no NTP resets or fixed epochs', inputSelection=selection,
        sceneSetHash=COMMON.canonical_hash(entries))
    config['inputsHash'] = COMMON.canonical_hash({k: v for k, v in config.items() if k != 'ports'})
    save(out / 'run.json', config)
    print(f'Prepared {len(entries)} scenes / {len(entries) * 9} main measurements. Run directory: {out}', flush=True)


def raw_path(out, stage, target, entry, repetition):
    suffix = '.native.json' if target == 'windows' else '.jsonl'
    return out / 'results' / stage / target / f'{entry["caseId"]}-r{repetition}{suffix}'


def read_result(out, config, builds, stage, target, entry, repetition, detailed):
    path = raw_path(out, stage, target, entry, repetition)
    if not path.exists():
        return None
    if target == 'windows':
        row = COMMON.validate_windows(load(path), entry, repetition, detailed, config['sceneRoot'])
    else:
        row = COMMON.validate_hardware(path.read_bytes(), entry, target, builds['boards'][target],
            config['runId'], stage, repetition, detailed, config['sceneRoot'])
    row['rawPath'] = path.relative_to(out).as_posix()
    return row


def execute_board(out, config, builds, board, entries, stage, detailed):
    link = Link(config['ports'][board], board, out / f'{board}-protocol-events.jsonl')
    cleanup = dict(disabled=False)
    begun = False
    try:
        verify_identity(link, builds['boards'][board])
        link.begin(config['runId'])
        begun = True
        for number, entry in enumerate(entries):
            if STOP.is_set():
                return
            index = config['cardIndices'][board][entry['caseId']]
            inventory = link.inventory(config['runId'], index=index)
            if len(inventory) != 1 or any(inventory[0][key] != entry[key] for key in ('name', 'sha256', 'bytes')):
                raise ValueError(f'{board}: selected card file changed: {entry["name"]}')
            for repetition in range(3):
                if STOP.is_set():
                    return
                if read_result(out, config, builds, stage, board, entry, repetition, detailed) is None:
                    data = link.get(config['runId'], stage, entry, repetition)
                    if data is None:
                        timeout = min(3600000, max(30000, entry['expectedMs'] * 5 + entry['steps'] * 500 + 30000))
                        link.request('run', timeout=timeout / 1000 + 30, session=config['runId'], stage=stage,
                            caseId=entry['caseId'], repeat=repetition, index=index, sha256=entry['sha256'],
                            detailed=detailed, timeoutMs=timeout)
                        data = link.get(config['runId'], stage, entry, repetition)
                    if data is None:
                        raise ValueError('Completed capture has no committed SD log')
                    COMMON.validate_hardware(data, entry, board, builds['boards'][board], config['runId'],
                        stage, repetition, detailed, config['sceneRoot'])
                    path = raw_path(out, stage, board, entry, repetition)
                    path.parent.mkdir(parents=True, exist_ok=True)
                    temp = path.with_suffix('.tmp'); temp.write_bytes(data); temp.replace(path)
            save(out / f'{board}-progress.json', dict(stage=stage, scene=number + 1, total=len(entries), name=entry['name'], atUtc=now()))
            print(f'{stage} {board}: {number + 1}/{len(entries)} {entry["name"]}', flush=True)
    finally:
        try:
            if begun:
                cleanup = link.end(config['runId'])
        except Exception as error:
            cleanup = dict(disabled=False, error=str(error), atUtc=now())
        finally:
            link.close()
            save(out / f'{board}-cleanup.json', cleanup)
        if begun and not cleanup.get('disabled'):
            raise RuntimeError(f'{board}: cleanup failed; use Cleanup after checking the COM connection')


def execute_windows(out, config, builds, entries, stage, detailed):
    with NATIVE.Batch(out / 'windows') as batch:
        for number, entry in enumerate(entries):
            for repetition in range(3):
                if STOP.is_set():
                    return
                if read_result(out, config, builds, stage, 'windows', entry, repetition, detailed) is None:
                    raw = batch.play(entry, repetition, detailed)
                    COMMON.validate_windows(raw, entry, repetition, detailed, config['sceneRoot'])
                    save(raw_path(out, stage, 'windows', entry, repetition), raw)
            save(out / 'windows-progress.json', dict(stage=stage, scene=number + 1, total=len(entries), name=entry['name'], atUtc=now()))
            print(f'{stage} windows: {number + 1}/{len(entries)} {entry["name"]}', flush=True)


def stage(out, config, builds, entries, name, detailed):
    errors = []
    with ThreadPoolExecutor(max_workers=3) as pool:
        tasks = {pool.submit(execute_board, out, config, builds, board, entries, name, detailed): board for board in config['ports']}
        tasks[pool.submit(execute_windows, out, config, builds, entries, name, detailed)] = 'windows'
        for future in as_completed(tasks):
            try:
                future.result()
            except Exception as error:
                errors.append(dict(target=tasks[future], error=str(error), atUtc=now()))
                STOP.set()
    save(out / f'{name}-errors.json', errors)
    if errors:
        raise RuntimeError(f'{name} failed: {errors}')
    if STOP.is_set():
        raise InterruptedError('Stopped between captures; use Resume with this run directory')


def qualification(out, config, builds, entries):
    controls = entries[:min(5, len(entries))]
    for name, detailed in (('qualification-summary', False), ('qualification-full', True)):
        stage(out, config, builds, controls, name, detailed)
    differences = []
    for entry in controls:
        for target in COMMON.TARGETS:
            baseline = [read_result(out, config, builds, 'qualification-summary', target, entry, r, False) for r in range(3)]
            full = [read_result(out, config, builds, 'qualification-full', target, entry, r, True) for r in range(3)]
            changes = [b['actualMs'] - a['actualMs'] for a, b in zip(baseline, full)]
            flagged = sum(delta > 50 and delta / a['actualMs'] * 100 > 5 for a, delta in zip(baseline, changes)) >= 2
            differences.append(dict(name=entry['name'], target=target, pairedOverheadMs=changes, confirmedOverhead=flagged))
    result = dict(passed=not any(r['confirmedOverhead'] for r in differences), comparisons=differences,
        note='Assesses added per-step recording cost versus summary-only hooks; does not prove zero baseline hook overhead.', atUtc=now())
    save(out / 'qualification.json', result)
    if not result['passed']:
        raise RuntimeError('Detailed capture has confirmed recording overhead; inspect qualification.json before the main run')


def cleanup(out):
    config, builds = load(out / 'run.json'), load(out / 'frozen-builds.json')
    errors = []
    for board, port in config['ports'].items():
        link = None
        try:
            link = Link(port, board)
            verify_identity(link, builds['boards'][board])
            save(out / f'{board}-cleanup.json', link.end(config['runId']))
        except Exception as error:
            errors.append(dict(board=board, error=str(error)))
        finally:
            if link:
                link.close()
    if errors:
        raise RuntimeError(f'Cleanup incomplete: {errors}')


def run(out):
    config = load(out / 'run.json')
    entries, builds = verify_frozen(out, config)
    STOP.clear()
    def stop(signum, frame):
        STOP.set()
        print('Stop requested. Finishing active captures, saving evidence, and disabling sessions...', flush=True)
    previous_signal = signal.signal(signal.SIGINT, stop)
    awake = False
    if os.name == 'nt':
        import ctypes
        awake = bool(ctypes.windll.kernel32.SetThreadExecutionState(0x80000003))
    try:
        qualification(out, config, builds, entries)
        stage(out, config, builds, entries, 'main', True)
    finally:
        signal.signal(signal.SIGINT, previous_signal)
        if awake:
            import ctypes
            ctypes.windll.kernel32.SetThreadExecutionState(0x80000000)
        report(out)
    if not load(out / 'summary.json')['complete']:
        raise RuntimeError('Comparison incomplete; inspect report.md and use Resume')


def report(out):
    import CurrentPlaybackReport
    return CurrentPlaybackReport.write(out, read_result, save, verify_frozen)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'run', 'resume', 'report', 'cleanup'])
    parser.add_argument('output', type=Path)
    parser.add_argument('--test-set', choices=['Standard50', '5%', '10%', '50%', 'Custom'])
    parser.add_argument('--size')
    parser.add_argument('--seed', type=int, default=50)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--scene-root', type=Path, default=ROOT / 'scenes')
    parser.add_argument('--port7')
    parser.add_argument('--port349b')
    args = parser.parse_args()
    out = args.output.resolve()
    if args.action != 'prepare' and (args.test_set is not None or args.size is not None or args.manifest is not None):
        parser.error('Selection options are accepted only by Prepare; Run/Resume use the frozen manifest')
    if args.action == 'report':
        with run_lock(out):
            report(out)
    else:
        with run_lock(out):
            if args.action != 'prepare' and (args.port7 or args.port349b):
                config = load(out / 'run.json')
                if args.port7:
                    config['ports']['Waveshare7'] = args.port7
                if args.port349b:
                    config['ports']['Waveshare349B'] = args.port349b
                save(out / 'run.json', config)
            if args.action == 'prepare':
                prepare(args, out)
            elif args.action == 'cleanup':
                cleanup(out); report(out)
            else:
                run(out)


if __name__ == '__main__':
    main()
