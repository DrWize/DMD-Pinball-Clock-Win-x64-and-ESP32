"""Local ten-scene hardware/native pilot. No AI calls; large runs are separate.

Use pinned ESP-IDF Python (pyserial) for run. Commands: prepare, run, report.
Hardware identities below are the two inspected devices, not generic COM guesses.
Full backups remain local and may contain credentials. Never commit output.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[1]
PYTHON=ROOT.parent/'.tools/esp-idf/v5.5.2/tools/python/v5.5.2/venv/Scripts/python.exe'
BOARDS={
 'Waveshare7':dict(port='COM4',usbSerial='5B3E087595',mac='3c:0f:02:c3:59:d8',width=800),
 'Waveshare349B':dict(port='COM3',usbSerial='28:84:85:92:B1:34',mac='28:84:85:92:b1:34',width=640),
}

def save(path,value):
    temporary=path.with_suffix(path.suffix+'.tmp')
    temporary.write_text(json.dumps(value,indent=2),encoding='utf-8');temporary.replace(path)

def command(args,log,cwd=None):
    with log.open('w',encoding='utf-8') as stream:
        subprocess.run([str(a) for a in args],cwd=cwd,stdout=stream,stderr=subprocess.STDOUT,check=True)

def identity(board):
    from serial.tools import list_ports
    expected=BOARDS[board]
    match=next((p for p in list_ports.comports() if p.device==expected['port']),None)
    if match is None or match.serial_number!=expected['usbSerial']:
        raise RuntimeError(f'{board}: USB identity differs; refusing flash')

def prepare(out):
    out.mkdir(parents=True,exist_ok=False)
    save(out/'run.json',dict(schemaVersion=1,createdAtUtc=datetime.now(timezone.utc).isoformat(),boards=BOARDS,
        mode='Basic orange',speed=1,scope='10-scene pilot, not a large run',oldQualification='Old playback + stable hardware drivers; hybrid',
        smallBoardEvidence='physical-349b-app/dmdclock349-v2-20260821T134545Z.log matches USB MAC 28:84:85:92:b1:34'))
    for board in BOARDS:
        command([PYTHON,ROOT/'scripts/esp32/tests/Prepare-PlaybackTimingComparison.py','--pilot','--stable-board',board,'--output',out/board],out/f'{board}-prepare.log')
    fixtures=json.loads((out/'Waveshare7/scene-manifest.json').read_text())[1:]
    if fixtures!=json.loads((out/'Waveshare349B/scene-manifest.json').read_text())[1:]:raise RuntimeError('Different board fixtures')
    save(out/'scene-manifest.json',fixtures)
    for board in BOARDS:
        for label in ['oldest','latest']:
            main=out/board/label/'firmware/dmdclock-esp32/main'
            save(out/board/label/'prepared-source-hashes.json',{str(p.relative_to(main)):hashlib.sha256(p.read_bytes()).hexdigest() for p in main.rglob('*') if p.is_file() and p.suffix in ['.c','.h','.txt','.yml']})
    command([PYTHON,ROOT/'scripts/Compare-NativeWindowsPlayback.py',out/'windows','--prepare-only','--manifest',out/'scene-manifest.json','--basic-only','--repeats','1','--no-screenshots'],out/'windows-prepare.log')
    build_all(out)

def build_all(out):
    (out/'prepared.json').unlink(missing_ok=True)
    for board in BOARDS:
        for label in ['oldest','latest']:
            main=out/board/label/'firmware/dmdclock-esp32/main'
            save(out/board/label/'prepared-source-hashes.json',{str(p.relative_to(main)):hashlib.sha256(p.read_bytes()).hexdigest() for p in main.rglob('*') if p.is_file() and p.suffix in ['.c','.h','.txt','.yml']})
    # Finish every compilation before timing. Separate copied projects, no shared build trees.
    def build(board,label):
        project=out/board/label/'firmware/dmdclock-esp32'
        quote=lambda value:"'"+str(value).replace("'","''")+"'"
        expression=f"$ErrorActionPreference='Stop'; & {quote(ROOT/'scripts/esp32/dev/Invoke-Idf.ps1')} -ProjectPath {quote(project)} -IdfArguments @('-B','build-timing','-DPROJECT_VER=1.8.0-pilot-{label}','-DCMAKE_JOB_POOLS=timing_compile=4','-DCMAKE_JOB_POOL_COMPILE=timing_compile','build'); exit $LASTEXITCODE"
        command(['pwsh','-NoProfile','-Command',expression],out/f'{board}-{label}-build.log')
        if not (project/'build-timing/dmdclock_esp32.bin').exists():raise RuntimeError('Build did not produce firmware')
        return f'{board}/{label} built'
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures=[pool.submit(build,b,l) for b in BOARDS for l in ['oldest','latest']]
        for future in as_completed(futures):print(future.result(),flush=True)
    save(out/'prepared.json',dict(complete=True))

def backup(board,out):
    identity(board);info=BOARDS[board];folder=out/board
    path=folder/'pre-test-flash.bin';meta=folder/'pre-test-flash.json'
    if path.exists() or meta.exists():
        if not meta.exists():raise RuntimeError('Partial backup; inspect before retrying')
        m=json.loads(meta.read_text())
        if path.stat().st_size!=16777216 or hashlib.sha256(path.read_bytes()).hexdigest()!=m['sha256']:raise RuntimeError('Backup changed')
        return
    command([PYTHON,'-m','esptool','--chip','esp32s3','--port',info['port'],'--baud','921600','read_flash','0','0x1000000',path],folder/'backup.log')
    log=(folder/'backup.log').read_text()
    if info['mac'] not in log.lower() or path.stat().st_size!=16777216:raise RuntimeError('Backup chip identity/size mismatch')
    save(meta,dict(**info,size=path.stat().st_size,sha256=hashlib.sha256(path.read_bytes()).hexdigest()))

def flash(board,label,out):
    identity(board);build=out/board/label/'firmware/dmdclock-esp32/build-timing'
    config=(build/'config/sdkconfig.h').read_text()
    if f'#define CONFIG_DMD_DISPLAY_WIDTH {BOARDS[board]["width"]}\n' not in config or '#define CONFIG_DMD_QEMU 1' in config:raise RuntimeError('Wrong panel build')
    settings=json.loads((build/'flasher_args.json').read_text())
    if set(settings['flash_files'])!={'0x0','0x8000','0x10000'}:raise RuntimeError('Unexpected flash layout')
    args=[PYTHON,'-m','esptool','--chip','esp32s3','--port',BOARDS[board]['port'],'--baud','921600','write_flash',*settings['write_flash_args']]
    images={}
    for offset,name in settings['flash_files'].items():
        path=build/name;args.extend([offset,path]);images[offset]=hashlib.sha256(path.read_bytes()).hexdigest()
    save(out/board/f'{label}-images.json',images)
    (out/board/'restored.json').unlink(missing_ok=True)
    save(out/board/'restore-required.json',dict(label=label,atUtc=datetime.now(timezone.utc).isoformat()))
    command(args,out/board/f'{label}-flash.log')

def capture(board,label,out):
    import serial
    port=serial.Serial(port=None,baudrate=115200,timeout=.2);port.dtr=False;port.rts=False;port.port=BOARDS[board]['port']
    for attempt in range(50):
        try:port.open();break
        except serial.SerialException:
            if attempt==49:raise
            time.sleep(.2)
    pending=b'';rows=[];current=None;index=None;stop=time.monotonic()+600;done=False
    with port,(out/board/f'{label}-serial.log').open('w',encoding='utf-8') as log:
        while time.monotonic()<stop:
            pending+=port.read(4096)
            while b'\n' in pending:
                raw,pending=pending.split(b'\n',1);line=raw.decode(errors='replace').strip();log.write(line+'\n');log.flush()
                if any(x in line for x in ['TIMING ERROR','Guru Meditation','ESP_ERROR_CHECK failed','assert failed']):
                    try:
                        for _ in range(10):log.write(port.read(4096).decode(errors='replace'));log.flush()
                    except serial.SerialException:pass
                    raise RuntimeError(line)
                if 'TIMING REQUEST ' in line:index=int(dict(re.findall(r'(\w+)=([^\s]+)',line))['index'])
                elif 'TIMING RESULT ' in line:
                    fields=dict(re.findall(r'(\w+)=([^\s]+)',line));current={k:v if k=='name' else int(v) for k,v in fields.items()};current.update(index=index,steps=[])
                elif 'TIMING STEP ' in line and current is not None:current['steps'].append({k:int(v) for k,v in re.findall(r'(\w+)=([^\s]+)',line)})
                elif line=='TIMING END' and current is not None:
                    rows.append(current);current=None;save(out/board/f'{label}-measurements.json',rows)
                    print(f'{board}/{label}: {len(rows)}/10 scenes captured',flush=True)
                elif line=='TIMING ALL_DONE':done=True;break
            if done:break
    if not done or len(rows)!=10:raise RuntimeError(f'{board}/{label}: incomplete capture {len(rows)}/10')

def restore(board,out):
    identity(board);backup(board,out)
    command([PYTHON,'-m','esptool','--chip','esp32s3','--port',BOARDS[board]['port'],'--baud','921600','write_flash','0',out/board/'pre-test-flash.bin'],out/board/'restore.log')
    save(out/board/'restored.json',dict(complete=True,atUtc=datetime.now(timezone.utc).isoformat()))
    (out/board/'restore-required.json').unlink(missing_ok=True)

def run(out):
    if not (out/'prepared.json').exists():raise RuntimeError('Prepare/build phase is incomplete')
    # Back up both boards before writing either one.
    for board in BOARDS:backup(board,out)
    def hardware(board):
        try:
            for label in ['oldest','latest']:
                flash(board,label,out);capture(board,label,out)
        finally:restore(board,out)
    def windows():
        existing=out/'windows/native-measurements.json'
        if existing.exists() and len(json.loads(existing.read_text()))==10:
            print('Windows: retaining completed ten-scene capture (report validates it)',flush=True);return
        command([PYTHON,ROOT/'scripts/Compare-NativeWindowsPlayback.py',out/'windows','--run-only','--manifest',out/'scene-manifest.json','--basic-only','--repeats','1','--no-screenshots'],out/'windows-run.log')
    errors=[]
    with ThreadPoolExecutor(max_workers=3) as pool:
        tasks={pool.submit(hardware,b):b for b in BOARDS};tasks[pool.submit(windows)]='windows'
        for future in as_completed(tasks):
            try:future.result()
            except Exception as error:errors.append(dict(target=tasks[future],error=str(error)));print(errors[-1],flush=True)
    save(out/'errors.json',errors)
    report(out)
    if errors:raise RuntimeError('Pilot has failures; see errors.json')

def report(out):
    spec=importlib.util.spec_from_file_location('analysis',ROOT/'scripts/esp32/tests/Analyze-PlaybackTimingCapture.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    manifest=json.loads((out/'scene-manifest.json').read_text());results=[];counts={}
    for board in BOARDS:
        indexed=json.loads((out/board/'scene-manifest.json').read_text())
        for label in ['oldest','latest']:
            target=f'{board}/{label}';path=out/board/f'{label}-measurements.json';counts[target]=0
            if not path.exists():continue
            seen=set()
            for row in json.loads(path.read_text()):
                fixture=indexed[row['index']];data=(out/board/label/'scenes'/fixture['name']).read_bytes()
                if hashlib.sha256(data).hexdigest()!=fixture['sha256']:raise RuntimeError('Fixture hash mismatch')
                if not fixture['name'].startswith(row['name']) or row['preset']!=0 or row['repeat']!=0 or row['end']<=row['start']:raise RuntimeError('Case identity or timing mismatch')
                expected=module.expected_steps(data)
                actual=[(s['frame'],s['delay']) for s in row['steps']]
                if actual!=expected or row['count']!=len(expected) or row['expected_steps']!=len(expected):raise RuntimeError(f'{target}: sequence mismatch')
                if row['index'] in seen or any(s['painted']<s['decoded'] or s['decoded']<s['loop'] for s in row['steps']):raise RuntimeError('Invalid trace')
                if any(a['loop']>b['loop'] for a,b in zip(row['steps'],row['steps'][1:])) or row['steps'][-1]['painted']>row['end']:raise RuntimeError('Nonmonotonic trace')
                seen.add(row['index']);counts[target]+=1
                results.append(dict(target=target,name=fixture['name'],sha256=fixture['sha256'],expectedMs=sum(d for _,d in expected),actualMs=(row['end']-row['start'])/1000,steps=len(expected),skipped=0))
    path=out/'windows/native-measurements.json';counts['windows']=0
    if path.exists():
        for row in json.loads(path.read_text()):
            fixture=next(f for f in manifest if f['name']==row['name']);t=row['timing']
            expected=sum(d for _,d in module.expected_steps((out/'Waveshare7/oldest/scenes'/row['name']).read_bytes()))
            if row['sha256']!=fixture['sha256'] or t['speed']!=1 or t['status']!='Completed' or t['expectedDurationMs']!=expected:raise RuntimeError('Invalid Windows result')
            counts['windows']+=1;results.append(dict(target='windows',name=row['name'],sha256=row['sha256'],expectedMs=expected,actualMs=t['actualDurationMs'],steps=t['totalSteps'],skipped=t['skippedFrames']))
    sources=json.loads((out/'Waveshare7/probe-source.json').read_text())
    sources['windowsVersions']=sorted({r['appVersion'] for r in json.loads(path.read_text())}) if path.exists() else []
    restoration={board:(out/board/'restored.json').exists() and not (out/board/'restore-required.json').exists() for board in BOARDS}
    measurements_complete=all(c==10 for c in counts.values())
    errors_path=out/'errors.json';errors=json.loads(errors_path.read_text()) if errors_path.exists() else None
    save(out/'summary.json',dict(counts=counts,measurementsComplete=measurements_complete,restored=restoration,
        complete=measurements_complete and all(restoration.values()) and errors==[],sources=sources,results=results))
    import csv
    with (out/'measurements.csv').open('w',newline='',encoding='utf-8') as stream:
        writer=csv.DictWriter(stream,fieldnames=['target','name','sha256','expectedMs','actualMs','steps','skipped']);writer.writeheader();writer.writerows(results)
    lines=['# Ten-scene timing pilot','','Old builds use stable panel drivers and are hybrids. One sample per target/scene.','Software render timestamps are not optical measurements.',
        f"ESP32 sources: oldest `{sources['snapshots']['oldest']}`, newer `{sources['snapshots']['latest']}`. Windows versions: {sources['windowsVersions']}; source hashes are saved under windows/.",
        'The old builds do not reproduce exact historical driver performance. Windows uses its normal wall clock; ESP32 uses the fixed test date. ESP32 starts timing at first-step decode, Windows at session start.',
        ('The first attempt found a test-adapter mutex omission before hardware measurement; it was corrected and rebuilt. Failed-attempt logs are retained separately. The parallel Windows pass is the reported pass.' if (out/'attempts/attempt1-adapter-mutex-failure').exists() else 'All completed attempts are recorded in the run directory.'),'',
        '| Scene | File ms | 7 old ms | 7 new ms | 3.49 old ms | 3.49 new ms | Windows ms | Win skipped |','| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for f in manifest:
        values={r['target']:r for r in results if r['name']==f['name']}
        durations=[f"{values[t]['actualMs']:.1f}" if t in values else 'missing' for t in ['Waveshare7/oldest','Waveshare7/latest','Waveshare349B/oldest','Waveshare349B/latest','windows']]
        nominal=next((r['expectedMs'] for r in values.values()),'?');skips=values.get('windows',{}).get('skipped','?')
        lines.append('| '+' | '.join([f['name'],str(nominal),*durations,str(skips)])+' |')
    comparisons=[]
    for fixture in manifest:
        values={r['target']:r for r in results if r['name']==fixture['name']}
        for left,right in [('Waveshare7/oldest','Waveshare7/latest'),('Waveshare349B/oldest','Waveshare349B/latest'),
            ('Waveshare7/oldest','windows'),('Waveshare7/latest','windows'),('Waveshare349B/oldest','windows'),('Waveshare349B/latest','windows'),
            ('Waveshare7/oldest','Waveshare349B/oldest'),('Waveshare7/latest','Waveshare349B/latest')]:
            if left not in values or right not in values:continue
            a=values[left];b=values[right];delta=b['actualMs']-a['actualMs'];pct=delta/a['actualMs']*100
            comparisons.append(dict(name=fixture['name'],reference=left,compared=right,durationChangeMs=delta,durationChangePercent=pct,
                comparedSpeedRelativeToReference=a['actualMs']/b['actualMs'],flag=abs(delta)>50 and abs(pct)>5 or a['skipped']>0 or b['skipped']>0))
    save(out/'comparisons.json',comparisons)
    lines+=['','## Differences to repeat','','| Scene | Reference | Compared | Duration change | Speed ratio |','| --- | --- | --- | ---: | ---: |']
    for c in comparisons:
        if c['flag']:lines.append(f"| {c['name']} | {c['reference']} | {c['compared']} | {c['durationChangePercent']:+.1f}% | {c['comparedSpeedRelativeToReference']:.2f}x |")
    lines+=['',f'Coverage: {counts}',f'Restored to pre-test flash: {restoration}', '',
        'The ten scenes contain 651 scheduled steps per target; Windows skips overdue intermediate frames rather than stretching its timeline. Within-board old/new differences require repeat measurements before a statistical conclusion.',
        'Both boards are restored only when their restored.json confirms success.','Larger runs and repetition of outliers are separate follow-up work.']
    (out/'report.md').write_text('\n'.join(lines)+'\n',encoding='utf-8');print(out/'report.md',flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('action',choices=['prepare','build','run','report','restore']);parser.add_argument('output',type=Path)
    args=parser.parse_args();out=args.output.resolve()
    if args.action=='restore':
        for board in BOARDS:restore(board,out)
    elif args.action=='build':build_all(out)
    else:globals()[args.action](out)
