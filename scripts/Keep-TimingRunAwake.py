"""Temporary sleep/display request for an already-running local timing process."""
import ctypes
import json
from pathlib import Path
import sys

folder=Path(sys.argv[1]).resolve()
state=json.loads((folder/'runner-state.json').read_text())
if state['state']!='running':raise RuntimeError('Timing runner is not running')
kernel=ctypes.windll.kernel32
kernel.OpenProcess.restype=ctypes.c_void_p
kernel.WaitForSingleObject.argtypes=[ctypes.c_void_p,ctypes.c_ulong]
kernel.CloseHandle.argtypes=[ctypes.c_void_p]
handle=kernel.OpenProcess(0x00100000,False,state['pid'])
if not handle:raise RuntimeError('Timing process handle is missing')
previous=kernel.SetThreadExecutionState(0x80000003)
if not previous:raise RuntimeError('Could not request temporary wakefulness')
try:
    print(f'Temporary system/display wake request active until timing PID {state["pid"]} exits',flush=True)
    while kernel.WaitForSingleObject(handle,1000)==258:pass
finally:
    kernel.SetThreadExecutionState(previous)
    kernel.CloseHandle(handle)
    print('Temporary wake request released; power settings were not changed',flush=True)
