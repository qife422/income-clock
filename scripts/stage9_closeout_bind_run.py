#!/usr/bin/env python3
"""Exact per-assertion bindings; preserve old failures, select latest named run.
This reads already-exported JSON only, never sealed xcresult. Producer candidate
projection is mutable and never an independent adjudication.
"""
from pathlib import Path
import argparse,csv,json,hashlib,re,collections,shlex
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser()
p.add_argument('--run-root',type=Path,default=Path('/private/tmp/visual-income-check-in/stage9-closeout/run-20260907-001'))
p.add_argument('--prefix',default='regression')
p.add_argument('--source-manifest',default='build-source.json')
p.add_argument('--fixed-source',type=Path,default=ROOT/'stage9_closeout_evidence/code-candidate-001')
p.add_argument('--runs-json',type=Path)
a=p.parse_args()
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def read(p):return list(csv.DictReader(Path(p).open(),delimiter='\t'))
def write(p,rs):
 with Path(p).open('w') as f:
  w=csv.DictWriter(f,fieldnames=list(rs[0]),delimiter='\t',lineterminator='\n');w.writeheader();w.writerows(rs)
def resolve(p):
 p=Path(p);return p if p.is_absolute() else ROOT/p
contract_manifest=ROOT/'contract_snapshots/2026-08-17-pd2rr-007-recovery-transaction-repair-candidates/SHA256SUMS'
assert sha(contract_manifest)=='10d994a8ca452aaba742c0e6de25fd763f3ea6d42d826c42918e87fb4eaed150'
for line in contract_manifest.read_text().splitlines():
 digest,rel=line.split(maxsplit=1);frozen=contract_manifest.parent/rel.lstrip('*')
 assert sha(frozen)==digest
 active=ROOT/(frozen.name.split('-')[0]+'.md')
 assert active.read_text().split('---',2)[-1]==frozen.read_text().split('---',2)[-1]
def method_body(p,name):
 if not p or not p.exists():return None
 ls=p.read_text().splitlines(keepends=True);hits=[i for i,l in enumerate(ls) if re.search(r'func '+re.escape(name)+r'\(',l)]
 if len(hits)!=1:return None
 i=hits[0];j=i+1
 while j<len(ls) and not re.match(r'    }\s*$',ls[j]):j+=1
 return i+1,j+1,hashlib.sha256(''.join(ls[i:j+1]).encode()).hexdigest()
def test_class(p,name):
 if not p:return ''
 prefix=p.read_text().split('func '+name+'(',1)[0]
 classes=re.findall(r'\bclass\s+(\w+)\s*:\s*XCTestCase',prefix)
 return classes[-1] if classes else ''
