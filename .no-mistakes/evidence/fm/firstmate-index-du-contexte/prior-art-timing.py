import json, os, pathlib, statistics, subprocess, time
root=pathlib.Path.cwd()
home=root/'.test-prior-art-phase/home'
env=dict(os.environ,FM_HOME=str(home))
for name in ['FM_DATA_OVERRIDE','FM_STATE_OVERRIDE']:
 env.pop(name,None)
tools={'before_quotation_fix':root/'.test-prior-art-phase/bin/fm-prior-art.sh','target':root/'bin/fm-prior-art.sh'}
results={name:{} for name in tools}
for case,args in [('one_word',['memoire']),('five_words',['memoire','contexte','enquete','rapports','locale']),('rebuild_only',['--rebuild'])]:
 for i in range(3):
  for name,tool in tools.items():
   start=time.monotonic()
   p=subprocess.run([str(tool),*args],env=env,capture_output=True,text=True)
   elapsed=time.monotonic()-start
   assert p.returncode==0,p.stderr
   if case!='rebuild_only': assert 'index reused' in p.stdout
   results[name].setdefault(case,[]).append(round(elapsed,3))
result={'corpus':'462 synthetic Markdown records, 4.29 MB; end-to-end wall time, three interleaved samples; same machine and corpus, no sandbox launcher overhead','samples_seconds':results,'median_seconds':{name:{case:round(statistics.median(values),3) for case,values in cases.items()} for name,cases in results.items()}}
text=json.dumps(result,indent=2)
pathlib.Path('/Users/ydeep/.no-mistakes/evidence/01M291FZGP663KHAJH7W7NSBR1/prior-art-timing.json').write_text(text+'\n')
print(text)
