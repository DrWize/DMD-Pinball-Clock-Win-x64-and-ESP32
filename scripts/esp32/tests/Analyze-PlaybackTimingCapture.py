"""Validate captured ESP32 frame traces against fixture bytes and compare versions."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import statistics
import struct


def expected_steps(data):
    _,frames,boards=struct.unpack_from('<3H',data)
    if boards!=1:raise RuntimeError('Hardware fixture must have one storyboard')
    first,_,blank_first,regular,_,last,_,_=struct.unpack_from('<8H',data,6)
    steps=[]
    if first:steps.append((0,first))
    begin=int(first>0 and not blank_first)
    steps.extend((i,regular or 100) for i in range(begin,frames))
    if last:steps.append((frames-1,last))
    return steps


def parse(evidence,label,manifest):
    text=(evidence/f'{label}-serial.log').read_text()
    if 'TIMING ALL_DONE' not in text:raise RuntimeError(f'{label} is not complete')
    rows=[];current=None;index=None
    for line in text.splitlines():
        if 'TIMING REQUEST ' in line:
            index=int(dict(re.findall(r'(\w+)=([^\s]+)',line))['index'])
        elif 'TIMING RESULT ' in line:
            fields=dict(re.findall(r'(\w+)=([^\s]+)',line))
            current={k:(v if k=='name' else int(v)) for k,v in fields.items()}
            current['steps']=[];current['index']=index
        elif 'TIMING STEP ' in line and current is not None:
            current['steps'].append({k:int(v) for k,v in re.findall(r'(\w+)=([^\s]+)',line)})
        elif line=='TIMING END' and current is not None:
            fixture=manifest[current['index']]
            if not fixture['name'].startswith(current['name']):raise RuntimeError('Scene identity mismatch')
            # Earliest firmware truncates the active filename to its 15-character buffer.
            current['canonicalName']=fixture['name']
            data=(evidence/label/'scenes'/fixture['name']).read_bytes()
            if hashlib.sha256(data).hexdigest()!=fixture['sha256']:raise RuntimeError('Fixture hash mismatch')
            expected=expected_steps(data)
            actual=[(s['frame'],s['delay']) for s in current['steps']]
            if actual!=expected:raise RuntimeError(f'{label}: frame or delay mismatch for {fixture["name"]}')
            if current['count']!=len(expected) or current['expected_steps']!=len(expected):raise RuntimeError('Step count mismatch')
            if any(s['painted']<s['decoded'] or s['decoded']<s['loop'] for s in current['steps']):raise RuntimeError('Invalid paint timestamps')
            current['expectedMs']=sum(delay for _,delay in expected)
            current['actualMs']=(current['end']-current['start'])/1000
            current['medianPaintMs']=statistics.median((s['painted']-s['decoded'])/1000 for s in current['steps'])
            current['meanPaintMs']=statistics.mean((s['painted']-s['decoded'])/1000 for s in current['steps'])
            rows.append(current);current=None
    if len(rows)!=16 or len({(r['index'],r['preset'],r['repeat']) for r in rows})!=16:raise RuntimeError('Incomplete hardware matrix')
    (evidence/f'{label}-validated.json').write_text(json.dumps(rows,indent=2))
    return rows


def main():
    parser=argparse.ArgumentParser();parser.add_argument('evidence',type=Path)
    parser.add_argument('--windows',type=Path,help='Native Windows evidence directory')
    args=parser.parse_args()
    manifest=json.loads((args.evidence/'scene-manifest.json').read_text())
    rows={label:parse(args.evidence,label,manifest) for label in ['oldest','latest']}
    summary=[]
    for index in [1,2,4,7]:
        for preset in [0,1]:
            entry=dict(name=manifest[index]['name'],preset=['Basic orange','Plasma'][preset])
            for label in rows:
                samples=[r for r in rows[label] if r['index']==index and r['preset']==preset]
                entry[label]=dict(expectedMs=samples[0]['expectedMs'],meanMs=statistics.mean(r['actualMs'] for r in samples),
                    minMs=min(r['actualMs'] for r in samples),maxMs=max(r['actualMs'] for r in samples),
                    meanPaintMs=statistics.mean(r['meanPaintMs'] for r in samples),samples=len(samples))
            entry['durationChangePercent']=(entry['latest']['meanMs']/entry['oldest']['meanMs']-1)*100
            entry['newSpeedRelativeToOld']=entry['oldest']['meanMs']/entry['latest']['meanMs']
            summary.append(entry)
    output=dict(board='User-confirmed Waveshare ESP32-S3-Touch-LCD-7, MAC 3c:0f:02:c3:59:d8',
        snapshots=json.loads((args.evidence/'probe-source.json').read_text()),casesPerVersion=16,
        verifiedStepsPerVersion={k:sum(len(r['steps']) for r in v) for k,v in rows.items()},summary=summary)
    (args.evidence/'hardware-summary.json').write_text(json.dumps(output,indent=2))
    lines=['| Scene | Mode | File timing | Oldest measured | v1.8.0 measured | Duration change |',
           '| --- | --- | ---: | ---: | ---: | ---: |']
    for r in summary:
        lines.append(f'| {r["name"]} | {r["preset"]} | {r["oldest"]["expectedMs"]/1000:.3f} s | {r["oldest"]["meanMs"]/1000:.3f} s | {r["latest"]["meanMs"]/1000:.3f} s | {r["durationChangePercent"]:+.1f}% |')
    (args.evidence/'hardware-results.md').write_text('\n'.join(lines)+'\n')
    print('\n'.join(lines))
    print('All scene hashes, ordered frame/delay sequences and paint timestamps validated.')
    if args.windows:
        native=json.loads((args.windows/'native-measurements.json').read_text())
        if len(native)!=16:raise RuntimeError('Incomplete native Windows matrix')
        comparison=[]
        for row in summary:
            measured=[r for r in native if r['name']==row['name'] and r['preset']==row['preset']]
            if len(measured)!=2:raise RuntimeError('Missing native scene/mode repetitions')
            fixture=next(f for f in manifest if f['name']==row['name'])
            if any(r['sha256']!=fixture['sha256'] or r['timing']['speed']!=1 or r['timing']['expectedDurationMs']!=row['oldest']['expectedMs'] for r in measured):
                raise RuntimeError('Native Windows input/timing mismatch')
            win=statistics.mean(r['timing']['actualDurationMs'] for r in measured)
            comparison.append(dict(name=row['name'],preset=row['preset'],fileMs=row['oldest']['expectedMs'],
                oldEsp32Ms=row['oldest']['meanMs'],newEsp32Ms=row['latest']['meanMs'],nativeWindowsMs=win,
                windowsSpeedRelativeToOldEsp32=row['oldest']['meanMs']/win,
                windowsSkippedFrames=[r['timing']['skippedFrames'] for r in measured]))
        (args.evidence/'cross-platform-summary.json').write_text(json.dumps(comparison,indent=2))
        lines=['| Scene | Mode | Old ESP32 | Native Windows 1x | Windows speed relative to old ESP32 |',
            '| --- | --- | ---: | ---: | ---: |']
        for r in comparison:lines.append(f'| {r["name"]} | {r["preset"]} | {r["oldEsp32Ms"]/1000:.3f} s | {r["nativeWindowsMs"]/1000:.3f} s | {r["windowsSpeedRelativeToOldEsp32"]:.2f}x |')
        (args.evidence/'cross-platform-results.md').write_text('\n'.join(lines)+'\n')
        print('\n'.join(lines))


if __name__=='__main__':main()