def load_run(d):
 root=resolve(d['run_root']);prefix=d['prefix'];rawpath=root/d.get('tests',prefix+'-tests.json');summarypath=root/d.get('summary',prefix+'-summary.json');sourcepath=root/d['source_manifest']
 raw=json.loads(rawpath.read_text());summary=json.loads(summarypath.read_text());source=json.loads(sourcepath.read_text());leaves=[]
 def walk(n):
  if n.get('nodeType')=='Test Case':leaves.append(n)
  for c in n.get('children',[]):walk(c)
 for n in raw['testNodes']:walk(n)
 assert len(leaves)>0, 'Zero-test execution is retained diagnostic, not a bound test run'
 assert len(leaves)==summary['passedTests']+summary['failedTests']+summary['skippedTests']
 assert len({n['nodeIdentifierURL'] for n in leaves})==len(leaves)
 for result,key in [('Passed','passedTests'),('Failed','failedTests'),('Skipped','skippedTests')]:
  assert sum(n['result']==result for n in leaves)==summary[key]
 methods=collections.defaultdict(list)
 for n in leaves:methods[n['name'].removesuffix('()')].append(n)
 fixed=resolve(d['fixed_source']);assert fixed.is_dir()
 fixed_manifest=fixed/'MANIFEST.json'
 assert json.loads(fixed_manifest.read_text())==source
 assert all((fixed/rel).is_file() and sha(fixed/rel)==digest for rel,digest in source.items())
 provenance={}
 for key in ['command','execution','build_command','build_execution','execution_log']:
  path=resolve(d[key]) if d.get(key) else None
  provenance[key]=str(path) if path else ''
  provenance[key+'_sha256']=sha(path) if path else ''
 command_text=Path(provenance['command']).read_text() if provenance['command'] else ''
 command_format=d.get('command_format','json_argv' if command_text else 'unavailable')
 if command_format=='xcodebuild_log':
  command_lines=command_text.splitlines();indices=[i for i,line in enumerate(command_lines) if line=='Command line invocation:']
  assert len(indices)==1
  command_line=indices[0]+1;command=shlex.split(command_lines[command_line].strip())
 else:command_line=None;command=json.loads(command_text) if command_text else []
 if provenance['execution']:
  execution=json.loads(Path(provenance['execution']).read_text());assert execution['command']==command
 if provenance['build_command'] and provenance['build_execution']:
  assert json.loads(Path(provenance['build_execution']).read_text())['command']==json.loads(Path(provenance['build_command']).read_text())
 log_text=Path(provenance['execution_log']).read_text() if provenance['execution_log'] else ''
 log_outcomes=re.findall(r'^\*\* (TEST EXECUTE (?:FAILED|SUCCEEDED)) \*\*$',log_text,re.M)
 if log_outcomes:
  assert len(log_outcomes)==1
  assert (log_outcomes[0]=='TEST EXECUTE SUCCEEDED')==(summary['failedTests']==0)
 provenance.update(command_format=command_format,command_source_line=command_line+1 if command_line is not None else '',command_argv=json.dumps(command,ensure_ascii=False),execution_log_outcome=log_outcomes[0] if log_outcomes else '',provenance_gap=d.get('provenance_gap',''))
 xcresult=command[command.index('-resultBundlePath')+1] if '-resultBundlePath' in command else ''
 provenance.update(xcresult_path=xcresult,fixed_source=str(fixed),fixed_manifest=str(fixed_manifest),fixed_manifest_sha256=sha(fixed_manifest),fixed_source_files_verified=len(source),contract_versions='Product0.8/UI0.5/Technical0.4',contract_manifest=str(contract_manifest),contract_manifest_sha256=sha(contract_manifest),devices_and_configurations=json.dumps(summary.get('devicesAndConfigurations',[]),ensure_ascii=False,sort_keys=True))
 cache={}
 def original(rel):
  if rel in cache:return cache[rel]
  for q in [fixed/rel,ROOT/rel]:
   if q.exists() and sha(q)==source.get(rel):cache[rel]=q;return q
  return None
 return dict(prefix=prefix,rawpath=rawpath,summarypath=summarypath,sourcepath=sourcepath,summary=summary,source=source,methods=methods,original=original,leaves=leaves,provenance=provenance)
descriptors=json.loads(a.runs_json.read_text()) if a.runs_json else [dict(run_root=str(a.run_root),prefix=a.prefix,source_manifest=a.source_manifest,fixed_source=str(a.fixed_source))]
runs=sorted([load_run(d) for d in descriptors],key=lambda r:r['summary']['startTime'])
assert len({r['prefix'] for r in runs})==len(runs)
catalog=[dict(run_prefix=r['prefix'],raw_tests=str(r['rawpath']),raw_tests_sha256=sha(r['rawpath']),summary=str(r['summarypath']),summary_sha256=sha(r['summarypath']),source_manifest=str(r['sourcepath']),source_manifest_sha256=sha(r['sourcepath']),start_time=r['summary']['startTime'],passed=r['summary']['passedTests'],failed=r['summary']['failedTests'],skipped=r['summary']['skippedTests'],**r['provenance']) for r in runs]
write(ROOT/'STAGE9_CLOSEOUT_RUN_CATALOG.tsv',catalog)
candidates=read(ROOT/'STAGE9_CLOSEOUT_ASSERTION_CANDIDATES.tsv');bindings=[]
# Keep every actual test node, including failures with no current requirement
# mapping. Requirement links are a second projection, never the raw inventory.
method_rows=[]
latest={n['nodeIdentifierURL']:r['prefix'] for r in runs for n in r['leaves']}
for run in runs:
 fixed=Path(run['provenance']['fixed_source']);index=collections.defaultdict(list)
 for rel in run['source']:
  if rel.endswith('.swift') and 'Tests/' in rel:
   q=fixed/rel
   for name in re.findall(r'\bfunc\s+(test\w+)\s*\(',q.read_text()):
    cls=test_class(q,name);index[(Path(rel).parts[0],cls,name)].append((rel,q))
 for n in run['leaves']:
  target,cls,name=n['nodeIdentifierURL'].rsplit('/',3)[-3:]
  matches=index.get((target,cls,name),[]);rel,q=matches[0] if len(matches)==1 else ('',None)
  body=method_body(q,name);current=method_body(ROOT/rel,name) if rel else None
  ids=sorted({c['atomic_requirement_id'] for c in candidates if c['method']==name and c['test_file']==rel})
  method_rows.append(dict(run_prefix=run['prefix'],raw_node=n['nodeIdentifier'],raw_node_url=n['nodeIdentifierURL'],raw_result=n['result'],selected_latest_node=latest[n['nodeIdentifierURL']]==run['prefix'],test_target=target,test_class=cls,method=name,run_source_file=rel,source_unique_matches=len(matches),run_source_file_sha256=sha(q) if q else '',run_method_range=f'{body[0]}-{body[1]}' if body else '',run_method_sha256=body[2] if body else '',current_method_matches_run=bool(body and current and body[2]==current[2]),atomic_requirement_ids='; '.join(ids),raw_tests=str(run['rawpath']),raw_tests_sha256=sha(run['rawpath']),run_catalog='STAGE9_CLOSEOUT_RUN_CATALOG.tsv#'+run['prefix']))
