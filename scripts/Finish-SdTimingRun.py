"""Wait on the live timing process, validate results, then verify SD recovery."""
import ctypes
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('sd_runner',ROOT/'scripts/Compare-SdSceneTiming.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
out=Path(sys.argv[1]).resolve();state=json.loads((out/'runner-state.json').read_text())
kernel=ctypes.windll.kernel32;kernel.OpenProcess.restype=ctypes.c_void_p
kernel.WaitForSingleObject.argtypes=[ctypes.c_void_p,ctypes.c_ulong];kernel.CloseHandle.argtypes=[ctypes.c_void_p]
previous_power_state=kernel.SetThreadExecutionState(0x80000003)
try:
    if state['state']=='running':
        handle=kernel.OpenProcess(0x00100000,False,state['pid'])
        if not handle:raise RuntimeError('Runner process handle is missing; inspect before finalizing')
        try:
            print(f'Monitoring live timing PID {state["pid"]}; final checks will run after it exits',flush=True)
            while kernel.WaitForSingleObject(handle,1000)==258:pass
        finally:kernel.CloseHandle(handle)
    m.report(out);summary=json.loads((out/'summary.json').read_text())
    if not summary['complete']:raise RuntimeError('Main comparison is incomplete; no recovery test started')
    with (out/'recovery-verification.log').open('w') as stream:
        subprocess.run([str(m.PILOT.PYTHON),str(ROOT/'scripts/Verify-SdTimingRecovery.py'),str(out)],stdout=stream,stderr=subprocess.STDOUT,check=True)
    m.report(out);summary=json.loads((out/'summary.json').read_text());recovery=json.loads((out/'recovery-check.json').read_text())
    if not summary['complete'] or not recovery['complete']:raise RuntimeError('Final validation incomplete')
    m.save(out/'pipeline-finished.json',dict(complete=True,atUtc=m.now(),summary=summary,recoveryVerified=True))
    print('Timing comparison, raw-data validation, SD recovery, and both firmware restorations complete',flush=True)
except BaseException as error:
    m.save(out/'pipeline-finished.json',dict(complete=False,error=str(error),atUtc=m.now()));raise
finally:
    kernel.SetThreadExecutionState(previous_power_state or 0x80000000)
