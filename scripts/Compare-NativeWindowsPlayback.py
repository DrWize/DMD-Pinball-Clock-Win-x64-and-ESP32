"""Measure the current native Windows app using isolated settings and its debug API.

The copied app differs only in data-path isolation and loopback API binding.
Native Avalonia windows are displayed during the measurement. Installed settings
and production source are not changed.
"""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import time
import urllib.request

ROOT=Path(__file__).resolve().parents[1]
NAMES=['afm01.scn','APOLLO_13_009.scn','RD1116.scn','RD1474.scn']
PORT=17897
PRESETS=[0,2]
REPEATS=2
SCREENSHOTS=True


def prepare(out):
    source=out/'source';source.mkdir(parents=True,exist_ok=True)
    shutil.copytree(ROOT/'src',source/'src',ignore=shutil.ignore_patterns('bin','obj'),dirs_exist_ok=True)
    shutil.copytree(ROOT/'assets',source/'assets',dirs_exist_ok=True)
    shutil.copyfile(ROOT/'Directory.Build.props',source/'Directory.Build.props')
    (source/'scenes').mkdir(exist_ok=True)
    for name in ['catalog.json','scene-metadata.json']:shutil.copyfile(ROOT/'scenes'/name,source/'scenes'/name)
    changes=[]
    for relative,old,new in [
        ('src/DmdClock.App/MainWindow.axaml.cs','Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)',
         '(Environment.GetEnvironmentVariable("DMD_TIMING_DATA") ?? throw new InvalidOperationException("Missing isolated timing data directory"))'),
        ('src/DmdClock.App/Diagnostics/DebugApiServer.cs','options.ListenAnyIP(port);','options.ListenLocalhost(port);')]:
        p=source/relative;before=p.read_text()
        if old not in before:raise RuntimeError(f'Isolation anchor missing: {relative}')
        after=before.replace(old,new);p.write_text(after)
        changes.extend(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile=relative,tofile=f'isolated/{relative}'))
    (out/'isolation.patch').write_text(''.join(changes))
    manifest=[]
    for name in NAMES:
        p=out/'fixtures'/Path(name).stem/name;p.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(ROOT/'scenes'/name,p)
        manifest.append(dict(name=name,sha256=hashlib.sha256(p.read_bytes()).hexdigest()))
    (out/'scene-manifest.json').write_text(json.dumps(manifest,indent=2))
    (out/'source-hashes.json').write_text(json.dumps({str(p.relative_to(source)):hashlib.sha256(p.read_bytes()).hexdigest()
        for p in (source/'src').rglob('*') if p.is_file()},indent=2))
    project=source/'src/DmdClock.App/DmdClock.App.csproj'
    with (out/'build.log').open('w') as log:
        subprocess.run(['dotnet','build',str(project),'-c','Release','--nologo'],stdout=log,stderr=subprocess.STDOUT,check=True)
    print(f'Native test app built: {out}',flush=True)


