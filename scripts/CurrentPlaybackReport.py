"""Offline evidence audit and portable reports for current playback runs."""
import csv
import html
import json
from pathlib import Path
import statistics

import PlaybackComparison as COMMON


def read(path, default=None):
    return json.loads(path.read_text()) if path.exists() else default


def write(out, read_result, save, verify_frozen):
    config = read(out / 'run.json')
    entries, builds = verify_frozen(out, config)
    rows, missing, invalid = [], [], []
    qualification_rows = []
    for stage, selected, detailed in [('main', entries, True),
            ('qualification-summary', entries[:min(5, len(entries))], False),
            ('qualification-full', entries[:min(5, len(entries))], True)]:
        for entry in selected:
            for target in COMMON.TARGETS:
                for repetition in range(3):
                    try:
                        row = read_result(out, config, builds, stage, target, entry, repetition, detailed)
                        if row is None:
                            missing.append(dict(stage=stage, target=target, name=entry['name'], repeat=repetition))
                        elif stage == 'main':
                            rows.append(row)
                        else:
                            qualification_rows.append(dict(row, stage=stage))
                    except Exception as error:
                        invalid.append(dict(stage=stage, target=target, name=entry['name'], repeat=repetition, error=str(error)))
    qualification = read(out / 'qualification.json', {})
    expected_qualification = min(5, len(entries)) * 18
    overhead = []
    for entry in entries[:min(5, len(entries))]:
        for target in COMMON.TARGETS:
            short = {r['repeat']: r for r in qualification_rows if r['caseId'] == entry['caseId'] and r['target'] == target and r['stage'] == 'qualification-summary'}
            full = {r['repeat']: r for r in qualification_rows if r['caseId'] == entry['caseId'] and r['target'] == target and r['stage'] == 'qualification-full'}
            if len(short) == len(full) == 3:
                flags = sum(full[r]['actualMs'] - short[r]['actualMs'] > 50 and
                    (full[r]['actualMs'] - short[r]['actualMs']) / short[r]['actualMs'] * 100 > 5 for r in range(3))
                overhead.append(flags >= 2)
    qualification_valid = len(qualification_rows) == expected_qualification and not any(overhead) and qualification.get('passed') is True
    cleanup = {board: read(out / f'{board}-cleanup.json', {}) for board in config['ports']}
    comparisons = COMMON.compare_pairs(rows, entries)
    complete = len(rows) == len(entries) * 9 and not missing and not invalid and qualification_valid and all(v.get('disabled') for v in cleanup.values())
    summary = dict(schemaVersion=1, complete=complete, sceneCount=len(entries), measurementCount=len(rows),
        expectedMeasurements=len(entries) * 9, qualificationMeasurements=len(qualification_rows),
        qualificationPassed=qualification_valid, missing=missing, invalid=invalid, cleanup=cleanup,
        manifestHash=config['manifestHash'], buildsHash=config['buildsHash'],
        sceneSetHash=config.get('sceneSetHash'), settings=config['settings'],
        renderingPolicy=config.get('renderingPolicy'), repetitions=config['repetitions'],
        confirmedDurationPairs=sum(c['confirmedDuration'] for c in comparisons),
        repeatedSkippedStepPairs=sum(c['repeatedSkippedSteps'] for c in comparisons),
        thresholds=dict(percent=5, milliseconds=50, pairedConfirmations=2, repetitions=3))
    save(out / 'summary.json', summary)
    save(out / 'comparisons.json', comparisons)
    provenance = dict(manifestSha256=config['manifestHash'], buildsSha256=config['buildsHash'],
        sceneSetSha256=config.get('sceneSetHash'), thresholdPercent=5, thresholdMs=50,
        repetitions=config['repetitions'], renderingSettings=json.dumps(config['settings'], sort_keys=True))
    with (out / 'measurements.csv').open('w', newline='', encoding='utf-8') as stream:
        keys = ['target', 'name', 'caseId', 'sha256', 'repeat', 'expectedMs', 'actualMs', 'loadMs', 'steps', 'frames', 'skipped', 'coveredSteps', 'firmware', 'rawPath']
        writer = csv.DictWriter(stream, fieldnames=keys + list(provenance), extrasaction='ignore')
        writer.writeheader(); writer.writerows(dict(row, **provenance) for row in rows)
    with (out / 'step-timings.csv').open('w', newline='', encoding='utf-8') as stream:
        spans = {board: dict(loopToDecoded=[], decodedToSubmission=[]) for board in builds['boards']}
        keys = ['name', 'target', 'repeat', 'step', 'frame', 'expectedDelayMs', 'skipped', 'loopUs', 'decodedUs', 'paintedUs', 'submissionUs']
        writer = csv.DictWriter(stream, fieldnames=keys + list(provenance)); writer.writeheader()
        lookup = {e['caseId']: e for e in entries}
        for row in rows:
            entry = lookup[row['caseId']]
            expected = COMMON.expected_steps((Path(config['sceneRoot']) / entry['scenePath']).read_bytes())
            raw_path = out / row['rawPath']
            if row['target'] == 'windows':
                raw = read(raw_path); trace = raw['trace']; samples = {}
                for sample in trace['samples']:
                    samples.setdefault(sample['step'], sample)
                for n, wanted in enumerate(expected):
                    sample = samples.get(n)
                    writer.writerow(dict(**provenance, name=entry['name'], target=row['target'], repeat=row['repeat'], step=n,
                        frame=wanted['frame'], expectedDelayMs=wanted['delay'], skipped=sample is None,
                        submissionUs=sample['ticks'] * 1000000 / trace['frequency'] if sample else ''))
            else:
                raw = [json.loads(line) for line in raw_path.read_text().splitlines()]
                for sample in raw[1:-2]:
                    spans[row['target']]['loopToDecoded'].append((sample['decoded'] - sample['loop']) / 1000)
                    spans[row['target']]['decodedToSubmission'].append((sample['painted'] - sample['decoded']) / 1000)
                    writer.writerow(dict(**provenance, name=entry['name'], target=row['target'], repeat=row['repeat'], step=sample['n'],
                        frame=sample['frame'], expectedDelayMs=sample['delay'], skipped=False,
                        loopUs=sample['loop'], decodedUs=sample['decoded'], paintedUs=sample['painted']))
    summary['softwareStageTimings'] = {board: dict(steps=len(values['loopToDecoded']),
        medianLoopToDecodedMs=statistics.median(values['loopToDecoded']) if values['loopToDecoded'] else None,
        medianDecodedToSubmissionMs=statistics.median(values['decodedToSubmission']) if values['decodedToSubmission'] else None)
        for board, values in spans.items()}
    save(out / 'summary.json', summary)
    table_rows = []
    for order, entry in enumerate(entries, 1):
        groups = {target: [r for r in rows if r['caseId'] == entry['caseId'] and r['target'] == target] for target in COMMON.TARGETS}
        metrics = {target: dict(medianMs=statistics.median(r['actualMs'] for r in group) if group else None,
            minMs=min((r['actualMs'] for r in group), default=None), maxMs=max((r['actualMs'] for r in group), default=None),
            skipped=[r['skipped'] for r in group], measurements=len(group), paths=[r['rawPath'] for r in group]) for target, group in groups.items()}
        for target, group in groups.items():
            metrics[target]['coveredSteps'] = [r['coveredSteps'] for r in group]
        table_rows.append(dict(order=order, **entry, metrics=metrics,
            confirmedDuration=any(c['confirmedDuration'] for c in comparisons if c['caseId'] == entry['caseId']),
            repeatedSkippedSteps=any(c['repeatedSkippedSteps'] for c in comparisons if c['caseId'] == entry['caseId'])))
    def fmt(value):
        return 'missing' if value is None else f'{value / 1000:.3f} s'
    def duration(metric):
        return f'{fmt(metric["medianMs"])} ({fmt(metric["minMs"])}–{fmt(metric["maxMs"])})'
    lines = ['# Current playback comparison', '', '**Complete**' if complete else '**INCOMPLETE — results must not be treated as a completed comparison.**', '',
        f'{len(entries)} scenes; {len(rows)}/{len(entries) * 9} main measurements; {len(qualification_rows)}/{expected_qualification} qualification measurements.', '',
        f'Capture-overhead qualification passed: {qualification_valid}. Detailed paired overhead is retained in `qualification.json`.', '',
        f'Manifest SHA-256: `{config["manifestHash"]}`. Threshold: both 5% and 50 ms, same direction in at least two of three paired measurements.', '',
        f'Scene-set SHA-256: `{config.get("sceneSetHash", "not recorded")}`. Repetitions per target: {config["repetitions"]}.', '',
        'Runtime settings: `' + json.dumps(config['settings'], sort_keys=True) + '`.', '',
        config.get('renderingPolicy', 'ESP32 glow 50%; Windows normal glow enabled.'), '',
        'Software scene timing and rendering submissions only. Windows skipped animation steps are separate from duration differences; no GPU/display-drop or optical timing claim is made.', '',
        'Loading, SD log writes, and transfer are excluded. Normal clocks, Wi-Fi, and NTP are retained. Summary-only qualification estimates added recording overhead, not the cost of all instrumentation.', '',
        '## Builds', '', f'- Windows frozen binaries/source: `{config["buildsHash"]}`']
    for board, identity in builds['boards'].items():
        lines.append(f'- {board}: `{identity["firmware"]}`, ELF SHA-256 `{identity["elfSha256"]}`')
    lines += ['', '## ESP32 software stage spans', '',
        'Step-weighted medians from valid main captures. The second span includes overlay, drawing and rendering submission; optical presentation is not measured. Windows does not expose equivalent spans.', '',
        '| Target | Captured steps | Loop to decode (ms) | Decode to submission (ms) |', '|---|---:|---:|---:|']
    for board, metrics in summary['softwareStageTimings'].items():
        a, b = metrics['medianLoopToDecodedMs'], metrics['medianDecodedToSubmissionMs']
        lines.append(f'| {board} | {metrics["steps"]} | {a if a is not None else "missing"} | {b if b is not None else "missing"} |')
    lines += ['', '## Pair results', '', '| Reference | Compared | Confirmed duration differences | Repeated skipped-step cases |', '|---|---|---:|---:|']
    for reference, compared in [('Waveshare7', 'windows'), ('Waveshare349B', 'windows'), ('Waveshare7', 'Waveshare349B')]:
        group = [c for c in comparisons if c['reference'] == reference and c['compared'] == compared]
        lines.append(f'| {reference} | {compared} | {sum(c["confirmedDuration"] for c in group)} | {sum(c["repeatedSkippedSteps"] for c in group)} |')
    lines += ['', '## Scene medians and repetition ranges', '', '| Scene | Category | File timeline | Windows (min–max) | 7-inch (min–max) | 3.49B (min–max) | Windows skipped steps (r0/r1/r2) | ESP32 coverage: 7-inch / 3.49B |', '|---|---|---:|---:|---:|---:|---|---|']
    for entry in table_rows:
        metrics = entry['metrics']
        coverage = ' / '.join(', '.join(f'{n}/{entry["steps"]}' for n in metrics[target]['coveredSteps']) or 'missing' for target in ('Waveshare7', 'Waveshare349B'))
        lines.append(f'| {entry["name"]} | {entry["category"]} | {fmt(entry["expectedMs"])} | {duration(metrics["windows"])} | {duration(metrics["Waveshare7"])} | {duration(metrics["Waveshare349B"])} | {metrics["windows"]["skipped"]} | {coverage} |')
    if missing or invalid or not qualification_valid or not all(v.get('disabled') for v in cleanup.values()):
        lines += ['', '## Outstanding evidence', '', f'- Missing cases: {len(missing)}; invalid cases: {len(invalid)}.',
            f'- Qualification passed: {qualification_valid}. Capture disabled on both boards: {all(v.get("disabled") for v in cleanup.values())}.',
            '- See `summary.json` for every missing/invalid case and cleanup outcome.']
    lines += ['', '[Interactive report](report.html) · [Measurements](measurements.csv) · [Step timing](step-timings.csv)', '']
    (out / 'report.md').write_text('\n'.join(lines), encoding='utf-8')
    payload = json.dumps(dict(summary=summary, scenes=table_rows, builds=builds['boards']), ensure_ascii=True).replace('<', '\\u003c')
    template = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Playback comparison</title>
