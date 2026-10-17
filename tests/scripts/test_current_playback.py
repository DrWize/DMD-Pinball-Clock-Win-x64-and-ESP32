import copy
import argparse
import importlib.util
import json
from pathlib import Path
import random
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import PlaybackComparison as C
spec = importlib.util.spec_from_file_location('current_playback_runner', ROOT / 'scripts/Compare-CurrentPlayback.py')
R = importlib.util.module_from_spec(spec); spec.loader.exec_module(R)


class SelectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.inventory = C.local_inventory(ROOT / 'scenes')
        cls.standard = json.loads(C.STANDARD.read_text())

    def test_reference_is_frozen_and_valid(self):
        self.assertEqual(C.canonical_hash(self.standard), 'b0766010703f3de1c0ef2e0bdbdba314abae16b69bf3847cde2830eab79d2706')
        self.assertEqual(C.digest(C.STANDARD), C.STANDARD_FILE_HASH)
        rows = C.validate_entries(self.standard['entries'], self.inventory)
        self.assertEqual(len(rows), 50)
        self.assertEqual({c: sum(e['category'] == c for e in rows) for c in ('previous-difference', 'diverse', 'matching-control')},
            {'previous-difference': 20, 'diverse': 20, 'matching-control': 10})
        self.assertGreaterEqual(len({r['game'] for r in rows}), 20)

    def test_sizes_and_rounding(self):
        for test_set, size, result in [('Standard50', None, 50), ('5%', None, 121), ('10%', None, 242),
                ('50%', None, 1208), ('Custom', '12.5%', 302), ('Custom', '.1%', 3), ('Custom', '75', 75),
                ('Custom', '100%', 2416), ('Custom', '1', 1)]:
            self.assertEqual(C.sample_count(test_set, size, 2416), result)
        self.assertEqual(C.sample_count('5%', None, 51), 3)

    def test_invalid_sizes(self):
        for value in ('0', '-1', '2.5', '0%', '-1%', '101%', 'NaN%', 'inf%', '', 'abc', '2%%', '1e2%', '2417'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                C.sample_count('Custom', value, 2416)
        with self.assertRaises(ValueError): C.sample_count('10%', '10', 2416)
        with self.assertRaises(ValueError): C.sample_count('Standard50', None, 49)
        with self.assertRaises(ValueError): C.sample_count('Custom', '1', 0)

    def test_samples_nested_and_input_order_independent(self):
        shuffled = self.inventory[:]; random.Random(90).shuffle(shuffled)
        small = C.select_entries(self.inventory, '5%')
        large = C.select_entries(shuffled, '10%')
        self.assertEqual(small, large[:len(small)])
        self.assertEqual(small[:50], C.select_entries(self.inventory))
        self.assertEqual(C.select_entries(self.inventory, 'Custom', '7'), small[:7])
        self.assertNotEqual(C.select_entries(self.inventory, '5%', seed=123)[50:], small[50:])

    def test_manifest_reuse_and_changed_reference_rejected(self):
        damaged_manifest = copy.deepcopy(self.standard)
        damaged_manifest['entries'].reverse()
        with self.assertRaisesRegex(ValueError, 'Standard50-v1 changed'):
            C.validate_reference(damaged_manifest)
        with tempfile.TemporaryDirectory() as folder:
            altered = Path(folder) / 'reformatted.json'
            altered.write_bytes(C.STANDARD.read_bytes().replace(b'\r\n', b'\n'))
            with self.assertRaises(ValueError): C.validate_reference(self.standard, altered)
        chosen = C.select_entries(self.inventory, 'Custom', '75')
        shuffled = self.inventory[:]; random.Random(5).shuffle(shuffled)
        self.assertEqual(chosen, C.validate_entries(chosen, shuffled))
        damaged = copy.deepcopy(self.inventory)
        name = self.standard['entries'][0]['name']
        next(e for e in damaged if e['name'] == name)['sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'changed reference'):
            C.select_entries(damaged)
        with self.assertRaises(ValueError): C.validate_entries(chosen, chosen + chosen)

    def test_alignment_does_not_replace_missing_or_different_scenes(self):
        local = self.inventory[:3]
        cards = {b: [dict(e, index=i) for i, e in enumerate(local)] for b in ('a', 'b')}
        cards['a'][0]['sha256'] = '0' * 64
        cards['b'].pop(1)
        matching, alignment = C.align(local, cards)
        self.assertEqual([r['name'] for r in matching], [local[2]['name']])
        self.assertEqual(len(alignment['issues']), 2)

    def test_prepare_preserves_exact_manifest_across_builds(self):
        inventory = self.inventory
        class FakeLink:
            version = 'version-A'
            def __init__(self, port, board, *args):
                self.identity = dict(board=board, firmware=self.version, elfSha256=('a' if self.version == 'version-A' else 'b') * 64)
            def begin(self, run_id): pass
            def end(self, run_id): return dict(disabled=True)
            def close(self): pass
            def inventory(self, run_id): return [dict(e, index=i) for i, e in enumerate(inventory)]
        def native_prepare(out): (out / 'fixtures').mkdir(parents=True)
        with tempfile.TemporaryDirectory() as temporary:
            first, second = Path(temporary) / 'first', Path(temporary) / 'second'
            first.mkdir(); second.mkdir()
            args = argparse.Namespace(manifest=None, test_set='Standard50', size=None, seed=50,
                scene_root=ROOT / 'scenes', port7=None, port349b=None)
            with patch.object(R, 'Link', FakeLink), patch.object(R.NATIVE, 'prepare', native_prepare), \
                    patch.object(R, 'build_hashes', return_value=dict(sources={}, binaries={})):
                R.prepare(args, first)
                FakeLink.version = 'version-B'
                args.manifest, args.test_set = first / 'manifest.json', None
                R.prepare(args, second)
            self.assertEqual((first / 'manifest.json').read_bytes(), C.STANDARD.read_bytes())
            self.assertEqual((second / 'manifest.json').read_bytes(), C.STANDARD.read_bytes())
            self.assertEqual(R.load(first / 'run.json')['sceneSetHash'], R.load(second / 'run.json')['sceneSetHash'])
            self.assertNotEqual(R.load(first / 'run.json')['buildsHash'], R.load(second / 'run.json')['buildsHash'])

    def test_invalid_manifest_fails_before_opening_ports(self):
        args = argparse.Namespace(manifest=Path('missing-reference.json'), test_set=None, size=None,
            scene_root=ROOT / 'scenes', seed=50, port7=None, port349b=None)
        with tempfile.TemporaryDirectory() as folder, patch.object(R, 'Link') as link:
            with self.assertRaises(FileNotFoundError): R.prepare(args, Path(folder))
            link.assert_not_called()


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
        header = struct.pack('<3H', 1, 2, 1)
        storyboard = struct.pack('<8H', 20, 0, 0, 100, 0, 30, 0, 1) + bytes(20)
        data = header + storyboard + (struct.pack('<4H', 128, 32, 4, 0) + bytes(2048)) * 2
        (self.root / 'test.scn').write_bytes(data)
        self.entry = C.local_inventory(self.root)[0]
        self.identity = dict(firmware='test', elfSha256='a' * 64, board='Waveshare7', mac='01:02:03:04:05:06')

    def tearDown(self): self.temp.cleanup()

    def hardware(self, repetition=0, detailed=True):
        e = self.entry
        header = dict(kind='header', schemaVersion=1, runId='run', stage='main', caseId=e['caseId'], repeat=repetition,
            board='Waveshare7', firmware='test', elfSha256='a' * 64, sha256=e['sha256'], steps=e['steps'], frames=e['frames'], detailed=detailed,
            loadStartUs=1, loadEndUs=2, commandUs=3, colorPreset=0, brightness=100, glowStrength=50, showSeconds=False, showInformation=False)
        steps = [dict(kind='step', n=i, frame=s['frame'], delay=s['delay'], loop=100 + i * 1000,
            decoded=200 + i * 1000, painted=300 + i * 1000) for i, s in enumerate(C.expected_steps((self.root / 'test.scn').read_bytes()))] if detailed else []
        return [header] + steps + [dict(kind='result', count=e['steps'], start=200, end=3000, status='Completed'), dict(kind='commit', count=e['steps'])]

    def encoded(self, rows): return ('\n'.join(json.dumps(r) for r in rows) + '\n').encode()

    def windows(self, detailed=True, skipped=False):
        e = self.entry
        expected = C.expected_steps((self.root / 'test.scn').read_bytes())
        indices = [0, 2] if skipped or not detailed else [0, 1, 2]
        samples = [dict(ticks=i * 1000, step=i, frame=-1 if expected[i]['blank'] else expected[i]['frame'], blank=expected[i]['blank'], completed=i == 2) for i in indices]
        return dict(name=e['name'], sha256=e['sha256'], repeat=0, detailed=detailed, appVersion='test',
            timing=dict(speed=1, status='Completed', completed=True, totalSteps=3, expectedDurationMs=150, actualDurationMs=155, skippedFrames=int(skipped)),
            trace=dict(frequency=1000000, samples=samples))

    def validate(self, rows, repetition=0, detailed=True):
        return C.validate_hardware(self.encoded(rows), self.entry, 'Waveshare7', self.identity, 'run', 'main', repetition, detailed, self.root)

    def test_valid_full_and_summary_captures(self):
        self.assertEqual(self.validate(self.hardware())['coveredSteps'], 3)
        self.assertEqual(self.validate(self.hardware(detailed=False), detailed=False)['coveredSteps'], 3)

    def test_incomplete_corrupt_and_mismatched_logs(self):
        for fault in ('footer', 'identity', 'frame', 'paint', 'order', 'count'):
            rows = self.hardware()
            if fault == 'footer': rows.pop()
            if fault == 'identity': rows[0]['firmware'] = 'different'
            if fault == 'frame': rows[1]['frame'] = 10
            if fault == 'paint': rows[1]['painted'] = 0
            if fault == 'order': rows[2]['loop'] = 0
            if fault == 'count': rows[-1]['count'] = 2
            with self.subTest(fault=fault), self.assertRaises((ValueError, KeyError)):
                self.validate(rows)
        with self.assertRaises(ValueError): self.validate(self.hardware(), detailed=False)

    def test_windows_skip_trace_and_counter_agree(self):
        row = C.validate_windows(self.windows(skipped=True), self.entry, 0, True, self.root)
        self.assertEqual((row['coveredSteps'], row['skipped']), (2, 1))
        bad = self.windows(skipped=True); bad['timing']['skippedFrames'] = 0
        with self.assertRaises(ValueError): C.validate_windows(bad, self.entry, 0, True, self.root)
        bad = self.windows(); bad['timing']['speed'] = .8
        with self.assertRaises(ValueError): C.validate_windows(bad, self.entry, 0, True, self.root)
        for field, value in [('frequency', float('nan')), ('frequency', float('inf')), ('ticks', -1), ('ticks', float('nan'))]:
            bad = self.windows()
            if field == 'frequency': bad['trace'][field] = value
            else: bad['trace']['samples'][0][field] = value
            with self.assertRaises(ValueError): C.validate_windows(bad, self.entry, 0, True, self.root)

    def test_resume_reuses_host_and_sd_commits(self):
        out = self.root / 'run'; out.mkdir()
        config = dict(runId='run', ports=dict(Waveshare7='COM4'), sceneRoot=str(self.root), cardIndices=dict(Waveshare7={self.entry['caseId']: 0}))
        builds = dict(boards=dict(Waveshare7=self.identity))
        path = R.raw_path(out, 'main', 'Waveshare7', self.entry, 0)
        path.parent.mkdir(parents=True); path.write_bytes(self.encoded(self.hardware(0)))
        before = path.read_bytes()
        fixture = self
        class FakeLink:
            runs = []
            identity = fixture.identity
            def __init__(self, *args): pass
            def begin(self, run_id): pass
            def inventory(self, *args, **kwargs): return [dict(fixture.entry, index=0)]
            def get(self, run_id, stage, entry, repetition):
                if repetition == 2 and 2 not in self.runs: return None
                return fixture.encoded(fixture.hardware(repetition))
            def request(self, op, **kwargs): self.runs.append(kwargs['repeat'])
            def end(self, run_id): return dict(disabled=True)
            def close(self): pass
        R.STOP.clear()
        with patch.object(R, 'Link', FakeLink):
            R.execute_board(out, config, builds, 'Waveshare7', [self.entry], 'main', True)
        self.assertEqual(FakeLink.runs, [2])
        self.assertEqual(path.read_bytes(), before)
        self.assertTrue((out / 'Waveshare7-cleanup.json').exists())

    def test_firmware_change_rejected(self):
        class Fake: board = 'Waveshare7'; identity = dict(self.identity, elfSha256='b' * 64)
        with self.assertRaisesRegex(ValueError, 'changed'):
            R.verify_identity(Fake(), self.identity)

    def test_complete_and_corrupt_offline_reports(self):
        import CurrentPlaybackReport as report
        out = self.root / 'report'; out.mkdir()
        self.entry.update(category='control', game='Test')
        config = dict(runId='run', sceneRoot=str(self.root), ports=dict(Waveshare7='COM4', Waveshare349B='COM3'),
            manifestHash='m', buildsHash='b', sceneSetHash='s', settings=dict(speed=1), repetitions=3)
        builds = dict(boards={b: dict(self.identity, board=b) for b in config['ports']})
        R.save(out / 'run.json', config); R.save(out / 'qualification.json', dict(passed=True))
        for board in config['ports']: R.save(out / f'{board}-cleanup.json', dict(disabled=True))
        for stage, detailed in [('main', True), ('qualification-summary', False), ('qualification-full', True)]:
            for target in C.TARGETS:
                for repetition in range(3):
                    path = R.raw_path(out, stage, target, self.entry, repetition)
                    path.parent.mkdir(parents=True, exist_ok=True)
                    if target == 'windows':
                        data = self.windows(detailed=detailed); data['repeat'] = repetition
                        R.save(path, data)
                    else:
                        rows = self.hardware(repetition, detailed)
                        rows[0].update(board=target, stage=stage)
                        path.write_bytes(self.encoded(rows))
        verify = lambda *args: ([self.entry], builds)
        summary = report.write(out, R.read_result, R.save, verify)
        self.assertTrue(summary['complete']); self.assertEqual(summary['measurementCount'], 9)
        self.assertEqual(summary['softwareStageTimings']['Waveshare7']['steps'], 9)
        self.assertAlmostEqual(summary['softwareStageTimings']['Waveshare7']['medianDecodedToSubmissionMs'], .1)
        self.assertEqual(summary['qualificationMeasurements'], 18)
        for name in ('report.html', 'report.md', 'measurements.csv', 'step-timings.csv'):
            self.assertTrue((out / name).stat().st_size > 100)
        R.raw_path(out, 'main', 'Waveshare7', self.entry, 0).write_text('broken')
        summary = report.write(out, R.read_result, R.save, verify)
        self.assertFalse(summary['complete']); self.assertEqual(len(summary['invalid']), 1)


class TransportTests(unittest.TestCase):
    def test_natural_startup_wifi_join_is_not_a_settings_change(self):
        class Link:
            wifi = dict(mac='m', ssid='', connected=False)
            end = R.Link.end
            def request(self, op, **arguments):
                if op == 'status': return [], dict(enabled=False, active=False, firmware='f', mac='m')
                return [], dict(mac='m', ssid='home', connected=True, ntpSynced=True)
        link = Link()
        self.assertTrue(link.end('run')['disabled'])
        link.wifi = dict(mac='m', ssid='other', connected=True)
        with self.assertRaisesRegex(RuntimeError, 'Wi-Fi identity/connection changed'):
            link.end('run')

    def test_missing_inventory_record_is_rehashed(self):
        calls = []
        class Link:
            board = 'test'
            inventory = R.Link.inventory
            def request(self, op, **arguments):
                calls.append(arguments.get('index'))
                rows = [dict(type='scene', index=i) for i in ([0, 2] if 'index' not in arguments else [arguments['index']])]
                return rows, dict(count=3 if 'index' not in arguments else 1)
        self.assertEqual([r['index'] for r in Link().inventory('run')], [0, 1, 2])
        self.assertEqual(calls, [None, 1])

    def test_altered_run_settings_rejected_before_hardware(self):
        config = dict(settings=dict(speed=1), ports=dict(Waveshare7='COM4'))
        config['inputsHash'] = C.canonical_hash({k: v for k, v in config.items() if k != 'ports'})
        config['settings']['speed'] = .5
        with self.assertRaisesRegex(ValueError, 'inputs/settings changed'):
            R.verify_frozen(Path('unused'), config)


class PairTests(unittest.TestCase):
    def compare(self, changes, skipped=(0, 0, 0)):
        entry = dict(caseId='a', name='a.scn')
        rows = []
        for i, change in enumerate(changes):
            rows += [dict(caseId='a', target='Waveshare7', repeat=i, actualMs=1000, skipped=0),
                dict(caseId='a', target='windows', repeat=i, actualMs=1000 + change, skipped=skipped[i])]
        return C.compare_pairs(rows, [entry])[0]

    def test_two_of_three_and_strict_thresholds(self):
        self.assertFalse(self.compare([50, 50, 50])['confirmedDuration'])
        self.assertTrue(self.compare([51, 60, 0])['confirmedDuration'])
        self.assertFalse(self.compare([60, -60, 0])['confirmedDuration'])
        self.assertFalse(self.compare([60, 60])['confirmedDuration'])
        row = self.compare([0, 0, 0], skipped=(1, 1, 0))
        self.assertFalse(row['confirmedDuration']); self.assertTrue(row['repeatedSkippedSteps'])


if __name__ == '__main__': unittest.main()