def run(out):
    exe=out/'source/src/DmdClock.App/bin/Release/net10.0/DmdClock.App.exe'
    manifest=json.loads((out/'scene-manifest.json').read_text())
    results=[]
    for entry in manifest:
      for preset in PRESETS:
        fixture=out/'fixtures'/Path(entry['name']).stem/entry['name']
        if hashlib.sha256(fixture.read_bytes()).hexdigest()!=entry['sha256']:raise RuntimeError('Changed scene fixture')
        case=out/'cases'/f'{fixture.stem}-{preset}'
        data=case/'data/DmdClock';data.mkdir(parents=True,exist_ok=True)
        token=secrets.token_hex(32)
        settings=dict(schemaVersion=1,automaticCycle=True,randomPlayback=False,clockDisplaySeconds=5,animationsPerCycle=1,
            animationGapSeconds=0,colorPreset=preset,brightnessPercent=100,glowEnabled=True,showAnimationInfo=False,
            language='en',clockFormat='24',dateFormat='yyyy-MM-dd',showSeconds=False,showTitleBar=True,
            foregroundColor=None,backgroundColor='#000000',windowScalePercent=100,fullscreenZoomPercent=100,
            animationDirectory=str(fixture.parent),plasmaPalette=0,plasmaCycleMilliseconds=8000,hotCoreEnabled=False,
            apiEnabled=True,apiPort=PORT,apiToken=token)
        (data/'settings.json').write_text(json.dumps(settings,indent=2))
        env=dict(os.environ,DMD_TIMING_DATA=str(data.parent))
        def api(path,body=None):
            request=urllib.request.Request(f'http://127.0.0.1:{PORT}'+path,
                data=None if body is None else json.dumps(body).encode(),
                headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
            with urllib.request.urlopen(request,timeout=5) as response:
                raw=response.read()
                return raw if path.startswith('/api/screenshot') else json.loads(raw)
        with (case/'process.log').open('w') as log:
          process=subprocess.Popen([str(exe)],cwd=exe.parent,env=env,stdout=log,stderr=subprocess.STDOUT)
          try:
            for repeat in range(REPEATS):
                if repeat:api('/api/playback',dict(action='restart'))
                deadline=time.monotonic()+180
                states=[];captured=False;completed=None
                while time.monotonic()<deadline:
                    if process.poll() is not None:raise RuntimeError(f'Native app exited: {case}')
                    try:state=api('/api/state')
                    except (OSError,TimeoutError):time.sleep(.05);continue
                    states.append(state)
                    scene=state.get('scene')
                    if SCREENSHOTS and scene and not captured and repeat==0:
                        (case/'native-frame.png').write_bytes(api('/api/screenshot'))
                        captured=True
                    completed=state.get('lastSceneResult')
                    if completed and completed['timing']['completed']:
                        break
                    time.sleep(.025)
                else:raise RuntimeError(f'Native playback timeout: {case}')
                timing=completed['timing']
                if completed['file']!=entry['name'] or timing['speed']!=1 or timing['status']!='Completed':
                    raise RuntimeError('Native run is not a clean 1x completion')
                row=dict(name=entry['name'],preset='Plasma' if preset==2 else 'Basic orange',repeat=repeat,
                    sha256=entry['sha256'],timing=timing,appVersion=state['appVersion'])
                results.append(row)
                (case/f'api-states-{repeat}.json').write_text(json.dumps(states,indent=2))
                (out/'native-measurements.json').write_text(json.dumps(results,indent=2))
                print(f'{entry["name"]} {row["preset"]} repeat={repeat}: expected={timing["expectedDurationMs"]:.3f} ms actual={timing["actualDurationMs"]:.3f} ms skipped={timing["skippedFrames"]}',flush=True)
          finally:
            if process.poll() is None:
                process.terminate()
                try:process.wait(timeout=5)
                except subprocess.TimeoutExpired:process.kill();process.wait()
    print(f'Native Windows playback completed: {len(results)} cases',flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('output',type=Path)
    parser.add_argument('--manifest',type=Path,help='Shared manifest of canonical scene names and hashes')
    parser.add_argument('--basic-only',action='store_true')
    parser.add_argument('--repeats',type=int,default=2)
    parser.add_argument('--no-screenshots',action='store_true',help='Avoid screenshot rendering during timed playback')
    group=parser.add_mutually_exclusive_group();group.add_argument('--prepare-only',action='store_true');group.add_argument('--run-only',action='store_true')
    args=parser.parse_args();out=args.output.resolve()
    if args.manifest:
        entries=json.loads(args.manifest.read_text());NAMES=[e['name'] for e in entries]
        for e in entries:
            if hashlib.sha256((ROOT/'scenes'/e['name']).read_bytes()).hexdigest()!=e['sha256']:raise RuntimeError('Input hash mismatch')
    if args.basic_only:PRESETS=[0]
    REPEATS=args.repeats
    SCREENSHOTS=not args.no_screenshots
    if not args.run_only:prepare(out)
    if not args.prepare_only:run(out)
