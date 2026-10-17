"""Isolated current Windows renderer; no production settings or clock changes."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


BASE = module('current_native_base', ROOT / 'scripts/TimingNativeBatch.py')
BASE.PORT = 17898


def replace_required(text, old, new):
    if old not in text:
        raise RuntimeError('Windows instrumentation anchor changed: ' + old)
    return text.replace(old, new)


def prepare(out):
    original = BASE.PARTIAL
    partial = replace_required(original, 'new TimingSample[8192]', 'new TimingSample[1024]')
    begin = partial.index('    private DateTimeOffset TimingRenderNow()')
    end = partial.index('    private void TimingRecord()', begin)
    partial = partial[:begin] + '''    private bool _timingDetailed = true;
    private double _timingLoadMs;
    private DateTimeOffset TimingRenderNow() => DateTimeOffset.Now;
''' + partial[end:]
    partial = replace_required(partial, 'if(_timingCount>=_timingSamples.Length)', '''if(_timingCount>0) {
            var last=_timingSamples[_timingCount-1];
            if(last.Step==_playback.TimingStepIndex && last.Completed==_playback.IsComplete) return;
            if(!_timingDetailed && !_playback.IsComplete) return;
        }
        if(_timingCount>=_timingSamples.Length)''')
    partial = replace_required(partial, 'var scene=LoadPlaybackScene(path).Scene;',
        'var loadStart=Stopwatch.GetTimestamp(); var scene=LoadPlaybackScene(path).Scene; _timingLoadMs=Stopwatch.GetElapsedTime(loadStart).TotalMilliseconds;')
    try:
        BASE.PARTIAL = partial
        BASE.prepare(out)
    finally:
        BASE.PARTIAL = original
    source = out / 'source'
    api = source / 'src/DmdClock.App/Diagnostics/DebugApiServer.cs'
    text = replace_required(api.read_text(), 'string? ScenePath = null);', 'string? ScenePath = null, bool Detailed = true);')
    api.write_text(text)
    commands = source / 'src/DmdClock.App/MainWindow.Diagnostics.cs'
    text = replace_required(commands.read_text(), 'case "timing-load": TimingLoad(command.ScenePath); break;',
        'case "timing-load": _timingDetailed=command.Detailed; TimingLoad(command.ScenePath); break;')
    text = replace_required(text, 'samples=_timingSamples.Take(_timingCount).ToArray()',
        'loadMs=_timingLoadMs,samples=_timingSamples.Take(_timingCount).ToArray()')
    commands.write_text(text)
    with (out / 'current-build.log').open('w') as log:
        subprocess.run(['dotnet', 'build', str(source / 'src/DmdClock.App/DmdClock.App.csproj'),
            '-c', 'Release', '--nologo'], stdout=log, stderr=subprocess.STDOUT, check=True)
    hashes = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in (source / 'src').rglob('*') if p.is_file() and not {'bin', 'obj'} & set(p.parts)}
    (out / 'source-hashes.json').write_text(json.dumps(hashes, indent=2))


class Batch(BASE.Batch):
    def play(self, entry, repetition, detailed=True):
        fixture = self.fixtures / entry['name']
        if hashlib.sha256(fixture.read_bytes()).hexdigest() != entry['sha256']:
            raise RuntimeError('Windows fixture hash mismatch')
        start = time.monotonic()
        self.api('/api/playback', dict(action='timing-load', scenePath=str(fixture.resolve()), detailed=detailed))
        deadline = start + max(30, entry['expectedMs'] / 1000 * 5 + entry['steps'] * .5 + 30)
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError('Native Windows process exited during capture')
            state = self.api('/api/state')
            result = state.get('lastSceneResult')
            if result and result['timing']['completed']:
                break
            time.sleep(.1)
        else:
            raise RuntimeError('Native Windows capture timed out')
        timing = result['timing']
        if result['file'] != entry['name'] or timing['speed'] != 1 or timing['status'] != 'Completed':
            raise RuntimeError('Invalid Windows playback completion')
        trace = self.api('/api/playback', dict(action='timing-export'))['timingTrace']
        return dict(schemaVersion=1, name=entry['name'], sha256=entry['sha256'], repeat=repetition,
            detailed=detailed, appVersion=state['appVersion'], timing=timing, trace=trace,
            renderClock='normal local time; no system-clock changes', hostElapsedMs=(time.monotonic() - start) * 1000)
