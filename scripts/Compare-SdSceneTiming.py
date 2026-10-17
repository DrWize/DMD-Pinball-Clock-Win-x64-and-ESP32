"""Autonomous SD-backed ESP32/Windows timing comparison; no AI/network services.

Commands: prepare, all, resume, report, restore. `all` qualifies SD logging with
ten scenes, compares 200 scenes, repeats differences, and expands to the common
full library only when the 200-scene comparison finds no confirmed difference.
The inspected USB identities and stable-driver hybrids come from the pilot.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import ExitStack
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import random
import shutil
import statistics
import struct
import subprocess
import threading
import time
import uuid

ROOT=Path(__file__).resolve().parents[1]

def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m

PILOT=module('timing_pilot',ROOT/'scripts/Compare-SceneTiming.py')
NATIVE=module('timing_native_batch',ROOT/'scripts/TimingNativeBatch.py')
ANALYZER=module('timing_expected',ROOT/'scripts/esp32/tests/Analyze-PlaybackTimingCapture.py')
BOARDS=PILOT.BOARDS
TARGETS=[f'{b}/{v}' for b in BOARDS for v in ['oldest','latest']]+['windows']
PILOT_NAMES=['afm01.scn','APOLLO_13_009.scn','RD0959.scn','RD1116.scn','RD0033.scn','RD1448.scn','RD1474.scn','RD1695.scn','got03.scn','RD1891.scn']
PAIRS=[(f'{b}/{v}','windows') for b in BOARDS for v in ['oldest','latest']]+[(f'{b}/oldest',f'{b}/latest') for b in BOARDS]+[(f'Waveshare7/{v}',f'Waveshare349B/{v}') for v in ['oldest','latest']]
STOP=threading.Event()

def save(path,value):path.parent.mkdir(parents=True,exist_ok=True);PILOT.save(path,value)
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def now():return datetime.now(timezone.utc).isoformat()

def local_inventory():
    metadata=json.loads((ROOT/'scenes/scene-metadata.json').read_text());files=metadata.get('files',{});rows=[]
    for p in sorted((ROOT/'scenes').rglob('*.scn')):
        data=p.read_bytes();version,frames,boards=struct.unpack_from('<3H',data)
        first,_,blank_first,delay,_,last,_,blank_last=struct.unpack_from('<8H',data,6)
        steps=ANALYZER.expected_steps(data)
        if version!=1 or not 0<frames<=512 or boards!=1:raise RuntimeError(f'Unsupported local SCN: {p}')
        offset=6+boards*36
        for _ in range(frames):
            width,height,bpp,mask=struct.unpack_from('<4H',data,offset)
            if (width,height,bpp)!=(128,32,4) or mask not in [0,1]:raise RuntimeError(f'Invalid local frame: {p}')
            offset+=8+2048+mask*512
        if offset!=len(data):raise RuntimeError(f'Unexpected local SCN length: {p}')
        entry=files.get(p.name,files.get(p.name.lower(),{})) if isinstance(files,dict) else {}
        game=entry.get('game') if isinstance(entry,dict) else None
        if not game:
            game=next((r.get('game') for r in metadata.get('prefixes',[]) if p.name.lower().startswith(r['prefix'].lower())),None)
        sha=hashlib.sha256(data).hexdigest();case_id=hashlib.sha256((p.name+'\0'+sha).encode()).hexdigest()[:24]
        rows.append(dict(name=p.name,path=str(p),sha256=sha,bytes=len(data),frames=frames,steps=len(steps),expectedMs=sum(d for _,d in steps),
            regularDelayMs=delay,effectiveDelayMs=delay or 100,firstHoldMs=first,lastHoldMs=last,blankFirst=bool(blank_first),blankLast=bool(blank_last),
            game=game or 'Unknown',caseId=case_id))
    if len({r['name'].casefold() for r in rows})!=len(rows):raise RuntimeError('Duplicate local basenames need explicit resolution')
    return rows

def initialize(out):
    out.mkdir(parents=True,exist_ok=True)
    if not (out/'run.json').exists():
        save(out/'run.json',dict(schemaVersion=2,runId=uuid.uuid4().hex,createdAtUtc=now(),seed=200,initialScenes=200,
            mode='Basic orange',speed=1,thresholdPercent=5,thresholdMs=50,boards=BOARDS,oldQualification='Old playback with stable panel/board/SD drivers and diagnostic scene selection; hybrid',
            clock='Each case starts at 2024-01-01 00:00:00; playback clocks remain monotonic',logging='RAM during playback; SD file commit afterward; USB collection afterward'))
        save(out/'local-inventory.json',local_inventory())
    return json.loads((out/'run.json').read_text())

def prepare(out):
    initialize(out)
    for board in BOARDS:
        if not (out/board/'probe-source.json').exists():
            PILOT.command([PILOT.PYTHON,ROOT/'scripts/esp32/tests/Prepare-PlaybackTimingComparison.py','--sd-log','--stable-board',board,'--output',out/board],out/f'{board}-prepare.log')
        if not json.loads((out/board/'probe-source.json').read_text()).get('sdLog'):raise RuntimeError('Not SD diagnostic firmware')
    if not (out/'windows/source/src/DmdClock.App/MainWindow.TimingBatch.cs').exists():NATIVE.prepare(out/'windows')
    PILOT.build_all(out)
    freeze_builds(out)

def freeze_builds(out):
    records={}
    for board in BOARDS:
        for version in ['oldest','latest']:
            folder=out/board/version;main=folder/'firmware/dmdclock-esp32/main';build=main.parent/'build-timing'
            sources={str(p.relative_to(main)):digest(p) for p in main.rglob('*') if p.is_file() and p.suffix in ['.c','.h','.txt','.yml']}
            images=json.loads((build/'flasher_args.json').read_text())['flash_files']
            records[f'{board}/{version}']=dict(sources=sources,images={offset:dict(path=name,sha256=digest(build/name)) for offset,name in images.items()},sdkconfigSha256=digest(build/'config/sdkconfig.h'))
    records['windows']=dict(sources=json.loads((out/'windows/source-hashes.json').read_text()),exeSha256=digest(out/'windows/source/src/DmdClock.App/bin/Release/net10.0/DmdClock.App.exe'))
    save(out/'frozen-builds.json',records)

def verify_builds(out):
    records=json.loads((out/'frozen-builds.json').read_text())
    for board in BOARDS:
        for version in ['oldest','latest']:
            record=records[f'{board}/{version}'];main=out/board/version/'firmware/dmdclock-esp32/main';build=main.parent/'build-timing'
            for name,sha in record['sources'].items():
                if digest(main/name)!=sha:raise RuntimeError('Prepared source changed; start a new run')
            for image in record['images'].values():
                if digest(build/image['path'])!=image['sha256']:raise RuntimeError('Firmware image changed; start a new run')
            if digest(build/'config/sdkconfig.h')!=record['sdkconfigSha256']:raise RuntimeError('Firmware configuration changed')
    source=out/'windows/source'
    for name,sha in records['windows']['sources'].items():
        if digest(source/name)!=sha:raise RuntimeError('Prepared Windows source changed')
    if digest(source/'src/DmdClock.App/bin/Release/net10.0/DmdClock.App.exe')!=records['windows']['exeSha256']:raise RuntimeError('Native executable changed')

class Link:
    def __init__(self,out,board,version):
        import serial
        self.serial_module=serial;self.out=out;self.board=board;self.version=version;self.pending=b''
        self.log=(out/board/f'{version}-protocol.log').open('a',encoding='utf-8')
        self.port=serial.Serial(port=None,baudrate=115200,timeout=.2);self.port.dtr=False;self.port.rts=False;self.port.port=BOARDS[board]['port']
        for attempt in range(100):
            try:self.port.open();break
            except serial.SerialException:
                if attempt==99:raise
                time.sleep(.2)
    def close(self):self.port.close();self.log.close()
    def send(self,line):self.port.write((line+'\n').encode());self.port.flush()
    def read(self,deadline):
        while time.monotonic()<deadline:
            if b'\n' in self.pending:
                raw,self.pending=self.pending.split(b'\n',1);line=raw.decode(errors='replace').strip();self.log.write(line+'\n');self.log.flush()
                if any(s in line for s in ['Guru Meditation','assert failed','ESP_ERROR_CHECK failed','Task watchdog got triggered']):raise RuntimeError(f'{self.board}: firmware fatal: {line}')
                if line.startswith('TIMING2 '):return line[8:]
            else:self.pending+=self.port.read(4096)
        raise TimeoutError(f'{self.board}/{self.version}: serial response timed out')
    def ready(self):
        stop=time.monotonic()+100
        while time.monotonic()<stop:
            self.send('HELLO')
            try:line=self.read(min(stop,time.monotonic()+3))
            except TimeoutError:continue
            if line.startswith('READY '):
                parts=line.split();source=json.loads((self.out/self.board/'probe-source.json').read_text())['snapshots'][self.version]
                if parts[1:4]!=[self.board,self.version,source] or parts[-1]!='sd=1':raise RuntimeError(f'Board/SD/source readiness failed: {line}')
                return
        raise RuntimeError('Diagnostic firmware not ready')
    def inventory(self):
        self.send('INVENTORY');rows=[];deadline=time.monotonic()+180
        while True:
            line=self.read(deadline)
            if line.startswith('INVENTORY '):
                _,hex_name,size,sha=line.split();rows.append(dict(name=bytes.fromhex(hex_name).decode('ascii'),bytes=int(size),sha256=sha))
                deadline=time.monotonic()+180
            elif line.startswith('INVENTORY_END '):
                _,count,failed=line.split()
                if int(count)!=len(rows) or int(failed):raise RuntimeError(f'Incomplete SD inventory: {line}')
                return rows
            elif line.startswith('ERROR'):raise RuntimeError(line)
    def get(self,run_id,case_id,repetition,version=None):
        self.send(f'GET {run_id} {version or self.version} {case_id} {repetition}');size=None;expected=None;records=[];deadline=time.monotonic()+180
        while True:
            line=self.read(deadline)
            if line=='NOT_FOUND':return None
            if line.startswith('FILE '):_,n,expected=line.split();size=int(n)
            elif line.startswith('RECORD '):records.append(line[7:]+'\n')
            elif line.startswith('FILE_END '):
                data=''.join(records).encode()
                if size!=len(data) or hashlib.sha256(data).hexdigest()!=expected or line.split()[1]!=expected:raise RuntimeError('Collected SD log hash/length mismatch')
                return data
            elif line.startswith('ERROR'):raise RuntimeError(line)
    def play(self,run_id,entry,repetition):
        timeout=max(60000,entry['expectedMs']*3+entry['steps']*250)
        self.send(f"RUN {run_id} {entry['caseId']} {repetition} {entry['sha256']} {entry['name'].encode().hex()} {timeout}")
        deadline=time.monotonic()+timeout/1000+60
        while True:
            line=self.read(deadline)
            if line.startswith('DONE '):
                if line.split()[1]!=entry['caseId']:raise RuntimeError('Unexpected completed case')
                return line
            if line.startswith('ERROR'):raise RuntimeError(line)

class BoardSession:
    def __init__(self,out,board):self.out=out;self.board=board;self.link=None;self.version=None
    def switch(self,version):
        if self.version==version and self.link is not None:return
        if self.link:self.link.close();self.link=None
        PILOT.flash(self.board,version,self.out);self.version=version
        self.link=Link(self.out,self.board,version);self.link.ready()
    def close(self):
        if self.link:self.link.close();self.link=None
        if (self.out/self.board/'restore-required.json').exists():PILOT.restore(self.board,self.out)

def alignment(out,inventory):
    local=json.loads((out/'local-inventory.json').read_text());maps={b:{r['name'].casefold():r for r in inventory[b]} for b in BOARDS}
    if any(len(maps[b])!=len(inventory[b]) for b in BOARDS):raise RuntimeError('Ambiguous duplicate card filenames')
    aligned=[];issues=[]
    for row in local:
        status={b:('missing' if row['name'].casefold() not in maps[b] else 'matching' if maps[b][row['name'].casefold()]['sha256']==row['sha256'] else 'different-content') for b in BOARDS}
        if all(s=='matching' for s in status.values()):aligned.append(row)
        else:issues.append(dict(name=row['name'],localSha256=row['sha256'],status=status,cardFiles={b:maps[b].get(row['name'].casefold()) for b in BOARDS}))
    local_names={r['name'].casefold() for r in local}
    extra={b:[r for r in inventory[b] if r['name'].casefold() not in local_names] for b in BOARDS}
    save(out/'alignment.json',dict(localCount=len(local),matchingCount=len(aligned),issues=issues,extra=extra,cardCounts={b:len(inventory[b]) for b in BOARDS},
        suggestion='Before comparing excluded scenes, back up and synchronize missing/different SCN files from one canonical collection. Do not compensate for different content with speed changes. No scene files were changed.'))
    return aligned

def select_200(rows,seed):
    rows=sorted(rows,key=lambda r:r['name'].casefold())
    if len(rows)<200:raise RuntimeError(f'Only {len(rows)} scenes match both SD cards and Windows; need 200. See alignment.json')
    selected=[];seen=set();rng=random.Random(seed)
    def add(source,number,category):
        count=0
        for row in source:
            if row['caseId'] in seen:continue
            selected.append(dict(row,category=category));seen.add(row['caseId']);count+=1
            if count==number:return
        raise RuntimeError(f'Cannot fill category {category}')
    add(sorted(rows,key=lambda r:(-r['bytes'],r['name'])),50,'largest')
    add(sorted(rows,key=lambda r:(r['effectiveDelayMs'],-r['frames'],r['name'])),50,'fastest')
    golden=[next(r for r in rows if r['name']==name) for name in PILOT_NAMES if any(r['name']==name for r in rows)]
    edges=[r for r in rows if not r['regularDelayMs'] or r['firstHoldMs'] or r['lastHoldMs'] or r['blankFirst'] or r['blankLast']];rng.shuffle(edges)
    zero=[r for r in edges if not r['regularDelayMs']];first=[r for r in edges if r['firstHoldMs']];last=[r for r in edges if r['lastHoldMs']]
    mixed=[]
    for i in range(max(map(len,[zero,first,last]))):
        for group in [zero,first,last]:
            if i<len(group):mixed.append(group[i])
    add(golden+mixed+rows,50,'timing-controls')
    games={}
    for r in rows:games.setdefault(r['game'],[]).append(r)
    order=list(games);rng.shuffle(order)
    for group in games.values():rng.shuffle(group)
    representatives=[]
    while any(games.values()):
        for game in order:
            if games[game]:representatives.append(games[game].pop())
    add(representatives,50,'representative')
    rng.shuffle(selected);return selected

def qualification_entries(aligned,selected):
    lookup={r['name']:r for r in aligned};entries=[lookup[n] for n in PILOT_NAMES if n in lookup]
    seen={r['caseId'] for r in entries}
    for row in selected:
        if len(entries)>=10:break
        if row['caseId'] not in seen:entries.append(row);seen.add(row['caseId'])
    if len(entries)!=10:raise RuntimeError('Need ten distinct matching qualification scenes')
    return entries

def case_path(out,stage,target,entry,repetition):return out/'results'/stage/target/f"{entry['caseId']}-r{repetition}.json"

def validate_hardware(data,entry,board,version,run_id,repetition,out):
    rows=[json.loads(line) for line in data.decode().splitlines()];header=rows[0];result=next(r for r in rows if r['kind']=='result');steps=[r for r in rows if r['kind']=='step']
    if rows[-1]!={'kind':'commit','count':entry['steps']} or header['schemaVersion']!=1:raise RuntimeError('Uncommitted or unsupported SD log')
    source=json.loads((out/board/'probe-source.json').read_text())['snapshots'][version]
    if any([header['runId']!=run_id,header['caseId']!=entry['caseId'],header['board']!=board,header['variant']!=version,header['source']!=source,
        header['sha256']!=entry['sha256'],bytes.fromhex(header['nameHex']).decode()!=entry['name'],header['repeat']!=repetition,header['steps']!=entry['steps'],header['frames']!=entry['frames']]):raise RuntimeError('SD log identity mismatch')
    local=Path(entry['path']).read_bytes()
    if hashlib.sha256(local).hexdigest()!=entry['sha256']:raise RuntimeError('Local scene changed since manifest')
    expected=ANALYZER.expected_steps(local)
    if [(r['frame'],r['delay']) for r in steps]!=expected or [r['n'] for r in steps]!=list(range(len(expected))) or result['count']!=len(expected):raise RuntimeError('Hardware frame/delay sequence mismatch')
    if result['status']!='Completed' or result['start']!=steps[0]['decoded'] or result['end']<=result['start']:raise RuntimeError('Invalid hardware completion')
    for a,b in zip(steps,steps[1:]):
        if b['loop']<a['loop'] or b['decoded']<a['painted']:raise RuntimeError('Hardware trace not monotonic')
    if any(r['painted']<r['decoded'] or r['decoded']<r['loop'] for r in steps) or steps[-1]['painted']>result['end']:raise RuntimeError('Invalid render timestamp')
    paints=[(r['painted']-r['decoded'])/1000 for r in steps];actual=(result['end']-result['start'])/1000
    return dict(target=f'{board}/{version}',name=entry['name'],sha256=entry['sha256'],caseId=entry['caseId'],repeat=repetition,status='Completed',
        expectedMs=entry['expectedMs'],actualMs=actual,frames=entry['frames'],steps=entry['steps'],skipped=0,source=header['source'],
        category=entry.get('category','qualification'),game=entry['game'],regularDelayMs=entry['regularDelayMs'],effectiveDelayMs=entry['effectiveDelayMs'],firstHoldMs=entry['firstHoldMs'],lastHoldMs=entry['lastHoldMs'],
        loadMs=(header['loadEndUs']-header['loadStartUs'])/1000,
        commandToCompletionMs=(result['end']-header['commandUs'])/1000,medianRenderMs=statistics.median(paints),maxRenderMs=max(paints),sdLogSha256=hashlib.sha256(data).hexdigest())

def validate_windows(row,entry,repetition):
    t=row['timing'];trace=row['trace'];samples=trace['samples']
    if row['name']!=entry['name'] or row['sha256']!=entry['sha256'] or row['repeat']!=repetition or t['speed']!=1 or t['status']!='Completed' or not t['completed'] or t['totalSteps']!=entry['steps'] or t['expectedDurationMs']!=entry['expectedMs']:raise RuntimeError('Invalid Windows case')
    if row.get('renderClockStart')!='2024-01-01T01:00:00+01:00':raise RuntimeError('Windows render clock differs from the controlled CET input')
    if not samples or not samples[-1]['completed'] or samples[0]['step']!=0 or any(a['ticks']>b['ticks'] or a['step']>b['step'] for a,b in zip(samples,samples[1:])):raise RuntimeError('Invalid Windows trace')
    if any(not 0<=r['step']<entry['steps'] for r in samples):raise RuntimeError('Windows step out of range')
    expected=ANALYZER.expected_steps(Path(entry['path']).read_bytes())
    blanks=[False]*len(expected)
    if entry['firstHoldMs'] and entry['blankFirst']:blanks[0]=True
    if entry['lastHoldMs'] and entry['blankLast']:blanks[-1]=True
    if any(r['frame']!=(-1 if blanks[r['step']] else expected[r['step']][0]) or r['blank']!=blanks[r['step']] for r in samples):raise RuntimeError('Windows rendered frame/blank sequence mismatch')
    observed_skips=sum(max(0,b['step']-a['step']-1) for a,b in zip(samples,samples[1:]))
    if observed_skips!=t['skippedFrames']:raise RuntimeError('Windows skip counter differs from trace')
    return dict(target='windows',name=entry['name'],sha256=entry['sha256'],caseId=entry['caseId'],repeat=repetition,status='Completed',
        expectedMs=entry['expectedMs'],actualMs=t['actualDurationMs'],frames=entry['frames'],steps=entry['steps'],skipped=t['skippedFrames'],appVersion=row['appVersion'],source=row['appVersion'],
        category=entry.get('category','qualification'),game=entry['game'],regularDelayMs=entry['regularDelayMs'],effectiveDelayMs=entry['effectiveDelayMs'],firstHoldMs=entry['firstHoldMs'],lastHoldMs=entry['lastHoldMs'])

def execute_hardware(session,out,stage,entries,repetitions):
    config=json.loads((out/'run.json').read_text());run_id=config['runId']+'-'+stage
    for version in ['oldest','latest']:
        target=f'{session.board}/{version}'
        cached=True
        for entry in entries:
            for repetition in repetitions:
                path=case_path(out,stage,target,entry,repetition);raw=path.with_suffix('.jsonl')
                if raw.exists():save(path,validate_hardware(raw.read_bytes(),entry,session.board,version,run_id,repetition,out))
                else:cached=False
        if cached:continue
        session.switch(version);link=session.link
        for number,entry in enumerate(entries):
            for repetition in repetitions:
                if STOP.is_set():raise InterruptedError('Stop requested between cases; completed SD records are retained')
                path=case_path(out,stage,target,entry,repetition);raw=path.with_suffix('.jsonl')
                if raw.exists():
                    row=validate_hardware(raw.read_bytes(),entry,session.board,version,run_id,repetition,out);save(path,row);continue
                data=link.get(run_id,entry['caseId'],repetition)
                if data is None:
                    link.play(run_id,entry,repetition);data=link.get(run_id,entry['caseId'],repetition)
                if data is None:raise RuntimeError('Completed case missing from SD')
                row=validate_hardware(data,entry,session.board,version,run_id,repetition,out)
                raw.parent.mkdir(parents=True,exist_ok=True);temporary=raw.with_suffix('.tmp');temporary.write_bytes(data);temporary.replace(raw);save(path,row)
            save(out/session.board/'progress.json',dict(stage=stage,version=version,scene=number+1,total=len(entries),atUtc=now()))
            print(f'{stage} {target}: {number+1}/{len(entries)} {entry["name"]}',flush=True)

def execute_windows(batch,out,stage,entries,repetitions):
    for number,entry in enumerate(entries):
        if STOP.is_set():raise InterruptedError('Stop requested between cases')
        fixture=batch.fixtures/entry['name']
        if not fixture.exists():shutil.copyfile(entry['path'],fixture)
        for repetition in repetitions:
            path=case_path(out,stage,'windows',entry,repetition);raw=path.with_suffix('.native.json')
            if raw.exists():row=validate_windows(json.loads(raw.read_text()),entry,repetition)
            else:
                result=batch.play(entry,repetition);row=validate_windows(result,entry,repetition);save(raw,result)
            save(path,row)
        save(out/'windows/progress.json',dict(stage=stage,scene=number+1,total=len(entries),atUtc=now()))
        print(f'{stage} windows: {number+1}/{len(entries)} {entry["name"]}',flush=True)

def parallel_stage(sessions,batch,out,stage,entries,repetitions):
    errors=[]
    with ThreadPoolExecutor(max_workers=3) as pool:
        tasks={pool.submit(execute_hardware,s,out,stage,entries,repetitions):s.board for s in sessions}
        tasks[pool.submit(execute_windows,batch,out,stage,entries,repetitions)]='windows'
        try:
            for future in as_completed(tasks):
                try:future.result()
                except Exception as error:errors.append(dict(target=tasks[future],error=str(error),atUtc=now()));print(errors[-1],flush=True)
        except BaseException:STOP.set();raise
    if errors:
        save(out/f'{stage}-errors.json',errors);raise RuntimeError(f'{stage} has failed/incomplete cases; restore and inspect errors')
    save(out/f'{stage}-errors.json',[])

def stage_rows(out,stage):
    root=out/'results'/stage
    return [json.loads(p.read_text()) for p in root.rglob('*.json') if not p.name.endswith('.native.json')] if root.exists() else []

def comparisons(rows,entries):
    results=[]
    for entry in entries:
        values={t:sorted([r for r in rows if r['target']==t and r['caseId']==entry['caseId']],key=lambda r:r['repeat']) for t in TARGETS}
        for left,right in PAIRS:
            a=values[left];b=values[right]
            if not a or not b:continue
            am=statistics.median(r['actualMs'] for r in a);bm=statistics.median(r['actualMs'] for r in b);delta=bm-am;pct=delta/am*100
            paired=[(x['actualMs'],y['actualMs']) for x,y in zip(a,b)]
            consistent=sum(abs(y-x)>50 and abs(y/x-1)*100>5 and (y-x)*delta>0 for x,y in paired)
            skip_repeats=sum(r['skipped']>0 for r in a)+sum(r['skipped']>0 for r in b)
            flag=abs(delta)>50 and abs(pct)>5 or skip_repeats>0
            enough_repeats=len(a)>=3 and len(b)>=3
            confirmed_duration=enough_repeats and consistent>=2
            confirmed_skips=enough_repeats and skip_repeats>=2
            confirmed=confirmed_duration or confirmed_skips
            results.append(dict(name=entry['name'],caseId=entry['caseId'],reference=left,compared=right,referenceMedianMs=am,comparedMedianMs=bm,
                durationChangeMs=delta,durationChangePercent=pct,speedRatio=am/bm,flag=flag,confirmed=confirmed,
                confirmedDuration=confirmed_duration,confirmedSkippedFrames=confirmed_skips,referenceSamples=len(a),comparedSamples=len(b),
                referenceSpreadMs=max(r['actualMs'] for r in a)-min(r['actualMs'] for r in a),comparedSpreadMs=max(r['actualMs'] for r in b)-min(r['actualMs'] for r in b),
                referenceSkipped=[r['skipped'] for r in a],comparedSkipped=[r['skipped'] for r in b]))
    return results

def run_unlocked(out,reuse_inventory=False):
    config=initialize(out);verify_builds(out)
    # Both fresh full backups must exist before the first firmware write.
    with ThreadPoolExecutor(max_workers=2) as pool:
        for future in as_completed([pool.submit(PILOT.backup,b,out) for b in BOARDS]):future.result()
    sessions=[BoardSession(out,b) for b in BOARDS];failures=[]
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            for future in as_completed([pool.submit(s.switch,'latest') for s in sessions]):future.result()
        inventory={}
        if reuse_inventory and all((out/f'{b}-sd-inventory.json').exists() for b in BOARDS):
            inventory={b:json.loads((out/f'{b}-sd-inventory.json').read_text()) for b in BOARDS}
            save(out/'inventory-validation.json',dict(mode='Frozen inventory reused on resume; every newly measured scene is verified against loaded bytes before and after playback',atUtc=now()))
        else:
            with ThreadPoolExecutor(max_workers=2) as pool:
                tasks={pool.submit(s.link.inventory):s.board for s in sessions}
                for future in as_completed(tasks):inventory[tasks[future]]=future.result();save(out/f'{tasks[future]}-sd-inventory.json',inventory[tasks[future]])
            save(out/'inventory-validation.json',dict(mode='Full inventory hashed from both cards',atUtc=now()))
        aligned=alignment(out,inventory)
        if (out/'selected-200.json').exists():
            selected=json.loads((out/'selected-200.json').read_text());current={(r['name'],r['sha256']) for r in aligned}
            if any((r['name'],r['sha256']) not in current for r in selected):raise RuntimeError('Selected card content changed since this run began')
        else:selected=select_200(aligned,config['seed']);save(out/'selected-200.json',selected)
        qualification=qualification_entries(aligned,selected)
        save(out/'qualification-10.json',qualification)
        fixtures=out/'windows/fixtures';fixtures.mkdir(exist_ok=True)
        for entry in aligned:
            path=fixtures/entry['name']
            if not path.exists():shutil.copyfile(entry['path'],path)
            if digest(path)!=entry['sha256']:raise RuntimeError('Frozen Windows fixture differs from aligned manifest')
        with NATIVE.Batch(out/'windows') as batch:
            parallel_stage(sessions,batch,out,'qualify',qualification,[0])
            if any(sum(r['target']==t for r in stage_rows(out,'qualify'))!=10 for t in TARGETS):raise RuntimeError('Qualification coverage incomplete')
            save(out/'qualification-passed.json',dict(atUtc=now(),cases=50))
            parallel_stage(sessions,batch,out,'sample',selected,[0])
            first=comparisons(stage_rows(out,'sample'),selected);flagged={r['caseId'] for r in first if r['flag']}
            repeat=[r for r in selected if r['caseId'] in flagged];save(out/'repeat-scenes.json',repeat)
            if repeat:parallel_stage(sessions,batch,out,'sample',repeat,[1,2])
            final=comparisons(stage_rows(out,'sample'),selected);save(out/'sample-comparisons.json',final)
            if any(r['confirmed'] for r in final):
                save(out/'expansion-decision.json',dict(expand=False,reason='Confirmed differences in 200-scene sample; report and recommend alignment before expanding',atUtc=now()))
            elif json.loads((out/'alignment.json').read_text())['issues']:
                save(out/'expansion-decision.json',dict(expand=False,reason='No confirmed sample timing difference, but scene collections differ. Recommend canonical file synchronization before a full-library comparison.',atUtc=now()))
            else:
                full=sorted(aligned,key=lambda r:r['name']);save(out/'full-manifest.json',full)
                save(out/'expansion-decision.json',dict(expand=True,reason='No confirmed differences in sample; testing full matching library',atUtc=now()))
                parallel_stage(sessions,batch,out,'full',full,[0])
                flags={r['caseId'] for r in comparisons(stage_rows(out,'full'),full) if r['flag']}
                repeat_full=[r for r in full if r['caseId'] in flags];save(out/'full-repeat-scenes.json',repeat_full)
                if repeat_full:parallel_stage(sessions,batch,out,'full',repeat_full,[1,2])
    except BaseException as error:
        failures.append(dict(error=str(error),atUtc=now()));raise
    finally:
        with ThreadPoolExecutor(max_workers=2) as pool:
            tasks={pool.submit(s.close):s.board for s in sessions}
            for future in as_completed(tasks):
                try:future.result()
                except Exception as error:failures.append(dict(target=tasks[future],restorationError=str(error),atUtc=now()))
        save(out/'run-errors.json',failures);report(out)

def run(out,reuse_inventory=False):
    import msvcrt
    import ctypes
    out.mkdir(parents=True,exist_ok=True)
    with (out/'run.lock').open('a+b') as lock:
        lock.seek(0);lock.write(b'1');lock.flush();lock.seek(0)
        try:msvcrt.locking(lock.fileno(),msvcrt.LK_NBLCK,1)
        except OSError:raise RuntimeError('A live runner already owns this run; observe it instead of restarting')
        try:
            import os
            previous_power_state=ctypes.windll.kernel32.SetThreadExecutionState(0x80000003)
            save(out/'runner-state.json',dict(pid=os.getpid(),state='running',atUtc=now()))
            run_unlocked(out,reuse_inventory)
        finally:
            save(out/'runner-state.json',dict(pid=os.getpid(),state='stopped',atUtc=now()))
            ctypes.windll.kernel32.SetThreadExecutionState(previous_power_state or 0x80000000)
            lock.seek(0);msvcrt.locking(lock.fileno(),msvcrt.LK_UNLCK,1)

def validated_stage_rows(out,stage,entries):
    rows=[]
    config=json.loads((out/'run.json').read_text()) if (out/'run.json').exists() else {}
    # Re-read raw committed logs; a normalized JSON file alone is not completion proof.
    for entry in entries:
        for target in TARGETS:
            for repetition in [0,1,2]:
                path=case_path(out,stage,target,entry,repetition)
                if target=='windows':
                    raw=path.with_suffix('.native.json')
                    if raw.exists():rows.append(validate_windows(json.loads(raw.read_text()),entry,repetition))
                else:
                    raw=path.with_suffix('.jsonl');board,version=target.split('/')
                    if raw.exists():rows.append(validate_hardware(raw.read_bytes(),entry,board,version,config['runId']+'-'+stage,repetition,out))
    return rows

def report(out):
    import csv
    stage='full' if (out/'full-manifest.json').exists() else 'sample';manifest_path=out/('full-manifest.json' if stage=='full' else 'selected-200.json')
    entries=json.loads(manifest_path.read_text()) if manifest_path.exists() else [];rows=validated_stage_rows(out,stage,entries);comp=comparisons(rows,entries)
    qualification_path=out/'qualification-10.json';qualification_entries_list=json.loads(qualification_path.read_text()) if qualification_path.exists() else []
    qualification_rows=validated_stage_rows(out,'qualify',qualification_entries_list)
    qualification_keys={(r['target'],r['caseId'],r['repeat']) for r in qualification_rows}
    qualification_expected={(t,r['caseId'],0) for t in TARGETS for r in qualification_entries_list}
    qualified=len(qualification_expected)==50 and qualification_expected.issubset(qualification_keys) and (out/'qualification-passed.json').exists()
    expected={(t,r['caseId'],0) for t in TARGETS for r in entries};actual={(r['target'],r['caseId'],r['repeat']) for r in rows}
    missing=sorted(expected-actual);repeat_path=out/('full-repeat-scenes.json' if stage=='full' else 'repeat-scenes.json')
    repeats=json.loads(repeat_path.read_text()) if repeat_path.exists() else []
    repeat_missing=[(t,r['caseId'],n) for r in repeats for t in TARGETS for n in [1,2] if (t,r['caseId'],n) not in actual]
    restoration={b:(out/b/'restored.json').exists() and not (out/b/'restore-required.json').exists() for b in BOARDS}
    errors=json.loads((out/'run-errors.json').read_text()) if (out/'run-errors.json').exists() else None
    complete=bool(entries) and qualified and not missing and not repeat_missing and all(restoration.values()) and errors==[]
    summary=dict(schemaVersion=2,stage=stage,sceneCount=len(entries),measurementCount=len(rows),initialExpected=len(expected),missingInitial=missing,missingRepeats=repeat_missing,
        confirmedDifferencePairs=sum(c['confirmed'] for c in comp),qualificationPassed=qualified,qualificationCases=len(qualification_keys),restored=restoration,complete=complete,atUtc=now())
    summary['confirmedScenes']=len({c['caseId'] for c in comp if c['confirmed']})
    summary['pairSummary']=[]
    for left,right in PAIRS:
        pairs=[c for c in comp if c['reference']==left and c['compared']==right]
        if pairs:summary['pairSummary'].append(dict(reference=left,compared=right,scenes=len(pairs),confirmed=sum(c['confirmed'] for c in pairs),
            confirmedDuration=sum(c['confirmedDuration'] for c in pairs),confirmedSkippedFrames=sum(c['confirmedSkippedFrames'] for c in pairs),
            medianDurationChangePercent=statistics.median(c['durationChangePercent'] for c in pairs),minimumDurationChangePercent=min(c['durationChangePercent'] for c in pairs),maximumDurationChangePercent=max(c['durationChangePercent'] for c in pairs)))
    save(out/'summary.json',summary);save(out/'comparisons.json',comp)
    with (out/'measurements.csv').open('w',newline='',encoding='utf-8') as stream:
        fields=['target','source','name','sha256','repeat','status','category','game','frames','steps','regularDelayMs','effectiveDelayMs','firstHoldMs','lastHoldMs','expectedMs','actualMs','skipped','loadMs','medianRenderMs','maxRenderMs']
        writer=csv.DictWriter(stream,fieldnames=fields,extrasaction='ignore');writer.writeheader();writer.writerows(rows)
    align=json.loads((out/'alignment.json').read_text()) if (out/'alignment.json').exists() else {}
    lines=['# SD scene timing comparison','',f"Stage: **{stage}**, {len(entries)} scenes, {len(rows)} collected measurements. Complete: **{complete}**.",
        'Old builds are stable-driver hybrids. All targets use Basic orange at 1x. Identical SCN bytes are required; cases are aligned by scene hash and step index, not synchronized screen refresh.',
        'ESP32 duration runs from first decode to completion; Windows runs from session start to completion. Loading, SD writes, and USB collection are recorded separately or excluded. Render timestamps are software submissions, not optical proof.',
        f"SD alignment: {align.get('matchingCount','unknown')} matching files; {len(align.get('issues',[]))} local files missing or different on at least one card. See alignment.json.",
        f"Confirmed timing/frame differences in {summary['confirmedScenes']} of the {len(entries)} selected scenes under the repeat criteria below. This is a stress/coverage sample, not a random estimate of the entire library.",'',
        'Pair summary (negative duration change means the compared target finishes sooner):','',
        '| Reference | Compared | Scenes compared | Confirmed duration | Repeated skipped frames | Either | Median duration change |','| --- | --- | ---: | ---: | ---: | ---: | ---: |']
    for pair in summary['pairSummary']:lines.append(f"| {pair['reference']} | {pair['compared']} | {pair['scenes']} | {pair['confirmedDuration']} | {pair['confirmedSkippedFrames']} | {pair['confirmed']} | {pair['medianDurationChangePercent']:+.2f}% |")
    lines+=['',
        '| Scene | File ms | 7 old ms | 7 new ms | 3.49 old ms | 3.49 new ms | Windows ms | Win skipped |','| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for entry in entries:
        values={t:[r for r in rows if r['target']==t and r['caseId']==entry['caseId']] for t in TARGETS}
        numbers=[f"{statistics.median(r['actualMs'] for r in values[t]):.1f}" if values[t] else 'missing' for t in TARGETS]
        skips=','.join(str(r['skipped']) for r in values['windows']) if values['windows'] else 'missing'
        lines.append('| '+' | '.join([entry['name'],str(entry['expectedMs']),*numbers,skips])+' |')
    lines+=['','## Confirmed differences','','| Scene | Reference | Compared | Duration change | Speed ratio | Samples |','| --- | --- | --- | ---: | ---: | ---: |']
    for c in sorted(comp,key=lambda r:-abs(r['durationChangePercent'])):
        if c['confirmed']:lines.append(f"| {c['name']} | {c['reference']} | {c['compared']} | {c['durationChangePercent']:+.1f}% | {c['speedRatio']:.2f}x | {c['referenceSamples']}/{c['comparedSamples']} |")
    lines+=['','## Recommendations','']
    if align.get('issues'):lines.append('- Some SD files do not match Windows. Back up and synchronize those files from one canonical collection before testing the excluded scenes. Do not adjust speed to compensate for different content.')
    windows_differences=[c for c in comp if c['confirmed'] and c['compared']=='windows']
    if windows_differences:
        lines.append('- Windows preserves the SCN timeline and catches up by advancing through overdue steps. ESP32 advances one step per loop and schedules from the current time, so rendering can stretch short-delay scenes. See the [Windows scheduler](windows/source/src/DmdClock.Core/Playback/ScenePlaybackSession.cs) and [ESP32 scheduler](Waveshare7/latest/firmware/dmdclock-esp32/main/dmd_display.c).')
        lines.append('- To eliminate skipped intermediate steps, recommend an optional Windows no-skip mode that advances one step per update and schedules the next delay from that update. This alone will not match ESP32 duration because Windows renders faster. Preserve current timeline-based 1x as a separate mode. This test does not implement that change.')
        lines.append('- A single global speed multiplier cannot reproduce scene-dependent ESP32 rendering delays. Exact timing parity would require choosing a reference board/version and using measured per-step pacing profiles; forcing slow hardware to follow the SCN timeline would instead require frame skipping.')
    if not any(c['confirmed'] for c in comp):lines.append('- No confirmed difference yet. This is conclusive only when all required cases and flagged repeats are present. Full-library expansion is gated on the completed sample.')
    lines+=['',f'Restored to pre-test flash: {restoration}',f'Missing initial cases: {len(missing)}; missing required repeats: {len(repeat_missing)}.',
        'Per-case detail is in measurements.csv; per-step observations and lateness are in step-timings.csv. Review-only measured intervals for the stable 7-inch v1.8.0 target are in esp32-pacing-reference.json. A speed ratio above 1 means the compared target finishes sooner.',
        'Raw logs and normalized per-case results are under results/. This script does not modify scene files or production playback code.']
    (out/'report.md').write_text('\n'.join(lines)+'\n',encoding='utf-8');print(out/'report.md',flush=True)
    write_html(out,summary,entries,rows,comp,align)
    export_step_timings(out,stage,entries)

def export_step_timings(out,stage,entries):
    import csv
    references=[]
    with (out/'step-timings.csv').open('w',newline='',encoding='utf-8') as stream:
        fields=['target','name','sha256','repeat','event','step','frame','requestedDelayMs','expectedElapsedMs','observedElapsedMs','latenessMs','renderMs','omittedStepsBefore']
        writer=csv.DictWriter(stream,fieldnames=fields);writer.writeheader()
        for entry in entries:
            expected=ANALYZER.expected_steps(Path(entry['path']).read_bytes());starts=[];elapsed=0
            for _,delay in expected:starts.append(elapsed);elapsed+=delay
            reference_samples=[]
            for target in TARGETS:
                for repetition in [0,1,2]:
                    path=case_path(out,stage,target,entry,repetition)
                    if target=='windows':
                        raw=path.with_suffix('.native.json')
                        if not raw.exists():continue
                        data=json.loads(raw.read_text());previous=-1
                        for row in data['trace']['samples']:
                            if row['step']==previous and not row['completed']:continue
                            observed=row['ticks']/data['trace']['frequency']*1000;expected_at=entry['expectedMs'] if row['completed'] else starts[row['step']]
                            writer.writerow(dict(target=target,name=entry['name'],sha256=entry['sha256'],repeat=repetition,event='complete' if row['completed'] else 'step',step=row['step'],frame=row['frame'],requestedDelayMs=expected[row['step']][1],
                                expectedElapsedMs=expected_at,observedElapsedMs=observed,latenessMs=observed-expected_at,renderMs='',omittedStepsBefore=max(0,row['step']-previous-1)))
                            previous=row['step']
                    else:
                        raw=path.with_suffix('.jsonl')
                        if not raw.exists():continue
                        data=[json.loads(line) for line in raw.read_text().splitlines()];steps=[r for r in data if r['kind']=='step'];result=next(r for r in data if r['kind']=='result')
                        for row in steps:
                            observed=(row['decoded']-result['start'])/1000
                            writer.writerow(dict(target=target,name=entry['name'],sha256=entry['sha256'],repeat=repetition,event='step',step=row['n'],frame=row['frame'],requestedDelayMs=row['delay'],expectedElapsedMs=starts[row['n']],
                                observedElapsedMs=observed,latenessMs=observed-starts[row['n']],renderMs=(row['painted']-row['decoded'])/1000,omittedStepsBefore=0))
                        if target=='Waveshare7/latest':
                            intervals=[((steps[i+1]['decoded'] if i+1<len(steps) else result['end'])-r['decoded'])/1000 for i,r in enumerate(steps)]
                            reference_samples.append(intervals)
            if reference_samples:
                medians=[statistics.median(sample[i] for sample in reference_samples) for i in range(entry['steps'])]
                references.append(dict(name=entry['name'],sha256=entry['sha256'],samples=len(reference_samples),fileExpectedMs=entry['expectedMs'],referenceDurationMs=sum(medians),stepIntervalsMs=medians))
    save(out/'esp32-pacing-reference.json',dict(schemaVersion=1,purpose='Review-only measured pacing reference; does not configure playback',target='Waveshare7/latest',timingOrigin='first decode',scenes=references))

def write_html(out,summary,entries,rows,comp,align):
    payload=json.dumps(dict(summary=summary,entries=entries,rows=rows,comparisons=comp,alignment=dict(matchingCount=align.get('matchingCount'),issues=len(align.get('issues',[]))),targets=TARGETS)).replace('<','\\u003c')
    template='''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>DMDClock timing comparison</title><style>
body{font:15px system-ui,sans-serif;background:#101722;color:#edf2f7;margin:32px}h1{font-size:26px}p{max-width:1100px;line-height:1.5;color:#c6d1df}
label{margin-right:20px}input,select{padding:9px;background:#202d3e;color:white;border:1px solid #526078;border-radius:5px}
table{border-collapse:collapse;width:100%;margin-top:22px;font-variant-numeric:tabular-nums}th,td{border-bottom:1px solid #304057;padding:11px;text-align:right}th:first-child,td:first-child{text-align:left}th{position:sticky;top:0;background:#182334}
tr.flag td:first-child{border-left:4px solid #ffb454}.bar{height:5px;background:#68afe8;margin-top:5px;border-radius:4px}.windows .bar{background:#e6b85e}.missing{color:#fc9a94}small{color:#a6b7c9}a{color:#8cc8ff}.controls{display:flex;gap:12px;flex-wrap:wrap}.status{padding:15px;background:#202d3e;border-radius:8px;max-width:1100px}
</style><h1>DMDClock playback timing</h1><p id="status" class="status"></p>
<p>Old builds use stable panel and SD drivers: they are historical playback hybrids. Measurements use identical scene bytes, Basic orange, and 1× speed. Bars show duration within each scene; shorter bars finish sooner. These are software measurements, not optical display recordings.</p>
<div class="controls"><label>Scene or game <input id="search" placeholder="Filter scenes"></label><label>Show <select id="filter"><option value="all">All scenes</option><option value="different">Confirmed differences</option></select></label><label>Sort <select id="sort"><option value="ratio">Largest ESP32/Windows duration ratio</option><option value="name">Filename</option><option value="duration">Longest file timeline</option></select></label></div>
<p id="count"></p><table><thead><tr><th>Scene / details</th><th>File timeline</th><th>7-inch old</th><th>7-inch new</th><th>3.49-inch old</th><th>3.49-inch new</th><th>Windows</th><th>Windows skipped</th></tr></thead><tbody id="body"></tbody></table>
<p>Each duration is the median of the recorded repetitions. Confirmed differences require repeated evidence: more than 5% and 50 ms in the same direction in at least two of three measurements, or repeated skipped steps. Raw per-case files remain beside this report. <a href="report.md">Markdown report</a> · <a href="measurements.csv">Measurements CSV</a> · <a href="alignment.json">File alignment details</a></p>
<script id="data" type="application/json">@PAYLOAD@</script><script>
const d=JSON.parse(document.getElementById('data').textContent),median=a=>{a=[...a].sort((x,y)=>x-y);return a.length?(a[Math.floor((a.length-1)/2)]+a[Math.ceil((a.length-1)/2)])/2:null},fmt=v=>v==null?'missing':(v/1000).toFixed(3)+' s';
const different=new Set(d.comparisons.filter(c=>c.confirmed).map(c=>c.caseId));
const scenes=d.entries.map(e=>{const groups=d.targets.map(t=>d.rows.filter(r=>r.caseId===e.caseId&&r.target===t));const values=groups.map(g=>median(g.map(r=>r.actualMs)));return{...e,groups,values,ratio:values[4]?Math.max(...values.slice(0,4).map(v=>v||0))/values[4]:0}});
document.getElementById('status').textContent=`${d.summary.complete?'Complete':'INCOMPLETE'} · ${d.summary.sceneCount} scenes · ${d.summary.measurementCount} measurements · ${different.size} scenes with confirmed differences · ${d.alignment.matchingCount??'?'} matching library files · ${d.alignment.issues} missing/different library files. Boards restored: ${Object.values(d.summary.restored).every(Boolean)?'yes':'not yet'}.`;
function cell(parent,text){let el=document.createElement('td');el.textContent=text;parent.append(el);return el}
function render(){const query=document.getElementById('search').value.toLowerCase(),only=document.getElementById('filter').value==='different',sort=document.getElementById('sort').value;
let list=scenes.filter(e=>(e.name+' '+e.game).toLowerCase().includes(query)&&(!only||different.has(e.caseId)));list.sort((a,b)=>sort==='name'?a.name.localeCompare(b.name):sort==='duration'?b.expectedMs-a.expectedMs:b.ratio-a.ratio);
const body=document.getElementById('body');body.replaceChildren();for(const e of list){let tr=document.createElement('tr');if(different.has(e.caseId))tr.className='flag';let first=cell(tr,'');let name=document.createElement('strong');name.textContent=e.name;first.append(name);let info=document.createElement('details'),title=document.createElement('summary');title.textContent='Details and raw results';info.append(title);let meta=document.createElement('small');meta.textContent=`${e.game} · ${e.category||'full library'} · ${e.frames} frames / ${e.steps} steps · regular delay ${e.regularDelayMs||'0 (100 ms fallback)'} ms · first/last holds ${e.firstHoldMs}/${e.lastHoldMs} ms · SHA-256 ${e.sha256}`;info.append(meta);
e.groups.forEach((g,i)=>g.forEach(r=>{let a=document.createElement('a');a.textContent=` ${d.targets[i]} r${r.repeat}`;a.href=`results/${d.summary.stage}/${d.targets[i]}/${e.caseId}-r${r.repeat}.${i===4?'native.json':'jsonl'}`;a.target='_blank';info.append(document.createElement('br'),a)}));first.append(info);cell(tr,fmt(e.expectedMs));const max=Math.max(...e.values.filter(v=>v!=null));e.values.forEach((v,i)=>{let td=cell(tr,fmt(v));td.className=v==null?'missing':i===4?'windows':'';if(v!=null){let bar=document.createElement('div');bar.className='bar';bar.style.width=(v/max*100)+'%';td.append(bar)}});cell(tr,e.groups[4].map(r=>r.skipped).join(', ')||'missing');body.append(tr)}document.getElementById('count').textContent=`Showing ${list.length} of ${scenes.length} scenes. Duration ratios vary by scene; no single speed factor is assumed.`}
for(const id of ['search','filter','sort'])document.getElementById(id).addEventListener('input',render);render();
</script></html>'''
    (out/'report.html').write_text(template.replace('@PAYLOAD@',payload),encoding='utf-8')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('action',choices=['prepare','all','resume','report','restore','freeze']);parser.add_argument('output',type=Path)
    args=parser.parse_args();out=args.output.resolve()
    if args.action in ['all','resume']:run(out,reuse_inventory=args.action=='resume')
    elif args.action=='restore':
        for b in BOARDS:PILOT.restore(b,out)
    elif args.action=='freeze':initialize(out);freeze_builds(out)
    else:globals()[args.action](out)