<style>body{font:15px system-ui;background:#10151c;color:#e9eef5;margin:28px}a{color:#8bc5ff}input,select{padding:8px;background:#202b38;color:inherit;border:1px solid #53677d}table{border-collapse:collapse;width:100%;margin-top:20px}td,th{border-bottom:1px solid #344357;text-align:left;padding:10px;vertical-align:top}.flag{background:#3d3021}.bad{color:#ff9c92}.bar{height:5px;background:#72b8ea;margin-top:5px}small{color:#afbdcd}details a{display:block}h1{margin-bottom:8px}</style>
<h1>Current playback comparison</h1><p id="status"></p><p>Three measurements per scene and target. Software submission timings; GPU/display drops and optical presentation are not measured. Windows skipped steps are reported separately.</p>
<details><summary>Frozen inputs, builds and rendering settings</summary><pre id="provenance"></pre></details>
<p><a href="report.md">Markdown</a> · <a href="measurements.csv">Measurements CSV</a> · <a href="step-timings.csv">Step timing CSV</a> · <a href="manifest.json">Frozen scene manifest</a> · <a href="summary.json">Evidence audit</a></p>
<label>Find scene/game <input id="search"></label> <label>Show <select id="filter"><option value="all">All</option><option value="duration">Duration differences</option><option value="skipped">Repeated skipped steps</option></select></label>
<table><thead><tr><th>Scene and raw evidence</th><th>File timeline</th><th>Windows</th><th>7-inch ESP32</th><th>3.49B ESP32</th><th>Windows skipped steps</th><th>ESP32 step coverage (7-inch / 3.49B)</th></tr></thead><tbody id="rows"></tbody></table>
<script id="data" type="application/json">@PAYLOAD@</script><script>
const data=JSON.parse(document.getElementById('data').textContent),fmt=n=>n==null?'missing':(n/1000).toFixed(3)+' s';
const summary=data.summary,status=document.getElementById('status');status.textContent=`${summary.complete?'Complete':'INCOMPLETE'} · ${summary.sceneCount} scenes · ${summary.measurementCount}/${summary.expectedMeasurements} measurements · ${summary.confirmedDurationPairs} confirmed duration pairs · ${summary.repeatedSkippedStepPairs} repeated skipped-step pairs`;if(!summary.complete)status.className='bad';
document.getElementById('provenance').textContent=JSON.stringify({manifestHash:summary.manifestHash,sceneSetHash:summary.sceneSetHash,buildsHash:summary.buildsHash,settings:summary.settings,renderingPolicy:summary.renderingPolicy,thresholds:summary.thresholds,boards:data.builds},null,2);
const stage=document.createElement('p');stage.textContent='ESP32 software spans: '+Object.entries(summary.softwareStageTimings).map(([board,m])=>`${board}: ${m.steps} steps; loop→decode ${m.medianLoopToDecodedMs?.toFixed(3)??'missing'} ms; decode→submission ${m.medianDecodedToSubmissionMs?.toFixed(3)??'missing'} ms`).join(' · ')+'. The submission span includes overlay and drawing; optical presentation is not measured.';status.after(stage);
function cell(tr,text){const e=document.createElement('td');e.textContent=text;tr.append(e);return e}
function render(){const body=document.getElementById('rows');body.replaceChildren();const query=document.getElementById('search').value.toLowerCase(),filter=document.getElementById('filter').value;for(const e of data.scenes){if(!(e.name+' '+e.game).toLowerCase().includes(query)||filter==='duration'&&!e.confirmedDuration||filter==='skipped'&&!e.repeatedSkippedSteps)continue;const tr=document.createElement('tr');if(e.confirmedDuration)tr.className='flag';const td=cell(tr,`${e.order}. ${e.name}`),details=document.createElement('details'),title=document.createElement('summary');title.textContent=`${e.game} · ${e.category} · ${e.steps} steps`;details.append(title);const hash=document.createElement('small');hash.textContent=`SHA-256 ${e.sha256}`;details.append(hash);for(const target of ['windows','Waveshare7','Waveshare349B'])for(const path of e.metrics[target].paths){const a=document.createElement('a');a.href=path;a.textContent=target+' raw capture';details.append(a)}td.append(details);cell(tr,fmt(e.expectedMs));const max=Math.max(...Object.values(e.metrics).map(m=>m.medianMs||0));for(const target of ['windows','Waveshare7','Waveshare349B']){const m=e.metrics[target],c=cell(tr,fmt(m.medianMs)),small=document.createElement('small');small.textContent=` (${m.measurements}/3; ${fmt(m.minMs)}–${fmt(m.maxMs)})`;c.append(small);if(m.medianMs!=null){const bar=document.createElement('div');bar.className='bar';bar.style.width=m.medianMs/max*100+'%';c.append(bar)}}cell(tr,e.metrics.windows.skipped.join(' / ')||'missing');cell(tr,['Waveshare7','Waveshare349B'].map(t=>e.metrics[t].coveredSteps.map(n=>n+'/'+e.steps).join(', ')||'missing').join(' / '));body.append(tr)}}
for(const id of ['search','filter'])document.getElementById(id).addEventListener('input',render);render();</script></html>'''
    (out / 'report.html').write_text(template.replace('@PAYLOAD@', payload), encoding='utf-8')
    print(f'Report: {out / "report.html"} — {"complete" if complete else "INCOMPLETE"}, {len(rows)}/{len(entries) * 9} measurements', flush=True)
    return summary
