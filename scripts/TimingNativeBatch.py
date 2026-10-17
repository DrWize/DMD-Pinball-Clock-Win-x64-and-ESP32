"""Diagnostic-only single-process native Windows batch, imported by SD runner."""
import difflib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
import urllib.request

ROOT=Path(__file__).resolve().parents[1]
PORT=17897

PARTIAL=r'''
using System.Diagnostics;
using DmdClock.Core.Playback;
namespace DmdClock.App;
public partial class MainWindow {
    private readonly record struct TimingSample(long Ticks,int Step,int Frame,bool Blank,bool Completed);
    private readonly TimingSample[] _timingSamples=new TimingSample[8192];
    private int _timingCount;
    private long _timingStart;
    private DateTimeOffset TimingRenderNow() => _timingStart==0 ? DateTimeOffset.Now :
        new DateTimeOffset(2024,1,1,1,0,0,TimeSpan.FromHours(1))+Stopwatch.GetElapsedTime(_timingStart);
    private void TimingRecord() {
        if(_timingStart==0 || _playback is null) return;
        if(_timingCount>=_timingSamples.Length) throw new InvalidOperationException("Timing trace overflow");
        _timingSamples[_timingCount++]=new(Stopwatch.GetTimestamp()-_timingStart,
            _playback.TimingStepIndex,_playback.CurrentFrameIndex,_playback.IsBlank,_playback.IsComplete);
    }
    private void TimingLoad(string? requested) {
        var root=Path.GetFullPath(Environment.GetEnvironmentVariable("DMD_TIMING_FIXTURES") ?? throw new InvalidOperationException("Missing fixture root"))+Path.DirectorySeparatorChar;
        var path=Path.GetFullPath(requested ?? throw new ArgumentException("Missing scene path"));
        if(!path.StartsWith(root,StringComparison.OrdinalIgnoreCase) || !path.EndsWith(".scn",StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Invalid fixture path");
        var scene=LoadPlaybackScene(path).Scene;
        _timingCount=0;_timingStart=Stopwatch.GetTimestamp();
        BeginScene(scene,path);TimingRecord();
    }
}
'''

def load_module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

