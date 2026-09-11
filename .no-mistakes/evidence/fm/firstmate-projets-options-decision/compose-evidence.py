import json, os, pathlib, subprocess
root=pathlib.Path.cwd()
ev=pathlib.Path('/Users/ydeep/.no-mistakes/evidence/01M28Y4M6MGK0WWZGMMGZDW2E3')
home=root/'.test-tmp/intent-home'
for d in ['state','data','config']: (home/d).mkdir(parents=True,exist_ok=True)
rows=[('torre-relance','Torre : relancer le fournisseur'),('torre-domaine','Torre : le domaine est basculé ?'),('torre-hebergement','Torre : choisir l’hébergement')]
snap={'schema':'fm-bearings.v1','home':'demonstration','generated':'2026-09-11T12:00:00Z','in_flight':[],'decisions_open':[dict(id=k,key=k,verb='captain-hold',title=t,summary=t,owner='(main)',repo='torre') for k,t in rows],'landed':[],'gates':[],'reports':[],'recorded_prs':[],'omitted':[],'secondmates':[]}
config={'schema':'fm-projets-config.v1','projects':[{'id':'torre','name':'Torre','prefixes':['torre-'],'decisions':{'torre-domaine':{'nature':'etat'},'torre-hebergement':{'question':'Hébergement : chez toi ou chez Torre ?','options':[{'value':'chez-toi','label':'chez toi'},{'value':'chez-torre','label':'chez Torre'}]}}}]}
for n,obj in [('snapshot.json',snap),('config.json',config)]: (ev/n).write_text(json.dumps(obj,ensure_ascii=False,indent=2))
env=dict(os.environ,FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'),TMPDIR=str(root/'.test-tmp'))
args=['compose','--snapshot',str(ev/'snapshot.json'),'--config',str(ev/'config.json'),'--no-quota','--now','2026-09-11T12:00:00Z']
new=subprocess.check_output([str(root/'bin/fm-projets-board.sh'),*args],env=env,text=True)
(ev/'composed-current.json').write_text(new)
subprocess.run([str(root/'bin/fm-projets-board.sh'),'render',str(ev/'composed-current.json')],env=env,check=True)
(ev/'projets.html').write_bytes((home/'.lavish/projets.html').read_bytes())
base=root/'.test-tmp/base-bin';base.mkdir()
for src in (root/'bin').iterdir():
 if src.name!='fm-projets-board.sh': (base/src.name).symlink_to(src)
oldscript=base/'fm-projets-board.sh'
oldscript.write_bytes(subprocess.check_output(['git','show','437b4a06d7ca1d2530e04de831193f266ae53e52:bin/fm-projets-board.sh']))
oldscript.chmod(0o755)
old=subprocess.check_output([str(oldscript),*args],env=env,text=True)
(ev/'composed-baseline.json').write_text(old)
cur=json.loads(new)['projects'][0]['missing_from_you'];prev=json.loads(old)['projects'][0]['missing_from_you']
assert prev[0]['options'][0]['value']=='fait'
assert [o['value'] for o in cur[0]['options']]==['on-y-va','on-ne-le-fait-pas','pas-maintenant','on-en-parle']
assert cur[0]['ask']=='on le fait, ou on ne le fait pas ?'
assert cur[1]['ask']=='je ne sais pas si c’est déjà fait'
assert [o['value'] for o in cur[1]['options']]==['je-l-ai-fait','pas-encore','on-en-parle']
assert cur[2]['options']==config['projects'][0]['decisions']['torre-hebergement']['options']
report={'baseline':prev,'current':cur,'comparison':'Identical held tasks and correspondence table: baseline offers c’est fait; current separates decision and unknown state while preserving configured hosting choices.'}
(ev/'before-after.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(report['comparison'])
