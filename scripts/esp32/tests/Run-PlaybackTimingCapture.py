"""Flash one prepared Waveshare-7 timing snapshot and capture its on-board results.

Run with the pinned ESP-IDF Python (pyserial required). The port must have been
identified and the 7-inch hardware confirmed before invoking this command.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import serial
from serial.tools import list_ports

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('evidence',type=Path)
    parser.add_argument('snapshot')
    parser.add_argument('--expected-cases',type=int,default=16)
    parser.add_argument('--reference',action='store_true',help='Initialize continuous reference playback and verify UART frame progression')
    parser.add_argument('--port',default='COM4')
    parser.add_argument('--backup-meta',type=Path,required=True,help='Verified full-flash backup JSON with usbSerial, board, mac, size, sha256')
    args=parser.parse_args()
    backup_meta=json.loads(args.backup_meta.read_text())
    backup=args.backup_meta.with_suffix('.bin')
    if 'ESP32-S3-Touch-LCD-7' not in backup_meta['board']:raise RuntimeError('Backup must identify the user-confirmed Waveshare 7 board')
    identity=next((p for p in list_ports.comports() if p.device==args.port),None)
    if identity is None or identity.vid!=0x1a86 or identity.pid!=0x55d3 or identity.serial_number!=backup_meta['usbSerial']:
        raise RuntimeError('Connected serial identity differs from the inspected COM4 board')
    if not backup.exists() or backup.stat().st_size!=16777216 or backup_meta['size']!=16777216 or hashlib.sha256(backup.read_bytes()).hexdigest()!=backup_meta['sha256']:
        raise RuntimeError('Verified original 16 MB flash backup is required')
    build=args.evidence/args.snapshot/'firmware/dmdclock-esp32/build-timing'
    config=(build/'config/sdkconfig.h').read_text()
    if '#define CONFIG_DMD_DISPLAY_WIDTH' in config and '#define CONFIG_DMD_DISPLAY_WIDTH 800' not in config:
        raise RuntimeError('Build is not configured for Waveshare 7')
    if '#define CONFIG_DMD_QEMU 1' in config:
        raise RuntimeError('QEMU image must not be flashed to hardware')
    description=json.loads((build/'project_description.json').read_text())
    flash=json.loads((build/'flasher_args.json').read_text())
    image_files=flash['flash_files']
    if set(image_files)!=set(['0x0','0x8000','0x10000']):
        raise RuntimeError('Unexpected flash layout')
    metadata=dict(board='Waveshare ESP32-S3-Touch-LCD-7',mac=backup_meta['mac'],
        port=args.port,originalBackupSha256=backup_meta['sha256'],version=description['project_version'],
        images={offset:dict(path=path,sha256=hashlib.sha256((build/path).read_bytes()).hexdigest()) for offset,path in image_files.items()})
    (args.evidence/f'{args.snapshot}-flash.json').write_text(json.dumps(metadata,indent=2))
    command=[sys.executable,'-m','esptool','--chip','esp32s3','--port',args.port,'--baud','921600','write_flash',*flash['write_flash_args']]
    for offset,path in image_files.items():command.extend([offset,str(build/path)])
    print(f'Flashing {args.snapshot}: {description["project_version"]}',flush=True)
    with (args.evidence/f'{args.snapshot}-flash.log').open('w') as log:
        subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True)
    print('Flash verified by esptool. Capturing serial timing results...',flush=True)
    port=serial.Serial(port=None,baudrate=115200,timeout=.5)
    port.dtr=False;port.rts=False;port.port=args.port;port.open()
    pending=b''
    runs=[]
    current=None
    done=False
    reference_states=[]
    reference_ready=None
    next_state=0
    stop=time.monotonic()+210
    with port, (args.evidence/f'{args.snapshot}-serial.log').open('w',encoding='utf-8') as log:
        while time.monotonic()<stop:
            if reference_ready is not None and time.monotonic()>=next_state:
                port.write(b'STATE\n');port.flush();next_state=time.monotonic()+.5
                if time.monotonic()-reference_ready>20:raise RuntimeError('Reference playback did not show frame progression')
            pending+=port.read(4096)
            while b'\n' in pending:
                raw,pending=pending.split(b'\n',1)
                line=raw.decode(errors='replace').strip()
                log.write(line+'\n');log.flush()
                if 'TIMING ERROR' in line or 'Guru Meditation' in line or 'ESP_ERROR_CHECK failed' in line:
                    raise RuntimeError(line)
                if args.reference and line.startswith('REFERENCE READY'):
                    reference_ready=time.monotonic()
                    port.write(f'TIME {int(time.time())}\nAUTO\n'.encode());port.flush()
                    print(line,flush=True)
                elif args.reference and line.startswith('REFERENCE STATE'):
                    reference_states.append({k:int(v) for k,v in re.findall(r'(\w+)=([^\s]+)',line)})
                    if len(reference_states)>=8 and len({(s['index'],s['step'],s['frame']) for s in reference_states if s['playing']})>=2:
                        (args.evidence/'reference-state.json').write_text(json.dumps(reference_states,indent=2))
                        print('Reference continuous playback verified: frame/step progression observed',flush=True)
                        done=True;break
                if 'TIMING RESULT ' in line:
                    fields=dict(re.findall(r'(\w+)=([^\s]+)',line))
                    current={k:(v if k=='name' else int(v)) for k,v in fields.items()}
                    current['steps']=[]
                    print(line,flush=True)
                elif 'TIMING STEP ' in line and current is not None:
                    current['steps'].append({k:int(v) for k,v in re.findall(r'(\w+)=([^\s]+)',line)})
                elif line=='TIMING END' and current is not None:
                    if len(current['steps'])!=current['count'] or current['count']!=current['expected_steps']:
                        raise RuntimeError('Incomplete step capture')
                    current['expectedMs']=sum(s['delay'] for s in current['steps'])
                    current['actualMs']=(current['end']-current['start'])/1000
                    if any(s['painted']==0 for s in current['steps']):
                        raise RuntimeError('A sampled step was not painted')
                    runs.append(current);current=None
                    (args.evidence/f'{args.snapshot}-measurements.json').write_text(json.dumps(runs,indent=2))
                elif line=='TIMING ALL_DONE':
                    done=True
                    break
            if done:break
    if args.reference:
        if not done:raise RuntimeError('Continuous reference did not become ready')
        return
    if not done or len(runs)!=args.expected_cases:
        raise RuntimeError(f'Incomplete hardware run: {len(runs)}/{args.expected_cases} cases, done={done}')
    print(f'{args.snapshot}: all {len(runs)} hardware cases captured',flush=True)


if __name__=='__main__':main()