write(ROOT/'STAGE9_CLOSEOUT_RUN_METHODS.tsv',method_rows)
for c in candidates:
 current=method_body(ROOT/c['test_file'],c['method'])
 applicable=[r for r in runs if c['method'] in r['methods']]
 selected=applicable[-1] if applicable else runs[-1]
 # Every executed input is retained; absent methods get one explicit NOT_RUN row.
 for run in applicable or [selected]:
  ns=run['methods'].get(c['method'],[]);q=run['original'](c['test_file']);body=method_body(q,c['method'])
  status='NOT_RUN'
  if ns:
   status='AMBIGUOUS_RAW_NODE' if len(ns)!=1 else ns[0]['result']
   if not q or not body:status='SOURCE_BINDING_UNAVAILABLE'
  n=ns[0] if len(ns)==1 else {}
  cls=test_class(q,c['method']);suffix='/'+Path(c['test_file']).parts[0]+'/'+cls+'/'+c['method']
  if n and not n.get('nodeIdentifierURL','').endswith(suffix):status='RAW_TARGET_OR_CLASS_MISMATCH'
  bindings.append(dict(c,execution_result=status,raw_result_path=str(run['rawpath']),raw_result_sha256=sha(run['rawpath']),run_prefix=run['prefix'],selected_for_current=run is selected,raw_node=n.get('nodeIdentifier',''),raw_node_url=n.get('nodeIdentifierURL',''),raw_unique_matches=len(ns),run_source_file=str(q) if q else '',run_source_file_sha256=sha(q) if q else '',run_method_range=f'{body[0]}-{body[1]}' if body else '',run_method_sha256=body[2] if body else '',candidate_method_is_current=bool(current and current[2]==c['method_sha256']),current_method_matches_run=bool(body and current and body[2]==current[2]),current_test_file_matches_run=bool(q and sha(ROOT/c['test_file'])==sha(q)),build_source_manifest=str(run['sourcepath']),build_source_manifest_sha256=sha(run['sourcepath']),run_summary=str(run['summarypath']),run_summary_sha256=sha(run['summarypath']),run_environment=run['summary'].get('environmentDescription',''),run_catalog='STAGE9_CLOSEOUT_RUN_CATALOG.tsv#'+run['prefix'],contract_manifest_sha256=sha(contract_manifest),binding_scope='Producer exact raw/input binding; original failed runs preserved; current production dependency compatibility and atomic sufficiency await independent review'))
write(ROOT/'STAGE9_CLOSEOUT_RUN_BINDINGS.tsv',bindings)
disposition=read(ROOT/'STAGE9_CLOSEOUT_DISPOSITION.tsv');byid=collections.defaultdict(list)
for b in bindings:
 if b['selected_for_current']:byid[b['atomic_requirement_id']].append(b)
static=read(ROOT/'STAGE9_CLOSEOUT_STATIC_OBSERVATIONS.tsv')
for d in disposition:
 # Always derive from the coverage base before applying a new run set.
 d['producer_run_disposition']='';d['producer_evidence_binding']='';d['producer_evidence_limit']=''
 bs=byid.get(d['atomic_requirement_id'],[])
 if bs:
  direct=[b for b in bs if b['coverage_scope']=='direct_atomic_candidate']
  # A direct binding is an explicit complete-predicate candidate. Supplementary
  # partial links cannot confer completion, nor erase an executed direct proof.
  # Every direct method must pass; any current relevant failure still blocks it.
  complete=bool(direct)
  passed=all(b['execution_result']=='Passed' and b['current_method_matches_run'] and b['candidate_method_is_current'] for b in direct)
  failed=any(b['execution_result']=='Failed' and b['current_method_matches_run'] for b in bs)
  any_current_pass=any(b['execution_result']=='Passed' and b['current_method_matches_run'] and b['candidate_method_is_current'] for b in bs)
  status='FAILURE_IN_BOUND_EVIDENCE' if failed else 'PRODUCER_PASS_CANDIDATE' if complete and passed else 'PARTIAL_PASSED_EVIDENCE' if any_current_pass else 'NOT_RUN_OR_SOURCE_UNBOUND'
  d['producer_run_disposition']=status;d['producer_evidence_binding']='STAGE9_CLOSEOUT_RUN_BINDINGS.tsv#'+d['atomic_requirement_id'];d['producer_evidence_limit']='No independent conclusion; partial_* never closes atomic row. Exact original build input retained; changed production dependencies require review.'
  if status=='PRODUCER_PASS_CANDIDATE' or failed:d['current_disposition']=status
  elif d['current_disposition'] in ['PRODUCER_PASS_CANDIDATE','FAILURE_IN_BOUND_EVIDENCE']:d['current_disposition']='NOT_VERIFIED'
 # Static observations are deliberately not promoted by the runtime binder.
 # Their source identities and pending independent sufficiency review are separate.