def prepare(out):
    (out/'source/src/DmdClock.App/MainWindow.TimingBatch.cs').unlink(missing_ok=True)
    native=load_module('native_pilot',ROOT/'scripts/Compare-NativeWindowsPlayback.py');native.NAMES=[];native.prepare(out)
    source=out/'source';changes=[]
    def edit(relative,old,new):
        p=source/relative;before=p.read_text()
        if old not in before:raise RuntimeError(f'Missing native batch anchor: {relative}: {old}')
        after=before.replace(old,new);p.write_text(after)
        changes.extend(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile=relative,tofile='timing/'+relative))
    # ScenePath is part of the normal playback API from v1.9.0 onward.
    edit('src/DmdClock.App/Diagnostics/DebugApiServer.cs','SceneResult? Scene, SceneResult? LastSceneResult);','SceneResult? Scene, SceneResult? LastSceneResult, object? TimingTrace = null);')
    edit('src/DmdClock.Core/Playback/ScenePlaybackSession.cs','private int _stepIndex;','private int _stepIndex;\n    public int TimingStepIndex => _stepIndex; // isolated diagnostic getter')
    edit('src/DmdClock.App/MainWindow.axaml.cs','var localNow = DateTimeOffset.Now;','var localNow = TimingRenderNow();')
    edit('src/DmdClock.App/MainWindow.axaml.cs','if (_playback.IsComplete) HandlePlaybackCompleted();','TimingRecord();\n            if (_playback.IsComplete) HandlePlaybackCompleted();')
    edit('src/DmdClock.App/MainWindow.axaml.cs','private void StartLibraryWatcher()\n    {','private void StartLibraryWatcher()\n    {\n        if(Environment.GetEnvironmentVariable("DMD_TIMING_FIXTURES") is not null) return;')
    edit('src/DmdClock.App/MainWindow.Diagnostics.cs','RenderPlaybackFrame(DateTimeOffset.Now)','RenderPlaybackFrame(TimingRenderNow())')
    edit('src/DmdClock.App/MainWindow.Diagnostics.cs','switch (command.Action)\n        {','''if(command.Action=="timing-ready") return Snapshot() with { TimingTrace=new { ready=_libraryIndex is not null && _scanGate.CurrentCount==1 && !_startupBrandVisible } };
        if(command.Action=="timing-export") {
            if(_playback is not null) throw new InvalidOperationException("Scene still active");
            return Snapshot() with { TimingTrace=new { frequency=System.Diagnostics.Stopwatch.Frequency,
                samples=_timingSamples.Take(_timingCount).ToArray() } };
        }
        switch (command.Action)
        {
            case "timing-load": TimingLoad(command.ScenePath); break;''')
    (source/'src/DmdClock.App/MainWindow.TimingBatch.cs').write_text(PARTIAL)
    (out/'batch-instrumentation.patch').write_text(''.join(changes))
    with (out/'batch-build.log').open('w') as stream:
        subprocess.run(['dotnet','build',source/'src/DmdClock.App/DmdClock.App.csproj','-c','Release','--nologo'],stdout=stream,stderr=subprocess.STDOUT,check=True)
    hashes={str(p.relative_to(source)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (source/'src').rglob('*') if p.is_file() and 'bin' not in p.parts and 'obj' not in p.parts}
    (out/'source-hashes.json').write_text(json.dumps(hashes,indent=2))

class Batch:
    def __init__(self,out):self.out=out;self.process=None
    def __enter__(self):
        self.token=secrets.token_hex(32);data=self.out/'batch-data/DmdClock';data.mkdir(parents=True,exist_ok=True)
        self.fixtures=self.out/'fixtures';self.fixtures.mkdir(exist_ok=True)
        (self.fixtures/'scene-metadata.json').write_bytes((ROOT/'scenes/scene-metadata.json').read_bytes())
        settings=dict(schemaVersion=1,automaticCycle=False,randomPlayback=False,clockDisplaySeconds=3600,animationsPerCycle=1,
            animationGapSeconds=0,colorPreset=0,brightnessPercent=100,glowEnabled=True,showAnimationInfo=False,
            language='en',clockFormat='24',dateFormat='yyyy-MM-dd',showSeconds=False,showTitleBar=True,
            foregroundColor=None,backgroundColor='#000000',windowScalePercent=100,fullscreenZoomPercent=100,
            animationDirectory=str(self.fixtures.resolve()),plasmaPalette=0,plasmaCycleMilliseconds=8000,hotCoreEnabled=False,
            apiEnabled=True,apiPort=PORT,apiToken=self.token)
        (data/'settings.json').write_text(json.dumps(settings,indent=2))
        env=dict(os.environ,DMD_TIMING_DATA=str(data.parent.resolve()),DMD_TIMING_FIXTURES=str(self.fixtures.resolve()))
        exe=self.out/'source/src/DmdClock.App/bin/Release/net10.0/DmdClock.App.exe'
        self.log=(self.out/'batch-process.log').open('a')
        self.process=subprocess.Popen([str(exe.resolve())],cwd=exe.parent,env=env,stdout=self.log,stderr=subprocess.STDOUT)
        try:
            deadline=time.monotonic()+120
            while time.monotonic()<deadline:
                if self.process.poll() is not None:raise RuntimeError('Native app exited at startup')
                try:
                    state=self.api('/api/playback',dict(action='timing-ready'))
                    if state['timingTrace']['ready']:return self
                except (OSError,TimeoutError):time.sleep(.1)
                time.sleep(.1)
            raise RuntimeError('Native API did not become ready')
        except BaseException:self.__exit__(None,None,None);raise
    def api(self,path,body=None):
        request=urllib.request.Request(f'http://127.0.0.1:{PORT}'+path,data=None if body is None else json.dumps(body).encode(),
            headers={'Authorization':'Bearer '+self.token,'Content-Type':'application/json'})
        with urllib.request.urlopen(request,timeout=10) as response:return json.loads(response.read())
    def play(self,entry,repetition):
        fixture=self.fixtures/entry['name']
        if hashlib.sha256(fixture.read_bytes()).hexdigest()!=entry['sha256']:raise RuntimeError('Windows fixture hash mismatch')
        start=time.monotonic();self.api('/api/playback',dict(action='timing-load',scenePath=str(fixture.resolve())))
        deadline=start+max(30,entry['expectedMs']/1000*3+20)
        while time.monotonic()<deadline:
            if self.process.poll() is not None:raise RuntimeError('Native app exited during playback')
            state=self.api('/api/state');result=state.get('lastSceneResult')
            if result and result['timing']['completed']:break
            time.sleep(.1)
        else:raise RuntimeError('Native scene timeout')
        timing=result['timing']
        if result['file']!=entry['name'] or timing['speed']!=1 or timing['status']!='Completed' or timing['expectedDurationMs']!=entry['expectedMs']:raise RuntimeError('Invalid native completion')
        trace=self.api('/api/playback',dict(action='timing-export'))['timingTrace']
        if not trace['samples'] or not trace['samples'][-1]['completed']:raise RuntimeError('Missing native trace completion')
        return dict(schemaVersion=1,name=entry['name'],sha256=entry['sha256'],repeat=repetition,appVersion=state['appVersion'],renderClockStart='2024-01-01T01:00:00+01:00',timing=timing,trace=trace,hostElapsedMs=(time.monotonic()-start)*1000)
    def __exit__(self,*arguments):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:self.process.kill();self.process.wait()
        if hasattr(self,'log'):self.log.close()
