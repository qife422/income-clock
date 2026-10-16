#!/usr/bin/env python3
"""Temporarily enable only Keyboard Navigation and restore the original preference."""
import json,signal,subprocess,sys,time,os,hashlib
from datetime import datetime,timezone
from pathlib import Path
run_name=sys.argv[1] if len(sys.argv)>1 else 'CLOSURE_DIRECTED'
command_path=sys.argv[2] if len(sys.argv)>2 else 'STAGE9_CLOSURE_DIRECTED_COMMAND.json'
record=Path('STAGE9_KEYBOARD_NAVIGATION_'+run_name+'_EXECUTION.json')
assert not record.exists()
# Opt-in observation only; legacy calls do not spawn a helper or create this file.
diag=os.environ.get('STAGE9_KEYBOARD_DIAGNOSTIC','')
diag_error=[];diag_file=None;restoring=False
if diag:
 assert diag=='1' and run_name=='RESUME010_RESTORE_PROBE'
 project=Path(__file__).resolve().parents[1]
 assert Path.cwd().resolve()==project
 helper='/private/tmp/visual-income-check-in/stage9-closeout/run-20260907-001/Resume008InputSource/stage9-input-source-context'
 digest='46312b7ba36608197aa1cb5e7a1c719eda6f865239d7988357d4f7ddcebde36b'
 assert os.environ.get('STAGE9_KEYBOARD_OBSERVER_HELPER')==helper
 assert os.environ.get('STAGE9_KEYBOARD_OBSERVER_SHA256')==digest
 assert str(Path(helper).resolve(strict=True))==helper and hashlib.sha256(Path(helper).read_bytes()).hexdigest()==digest
 assert json.loads(Path(command_path).read_text())==['/usr/bin/true']
 diag_path=project/'STAGE9_RESUME010_RESTORE_PROBE_KEYBOARD_BOUNDARIES.json'
 diag_file=open(diag_path,'x+',encoding='utf-8')
 diagnostic={'schema':'stage9.keyboard-boundaries.v1','helper_sha256':digest,'events':[]}
def sample(phase):
 if not diag:return
 try:
  entry={'phase':phase,'at':datetime.now(timezone.utc).isoformat(),'monotonic_ns':time.monotonic_ns()}
  try:
   # snapshot is read-only, including public AX context; never select/restore.
   p=subprocess.run([helper,'snapshot','com.apple.keylayout.US'],capture_output=True,text=True,timeout=3)
   if len(p.stdout)>8192 or p.returncode!=0:raise RuntimeError('observer exit/size '+str(p.returncode))
   value=json.loads(p.stdout)
   entry['inputSource']=value['currentID'][:512]
   entry['context']=value['context']
   if len(json.dumps(entry))>1500:raise RuntimeError('observer record too large')
  except BaseException as error:
   entry={'phase':phase,'at':datetime.now(timezone.utc).isoformat(),'error':type(error).__name__}
   diag_error.append(entry['error'])
  diagnostic['events'].append(entry)
  if len(diagnostic['events'])>24:raise RuntimeError('observer event cap')
  data=json.dumps(diagnostic,indent=2)
  if len(data.encode())>32768:raise RuntimeError('observer byte cap')
  diag_file.seek(0);diag_file.write(data);diag_file.truncate();diag_file.flush();os.fsync(diag_file.fileno())
 except BaseException as error:
  # Diagnostic failures, including an interrupted observation, cannot bypass restore.
  diag_error.append(type(error).__name__)
key=['NSGlobalDomain','AppleKeyboardUIMode']
def run(args):return subprocess.run(args,capture_output=True,text=True)
def observe():
 sample('jxa-before')
 p=run(['osascript','-l','JavaScript','-e','ObjC.import("AppKit"); $.NSApplication.sharedApplication.isFullKeyboardAccessEnabled']);sample('jxa-after');assert p.returncode==0,p.stderr;return p.stdout.strip()
sample('capture-before')
before=run(['defaults','read',*key]);sample('capture-after');assert before.returncode in (0,1)
r={'authorization':'DEVELOPMENT_STATE §65 explicit temporary Keyboard Navigation only','original_present':before.returncode==0,'original_value':before.stdout.strip() if before.returncode==0 else None,'original_appkit_enabled':observe()}
record.write_text(json.dumps(r,indent=2));child=None

def interrupted(signum,frame):
 if diag and restoring:
  diag_error.append('signal-during-restoration');return
 if child is not None and child.poll() is None:child.send_signal(signal.SIGINT)
 raise KeyboardInterrupt
signal.signal(signal.SIGTERM,interrupted);signal.signal(signal.SIGINT,interrupted)
try:
 if diag:assert not diag_error,diag_error
 sample('defaults-write-before')
 p=run(['defaults','write',*key,'-int','3']);sample('defaults-write-after');assert p.returncode==0,p.stderr
 sample('enabled-readback-before')
 r['enabled_preference']=run(['defaults','read',*key]).stdout.strip();sample('enabled-readback-after');r['enabled_appkit']=observe();record.write_text(json.dumps(r,indent=2));assert r['enabled_preference']=='3' and r['enabled_appkit']=='true',r
 if diag:assert not diag_error,diag_error
 child=subprocess.Popen([sys.executable,'scripts/stage9_run_monitored.py',run_name,command_path])
 r['monitor_exit']=child.wait();sample('child-return')
finally:
 restoring=True
 if child is not None and child.poll() is None:
  child.send_signal(signal.SIGINT)
  try:child.wait(timeout=20)
  except subprocess.TimeoutExpired:child.terminate();child.wait(timeout=10)
 sample('defaults-restore-before')
 restore=run(['defaults','write',*key,'-int',r['original_value']]) if r['original_present'] else run(['defaults','delete',*key])
 sample('defaults-restore-after')
 r['restore_returncode']=restore.returncode
 sample('restore-readback-before')
 after=run(['defaults','read',*key]);sample('restore-readback-after');r['restored_present']=after.returncode==0;r['restored_value']=after.stdout.strip() if after.returncode==0 else None;r['restored_appkit_enabled']=observe()
 r['restore_verified']=restore.returncode==0 and r['restored_present']==r['original_present'] and r['restored_value']==r['original_value'] and r['restored_appkit_enabled']==r['original_appkit_enabled']
 record.write_text(json.dumps(r,indent=2));assert r['restore_verified'],r
if diag:
 diag_file.close()
 assert not diag_error,diag_error
print(json.dumps(r))
raise SystemExit(r['monitor_exit'])
