"""Isolated playback comparison. Run from any directory with Python and .NET 10."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import io
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'output/verification/playback-comparison' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args])


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    refs = ['186a572', *git('tag', '--list', 'v*', '--sort=version:refname').decode().split(), 'HEAD']
    inventory = []
    for ref in refs:
        app = git('show', f'{ref}:src/DmdClock.App/MainWindow.axaml.cs').decode()
        inventory.append(dict(ref=ref, commit=git('rev-parse', f'{ref}^{{commit}}').decode().strip(),
            session=git('rev-parse', f'{ref}:src/DmdClock.Core/Playback/ScenePlaybackSession.cs').decode().strip(),
            reader=git('rev-parse', f'{ref}:src/DmdClock.Core/Scn/ScnReader.cs').decode().strip(),
            timer16ms='Interval = TimeSpan.FromMilliseconds(16)' in app))
    (OUT / 'version-inventory.json').write_text(json.dumps(inventory, indent=2))
    # A fixed manifest is shared by all three executables. Never use installed settings.
    manifest = []
    for path in sorted((ROOT / 'scenes').rglob('*.scn')):
        manifest.append(dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
    if not manifest:
        raise RuntimeError('No local SCN files found')
    (OUT / 'scene-manifest.json').write_text(json.dumps(manifest, indent=2))
    results = {}
    for label, ref in [('initial', '186a572'), ('v1.8.0', 'v1.8.0'), ('local-v1.9.0', None)]:
        folder = OUT / label
        folder.mkdir(exist_ok=True)
        core = folder / 'Core'
        core.mkdir(exist_ok=True)
        # Copy only source, avoiding existing obj/bin files and repository mutation.
        if ref:
            archive = tarfile.open(fileobj=io.BytesIO(git('archive', ref, 'src/DmdClock.Core')))
            for item in archive.getmembers():
                if item.isfile() and item.name.endswith('.cs'):
                    target = core / Path(item.name).relative_to('src/DmdClock.Core')
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(archive.extractfile(item).read())
        else:
            for source in (ROOT / 'src/DmdClock.Core').rglob('*.cs'):
                relative = source.relative_to(ROOT / 'src/DmdClock.Core')
                if 'obj' in relative.parts or 'bin' in relative.parts:
                    continue
                target = core / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
        # The project is independent of repository-level build properties and NuGet packages.
        (folder / 'Probe.csproj').write_text('''<Project Sdk="Microsoft.NET.Sdk">
<PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework>
<ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable>
<ImportDirectoryBuildProps>false</ImportDirectoryBuildProps>
<ImportDirectoryBuildTargets>false</ImportDirectoryBuildTargets>
</PropertyGroup></Project>''')
        shutil.copyfile(ROOT / 'scripts/PlaybackComparisonProbe.cs', folder / 'Program.cs')
        (folder / 'source-hashes.json').write_text(json.dumps({str(p.relative_to(core)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(core.rglob('*.cs'))}, indent=2))
        built = subprocess.run(['dotnet', 'build', str(folder / 'Probe.csproj'), '-c', 'Release', '--nologo',
            '-p:ImportDirectoryBuildProps=false', '-p:ImportDirectoryBuildTargets=false'], capture_output=True, text=True)
        (folder / 'build.log').write_text(built.stdout + built.stderr)
        if built.returncode:
            raise RuntimeError(f'Build failed: {folder / "build.log"}')
        subprocess.run(['dotnet', str(folder / 'bin/Release/net10.0/Probe.dll'),
            str(OUT / 'scene-manifest.json'), str(folder / 'results.json'), label], check=True)
        results[label] = json.loads((folder / 'results.json').read_text())
        print(f'{label}: {len(results[label]["deterministic"])} deterministic results; {len(results[label]["wallClock"])} wall-clock samples', flush=True)
    reference = results['initial']['deterministic']
    differences = {label: [dict(initial=a, compared=b) for a, b in zip(reference, result['deterministic']) if a != b]
                   for label, result in results.items() if label != 'initial'}
    summary = dict(sceneCount=len(manifest), deterministicCount=len(reference),
                   inventoryConsistent=all(i['session'] == inventory[0]['session'] and i['reader'] == inventory[0]['reader'] and i['timer16ms'] for i in inventory),
                   differences=differences, wallClock={k: v['wallClock'] for k, v in results.items()},
                   controls={k: v['controls'] for k, v in results.items()})
    for label, result in results.items():
        if len(result['deterministic']) != len(reference):
            raise RuntimeError(f'{label}: result count mismatch')
    (OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps({k: v for k, v in summary.items() if k not in ('wallClock', 'controls')}, indent=2))
    print(f'Evidence: {OUT}', flush=True)
    if any(differences.values()):
        raise RuntimeError('Playback differs; inspect summary.json')


if __name__ == '__main__':
    main()
