import json, os, subprocess
from pathlib import Path
root=Path.cwd(); work=root/'.test-phase-tmp/manual'; work.mkdir(parents=True,exist_ok=True)
evidence=Path('/Users/ydeep/.no-mistakes/evidence/01M298ZRRY4W20EE1Q7Q6N55TV')
snapshot={'schema':'fm-bearings.v1','home':'test/home','generated':'2026-09-12T10:00:00Z','prs':'not_requested',**{k:[] for k in ['in_flight','secondmates','secondmate_reconcile','landed','gates','reports','recorded_prs','omitted']},'decisions_open':[]}
for key,title in [('relance','Relancer le fournisseur de la boutique pilote'),('domaine','Le domaine de la boutique est basculé ?'),('hebergement','Hébergement : chez toi ou chez Torre ?'),('commande','La commande de matériel est passée ?')]:
 snapshot['decisions_open'].append({'id':'torre-'+key,'key':'torre-'+key,'verb':'captain-hold','title':title,'summary':title,'owner':'(main)','repo':'boutique'})
config={'schema':'fm-projets-config.v1','projects':[{'id':'torre','name':'Torre','prefixes':['torre-'],'decisions':{'torre-domaine':{'nature':'etat'},'torre-hebergement':{'question':'Hébergement : chez toi ou chez Torre ?','options':[{'value':'chez-toi','label':'chez toi'},{'value':'chez-torre','label':'chez Torre'}]},'torre-commande':{'nature':'etat','options':[{'value':'commandee','label':'je l’ai commandé'},{'value':'pas-encore','label':'pas encore'}]}}}]}
for name,data in [('snapshot',snapshot),('config',config)]: (evidence/(name+'.json')).write_text(json.dumps(data,ensure_ascii=False,indent=2))
base=work/'baseline'; (base/'bin').mkdir(parents=True,exist_ok=True)
for file in ['fm-projets-board.sh']:
 (base/'bin'/file).write_bytes(subprocess.check_output(['git','show','437b4a06d7ca1d2530e04de831193f266ae53e52:bin/'+file])); (base/'bin'/file).chmod(0o755)
for file in ['fm-timeout-lib.sh','fm-projets-data.jq']:
 (base/'bin'/file).symlink_to(root/'bin'/file)
(base/'template.html').write_bytes(subprocess.check_output(['git','show','437b4a06d7ca1d2530e04de831193f266ae53e52:.agents/skills/projets/assets/page-template.html']))
outputs={}
for name,board,template in [('before',base/'bin/fm-projets-board.sh',base/'template.html'),('after',root/'bin/fm-projets-board.sh',root/'.agents/skills/projets/assets/page-template.html')]:
 home=work/name; home.mkdir(exist_ok=True)
 env=dict(os.environ,FM_HOME=str(home),FM_ROOT_OVERRIDE=str(root),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'),FM_PROJETS_BOARD_TEMPLATE=str(template))
 data=json.loads(subprocess.check_output([str(board),'compose','--snapshot',str(evidence/'snapshot.json'),'--config',str(evidence/'config.json'),'--no-quota','--now','2026-09-12T10:00:00Z'],env=env))
 outputs[name]=data
 payload=evidence/(name+'-payload.json'); payload.write_text(json.dumps(data,ensure_ascii=False,indent=2))
 subprocess.run([str(board),'render',str(payload)],env=env,check=True,capture_output=True)
 (evidence/(name+'.html')).write_bytes((home/'.lavish/projets.html').read_bytes())
rows={r['key']:r for r in outputs['after']['projects'][0]['missing_from_you']}
assert rows['torre-relance']['nature']=='decision'
assert [o['value'] for o in rows['torre-relance']['options']]==['on-y-va','on-ne-le-fait-pas','pas-maintenant','on-en-parle']
assert rows['torre-domaine']['ask']=='je ne sais pas si c’est déjà fait'
assert [o['value'] for o in rows['torre-domaine']['options']]==['je-l-ai-fait','pas-encore','on-en-parle']
assert rows['torre-commande']['ask']=='je ne sais pas si c’est déjà fait'
assert rows['torre-hebergement']['ask'] is None
assert rows['torre-hebergement']['options']==config['projects'][0]['decisions']['torre-hebergement']['options']
before=outputs['before']['projects'][0]['missing_from_you'][0]
assert before['options'][0]['value']=='fait' and not before.get('ask')
(evidence/'behavior-comparison.json').write_text(json.dumps({name:data['projects'][0]['missing_from_you'] for name,data in outputs.items()},ensure_ascii=False,indent=2))
print('Same fleet inputs: base reproduces c’est fait without an admission; target distinguishes decision and status, preserves configured options, and renders both pages.')
