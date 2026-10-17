"""Verify SD checkpoint collection after firmware restoration; never rerun timings."""
import ctypes
from concurrent.futures import ThreadPoolExecutor,as_completed
import importlib.util
import json
import msvcrt
from pathlib import Path
import shutil
import sys

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('sd_runner',ROOT/'scripts/Compare-SdSceneTiming.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
out=Path(sys.argv[1]).resolve()
m.verify_builds(out)
summary=json.loads((out/'summary.json').read_text())
if not summary['complete']:raise RuntimeError('Finish and restore the main comparison before checkpoint recovery validation')
stage=summary['stage'];entries=json.loads((out/('full-manifest.json' if stage=='full' else 'selected-200.json')).read_text());entry=entries[0]
run_id=json.loads((out/'run.json').read_text())['runId']+'-'+stage

def verify(board):
    session=m.BoardSession(out,board)
    for name in ['restore.log','restored.json']:
        shutil.copyfile(out/board/name,out/board/('main-run-'+name))
    try:
        session.switch('latest');proof=[]
        for version in ['oldest','latest']:
            original=m.case_path(out,stage,f'{board}/{version}',entry,0).with_suffix('.jsonl').read_bytes()
            retrieved=session.link.get(run_id,entry['caseId'],0,version=version)
            if original!=retrieved:raise RuntimeError('Recovered checkpoint differs from original capture')
            m.validate_hardware(retrieved,entry,board,version,run_id,0,out)
            proof.append(dict(version=version,sha256=m.hashlib.sha256(retrieved).hexdigest(),unchanged=True))
        reply=session.link.play(run_id,entry,0)
        if not reply.endswith(' CACHED'):raise RuntimeError('Checkpoint RUN unexpectedly replayed the scene')
        return dict(board=board,caseId=entry['caseId'],scene=entry['name'],records=proof,cachedWithoutReplay=True)
    finally:session.close()

with (out/'run.lock').open('a+b') as lock:
    lock.seek(0);msvcrt.locking(lock.fileno(),msvcrt.LK_NBLCK,1)
    previous=ctypes.windll.kernel32.SetThreadExecutionState(0x80000003)
    try:
        results=[]
        with ThreadPoolExecutor(max_workers=2) as pool:
            for future in as_completed([pool.submit(verify,b) for b in m.BOARDS]):results.append(future.result())
        m.save(out/'recovery-check.json',dict(complete=True,atUtc=m.now(),results=results))
    finally:
        ctypes.windll.kernel32.SetThreadExecutionState(previous or 0x80000000)
        lock.seek(0);msvcrt.locking(lock.fileno(),msvcrt.LK_UNLCK,1)
m.report(out)
print('SD checkpoint recovery verified on both boards; both original firmwares restored',flush=True)
