#!/usr/bin/env python3
"""Apply the authorized local UIData entitlement to disposable Debug test products."""
from pathlib import Path
import subprocess,plistlib,json,hashlib,sys
r=Path('/private/tmp/visual-income-check-in/stage9-closeout/run-20260907-001');report=[];tag=sys.argv[1]
out=Path('STAGE9_'+tag+'_SIGNATURE.json');assert not out.exists()
for name in ['IncomeClock.app','IncomeClockUITests-Runner.app']:
 p=r/'DerivedData/Build/Products/Debug'/name;q=subprocess.run(['/usr/bin/codesign','-d','--entitlements',':-',str(p)],capture_output=True);assert q.returncode==0;before=plistlib.loads(q.stdout);after=dict(before);key='com.apple.security.temporary-exception.files.absolute-path.read-write';values=list(after.get(key,[]));ui=str(r/'UIData')+'/'
 if ui not in values:values.append(ui)
 after[key]=values;ent=Path('STAGE9_'+tag+'_'+name+'.entitlements.plist');ent.write_bytes(plistlib.dumps(after));assert after.get('com.apple.security.app-sandbox') is True
 sign=subprocess.run(['/usr/bin/codesign','--force','--sign','-','--entitlements',str(ent),str(p)],capture_output=True,text=True);assert sign.returncode==0,sign.stderr
 verify=subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict','--verbose=2',str(p)],capture_output=True,text=True);actual=subprocess.run(['/usr/bin/codesign','-d','--entitlements',':-',str(p)],capture_output=True);assert actual.returncode==0 and plistlib.loads(actual.stdout)==after;info=plistlib.loads((p/'Contents/Info.plist').read_bytes());binary=p/'Contents/MacOS'/info['CFBundleExecutable'];report.append({'path':str(p),'before':before,'after':after,'verify_returncode':verify.returncode,'verify_stderr':verify.stderr,'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest()});
 for nested in p.rglob('*.xctest/Contents/MacOS/*'):
  if nested.is_file():report[-1].setdefault('nested_test_binaries',{})[str(nested)]=hashlib.sha256(nested.read_bytes()).hexdigest()
 out.write_text(json.dumps(report,indent=2));assert verify.returncode==0,verify.stderr
print('Both temporary local signatures verified')
