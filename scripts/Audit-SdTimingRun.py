"""Audit the completed timing comparison from raw evidence; never touch devices."""
import argparse
import csv
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('sd_timing_audit_runner', ROOT / 'scripts/Compare-SdSceneTiming.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def audit(out):
    checks = []

    def check(name, action):
        try:
            detail = action()
            checks.append(dict(name=name, passed=True, detail=detail))
        except Exception as error:
            checks.append(dict(name=name, passed=False, error=str(error)))

    def require(condition, message):
        if not condition:
            raise RuntimeError(message)

    def read(name):
        return json.loads((out / name).read_text(encoding='utf-8'))

    def source_integrity():
        m.verify_builds(out)
        return 'All four firmware source/image/configuration hashes and Windows source/executable hashes match the frozen builds.'

    check('frozen-builds', source_integrity)
    inventory = read('local-inventory.json')
    selected = read('selected-200.json')
    config = read('run.json')

    def alignment():
        canonical = {r['name']: (r['sha256'], r['bytes']) for r in inventory}
        require(len(canonical) == len(inventory), 'Duplicate local scene names')
        for board in m.BOARDS:
            actual = {r['name']: (r['sha256'], r['bytes']) for r in read(f'{board}-sd-inventory.json')}
            require(actual == canonical, f'{board} SD collection differs')
        for row in inventory:
            require(m.digest(Path(row['path'])) == row['sha256'], f'Local input changed: {row["name"]}')
        return dict(matchingScenes=len(canonical), inputs=3)

    check('scene-content-alignment', alignment)

    def selection():
        require(selected == m.select_200(inventory, config['seed']), 'Selection differs from the reproducible 200-scene selection')
        require(len(selected) == len({r['caseId'] for r in selected}) == 200, 'Expected 200 unique scenes')
        return dict(scenes=200, categories={c: sum(r['category'] == c for r in selected) for c in sorted({r['category'] for r in selected})})

    check('sample-selection', selection)

    def qualification():
        entries = read('qualification-10.json')
        require(len(entries) == len({r['caseId'] for r in entries}) == 10, 'Expected ten unique qualification scenes')
        rows = m.validated_stage_rows(out, 'qualify', entries)
        require({(r['target'], r['caseId'], r['repeat']) for r in rows} == {(t, e['caseId'], 0) for t in m.TARGETS for e in entries}, 'Qualification raw evidence incomplete')
        return dict(validatedCases=len(rows))

    check('qualification-raw-evidence', qualification)

    def stage_evidence(stage, entries, repeat_file):
        rows = m.validated_stage_rows(out, stage, entries)
        initial = [r for r in rows if r['repeat'] == 0]
        expected_initial = {(t, e['caseId'], 0) for t in m.TARGETS for e in entries}
        require({(r['target'], r['caseId'], 0) for r in initial} == expected_initial, f'{stage}: incomplete initial raw evidence')
        flagged = {c['caseId'] for c in m.comparisons(initial, entries) if c['flag']}
        repeats = read(repeat_file)
        require({r['caseId'] for r in repeats} == flagged, f'{stage}: repeat manifest does not match initial flags')
        expected = expected_initial | {(t, e, n) for t in m.TARGETS for e in flagged for n in (1, 2)}
        require({(r['target'], r['caseId'], r['repeat']) for r in rows} == expected, f'{stage}: missing or unexpected raw repetitions')
        comparisons = m.comparisons(rows, entries)
        return rows, comparisons, dict(initialCases=len(initial), repeatedScenes=len(flagged), totalCases=len(rows), confirmedScenes=len({c['caseId'] for c in comparisons if c['confirmed']}))

    def sample():
        _, pairs, detail = stage_evidence('sample', selected, 'repeat-scenes.json')
        decision = read('expansion-decision.json')
        confirmed = any(c['confirmed'] for c in pairs)
        require(decision['expand'] == (not confirmed), 'Expansion decision contradicts sample evidence and matching collections')
        require(not confirmed or not (out / 'full-manifest.json').exists(), 'Full library was expanded despite confirmed sample differences')
        return dict(**detail, expanded=decision['expand'])

    check('sample-raw-evidence-and-expansion-gate', sample)
    stage = 'full' if (out / 'full-manifest.json').exists() else 'sample'
    entries = read('full-manifest.json') if stage == 'full' else selected
    if stage == 'full':
        def full():
            require({r['caseId'] for r in entries} == {r['caseId'] for r in inventory}, 'Full manifest does not cover matching library')
            return stage_evidence('full', entries, 'full-repeat-scenes.json')[2]
        check('full-library-raw-evidence', full)

    def restoration():
        for board, identity in m.BOARDS.items():
            folder = out / board
            backup = read(f'{board}/pre-test-flash.json')
            require(backup['mac'] == identity['mac'] and backup['usbSerial'] == identity['usbSerial'], f'{board}: backup identity mismatch')
            require((folder / 'pre-test-flash.bin').stat().st_size == backup['size'] == 16777216, f'{board}: backup size mismatch')
            require(m.digest(folder / 'pre-test-flash.bin') == backup['sha256'], f'{board}: backup hash mismatch')
            require(read(f'{board}/restored.json')['complete'] and not (folder / 'restore-required.json').exists(), f'{board}: restoration incomplete')
            log = (folder / 'restore.log').read_text()
            require('Hash of data verified.' in log and identity['mac'] in log.lower(), f'{board}: full-flash verification log missing')
        return 'Both complete 16 MB pre-test snapshots restored with esptool hash verification and matching chip identities.'

    check('firmware-restoration', restoration)

    def recovery():
        proof = read('recovery-check.json')
        require(proof['complete'] and {r['board'] for r in proof['results']} == set(m.BOARDS), 'Both board recovery checks required')
        for result in proof['results']:
            require(result['cachedWithoutReplay'] and {r['version'] for r in result['records']} == {'oldest', 'latest'}, 'Old/new log recovery and cached RUN required')
            for record in result['records']:
                raw = m.case_path(out, stage, f'{result["board"]}/{record["version"]}', dict(caseId=result['caseId']), 0).with_suffix('.jsonl')
                require(record['unchanged'] and m.digest(raw) == record['sha256'], 'Recovered log differs from measured raw evidence')
        return dict(boards=2, recoveredLogs=4, cachedWithoutReplay=2)

    check('physical-sd-checkpoint-recovery', recovery)

    def exports():
        rows = m.validated_stage_rows(out, stage, entries)
        with (out / 'measurements.csv').open(encoding='utf-8', newline='') as stream:
            exported = list(csv.DictReader(stream))
        require(len(exported) == len(rows), 'CSV measurement count differs from validated raw evidence')
        require({(r['target'], r['name'], int(r['repeat'])) for r in exported} == {(r['target'], r['name'], r['repeat']) for r in rows}, 'CSV coverage differs from raw evidence')
        for name in ['report.md', 'report.html', 'step-timings.csv', 'esp32-pacing-reference.json']:
            require((out / name).stat().st_size > 100, f'Missing or empty export: {name}')
        require(read('summary.json')['complete'] and read('pipeline-finished.json')['complete'], 'Final pipeline/report incomplete')
        require(read('run-errors.json') == [] and read('runner-state.json')['state'] == 'stopped', 'Runner still active or failed')
        return dict(stage=stage, measuredCases=len(rows), reports=['report.html', 'report.md', 'measurements.csv', 'step-timings.csv'])

    check('reports-and-terminal-state', exports)
    result = dict(complete=all(c['passed'] for c in checks), atUtc=m.now(), checks=checks)
    m.save(out / 'completion-audit.json', result)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    result = audit(args.output.resolve())
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['complete'] else 1)
