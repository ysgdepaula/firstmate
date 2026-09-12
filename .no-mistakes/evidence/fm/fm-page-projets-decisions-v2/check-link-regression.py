import json, os, subprocess
from pathlib import Path
root=Path.cwd(); home=root/'.test-tmp/manual/home'
evidence=Path(__file__).parent
env=dict(os.environ,FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'),TMPDIR=str(root/'.test-tmp'),PATH=str(home/'fakebin')+':'+os.environ['PATH'])
cases=[('main','fm-bearings-snapshot.sh',['--json','--all-decisions'],
'''links:call_links(([ $fleet_tasks[] | select(.id == $record.id) | .links[]? ]) +
                             (.links // []); null)''',
'''links:call_links((.links // []) +
                             ([ $fleet_tasks[] | select(.id == $record.id) | .links[]? ]); null)'''),
('secondmate','fm-fleet-snapshot.sh',['--secondmate-home-summary'],
'''call_link_candidates(($status_by_id[.id] // []) + (.links // []); null)''',
'''call_link_candidates((.links // []) + ($status_by_id[.id] // []); null)''')]
results=[]
for name,script,args,current,previous in cases:
 p=root/'bin'/script;original=p.read_bytes();text=original.decode()
 if text.count(current)!=1:raise RuntimeError('Counterfactual patch does not match its intended single merge')
 def observe():
  result=json.loads(subprocess.check_output([str(p),*args],env=env,text=True))
  return next(r for r in result['decisions_open'] if r['id']=='club-rose')
 fixed=observe(); fixed_links=fixed['links'].split() if isinstance(fixed['links'],str) else fixed['links']
 assert fixed_links[0]=='http://localhost:4387/session/final',fixed
 try:
  p.write_text(text.replace(current,previous))
  before=observe();before_links=before['links'].split() if isinstance(before['links'],str) else before['links']
  assert before_links[0]=='http://localhost:4387/session/draft',before
 finally:p.write_bytes(original)
 restored=observe();assert restored==fixed
 results.append({'path':name,'interface':[script,*args],'without_newest_status_fix':before,'with_fix':fixed,'restored_result_identical':True})
(evidence/'link-regression-results.json').write_text(json.dumps(results,indent=2,ensure_ascii=False))
print(json.dumps([{'path':r['path'],'before':r['without_newest_status_fix']['links'],'after':r['with_fix']['links']} for r in results],indent=2))