write(ROOT/'STAGE9_CLOSEOUT_DISPOSITION.tsv',disposition)
# Some old observations refer to the mutable disposition itself. Assess them
# against the final generated bytes, never the pre-write baseline.
static_applicability=[]
for s in static:
 refs=[item.rsplit('#',1) for item in s['source_bindings'].split('; ')]
 fresh=bool(refs) and all(len(pair)==2 and (ROOT/pair[0]).is_file() and sha(ROOT/pair[0])==pair[1] for pair in refs)
 static_applicability.append(dict(atomic_requirement_id=s['atomic_requirement_id'],recorded_result=s['actual_result'],scope=s['scope'],source_bindings_current=fresh,current_disposition='CURRENT_STATIC_OBSERVATION_PENDING_REVIEW' if fresh else 'STALE_SOURCE_BINDING',source_bindings=s['source_bindings'],limitation='Recorded static result is not a runtime result; stale observations cannot be promoted.'))
write(ROOT/'STAGE9_CLOSEOUT_STATIC_APPLICABILITY.tsv',static_applicability)
# Strict fixed inputs and the approved Contract retain their identities at exit.
for r in runs:
 fixed=Path(r['provenance']['fixed_source'])
 assert sha(fixed/'MANIFEST.json')==r['provenance']['fixed_manifest_sha256']
 assert all(sha(fixed/rel)==digest for rel,digest in r['source'].items())
assert sha(contract_manifest)=='10d994a8ca452aaba742c0e6de25fd763f3ea6d42d826c42918e87fb4eaed150'
info={'runs':[{'prefix':r['prefix'],'raw_test_leaf_count':len(r['leaves']),'raw_counts':dict(collections.Counter(n['result'] for n in r['leaves'])),'raw_tests_sha256':sha(r['rawpath']),'summary_sha256':sha(r['summarypath']),'source_manifest_sha256':sha(r['sourcepath']),'current_changed_files':[rel for rel,digest in r['source'].items() if (ROOT/rel).exists() and sha(ROOT/rel)!=digest]} for r in runs],'all_run_binding_counts':dict(collections.Counter(b['execution_result'] for b in bindings)),'selected_binding_counts':dict(collections.Counter(b['execution_result'] for b in bindings if b['selected_for_current'])),'producer_disposition_counts':dict(collections.Counter(d['current_disposition'] for d in disposition)),'limitations':['Historical runs/failures retained; latest executed node selected by summary startTime.','Candidate pass is not reviewer acceptance, technical verified, human acceptance or deployment.','Partial semantic bindings never close atomic rows.']}
info['raw_method_inventory']=dict(total_nodes=len(method_rows),all_raw_results=dict(collections.Counter(m['raw_result'] for m in method_rows)),latest_unique_nodes=sum(m['selected_latest_node'] for m in method_rows),latest_raw_results=dict(collections.Counter(m['raw_result'] for m in method_rows if m['selected_latest_node'])),unbound_source_nodes=[m['raw_node_url'] for m in method_rows if m['source_unique_matches']!=1],latest_methods_without_atomic_mapping=sum(m['selected_latest_node'] and not m['atomic_requirement_ids'] for m in method_rows))
info['static_observation_applicability']=dict(collections.Counter(s['current_disposition'] for s in static_applicability))
info['limitations'].extend(['All fixed source manifest entries rehashed; runtime methods additionally match exact target/class/node URL.','No static PASS promotion by runtime binder; static observations carry separate source freshness.','Latest selected node union is a multi-run method view, not a new single-build suite PASS; unresolved keyboard gates and isolated UI failures remain recorded.'])
(ROOT/'STAGE9_CLOSEOUT_RUN_SUMMARY.json').write_text(json.dumps(info,ensure_ascii=False,indent=2)+'\n');print(json.dumps(info,ensure_ascii=False,indent=2))
