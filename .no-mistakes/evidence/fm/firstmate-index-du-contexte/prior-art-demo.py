import hashlib, json, os, pathlib, statistics, subprocess, time
root = pathlib.Path.cwd()
home = root / '.test-prior-art-phase/home'
evidence = pathlib.Path('/Users/ydeep/.no-mistakes/evidence/01M291FZGP663KHAJH7W7NSBR1')
data = home / 'data'
data.mkdir(parents=True, exist_ok=True)
records = {
 'memoire-scout/report.md': '# Mémoire des agents\nDate: 2026-09-01\n\nNous avons déjà évalué la mémoire locale pour retrouver le contexte avant une enquête.\nLa recherche doit réutiliser les rapports existants.\n',
 'memoire-scout/brief.md': '# Instructions\nDate: 2026-08-31\n\nÉvaluer le contexte et la mémoire locale avant toute nouvelle enquête.\n',
 'captain.md': '# Notes\nDate: 2026-09-11\n\nPréserver le temps du capitaine grâce à la mémoire des projets.\n',
 'learnings.md': '# Learnings\nDate: 2026-09-10\n\nRelire le contexte de chaque enquête.\n',
 'backlog.md': '# Work queue\nDate: 2026-09-11\n\nRendre les rapports accessibles avant une enquête.\n',
 'budget/report.md': '# Budget\nDate: 2026-09-02\n\n-10% marge nette pour budgetneedle\n',
 'french/report.md': "# Note\nDate: 2026-09-03\n\nL'agent consulte d'abord la mémoire aujourd'hui.\n",
 'archive.md': '# Archive\nDate: 2025-07-10\n\n## Earlier 2026-08-01\n\n \tExample 1999-01-01\n---\nuncertainneedle\n',
}
for rel, content in records.items():
 p = data / rel
 p.parent.mkdir(parents=True, exist_ok=True)
 p.write_text(content)
 p.chmod(0o600)
for n in range(462-len(records)):
 p = data / f'other-{n:03d}/report.md'
 p.parent.mkdir(parents=True, exist_ok=True)
 p.write_text(f'# Unrelated investigation {n}\nDate: 2026-08-20\n\n' + 'Historique logistique des livraisons, inventaire des produits et calendrier des fournisseurs.\n'*100)
 p.chmod(0o600)
def snapshot():
 return {str(p.relative_to(data)): (hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_mode & 0o777, p.stat().st_mtime_ns) for p in data.rglob('*.md')}
initial = snapshot()
env = dict(os.environ, FM_HOME=str(home), LC_ALL='fr_FR.UTF-8')
env.pop('FM_DATA_OVERRIDE', None)
env.pop('FM_STATE_OVERRIDE', None)
transcript = ['Prior-art CLI demonstration on 462 synthetic local records (not private fleet data).',
 'Every CLI command is run with macOS sandbox-exec denying network access.',
 f'Corpus size: {sum(p.stat().st_size for p in data.rglob("*.md"))} bytes.', '']
def run(args, expected=0, tool=None, record=True):
 tool = tool or root / 'bin/fm-prior-art.sh'
 start = time.monotonic()
 proc = subprocess.run(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(tool),*args], env=env, text=True, capture_output=True)
 elapsed = time.monotonic()-start
 if record:
  transcript.extend(['$ FM_HOME=<fixture> bin/fm-prior-art.sh '+ ' '.join(map(repr,args)), proc.stdout+proc.stderr, f'Exit: {proc.returncode}; elapsed: {elapsed:.3f}s', ''])
 assert proc.returncode == expected, proc.stdout+proc.stderr
 return proc.stdout+proc.stderr, elapsed
out, _ = run(['--limit','3','memoire','contexte','enquete','rapports','locale'])
assert 'memoire-scout/report.md' in out and '2026-09-01  (stated in the document)' in out and 'déjà évalué' in out
out, _ = run(['budgetneedle'])
assert '   > -10% marge nette pour budgetneedle' in out
transcript.append('Counterfactual: the same source and query on the commit immediately before the quotation fix:')
old, _ = run(['budgetneedle'], tool=root / '.test-prior-art-phase/bin/fm-prior-art.sh')
assert '   > 10% marge nette pour budgetneedle' in old
out, _ = run(["l'agent"])
assert "   > L'agent consulte d'abord" in out and 'FOUND NOWHERE' not in out
out, _ = run(['uncertainneedle'])
assert '2025-07-10  (stated in the document)' in out and '(dated section)' not in out
out, _ = run(['unexploredneedle'])
assert 'FOUND NOWHERE: unexploredneedle' in out and 'source: data/' not in out
assert snapshot() == initial, 'lookup altered source bytes, modes or modification times'
transcript.append('Verified: all original record bytes, modes and modification times are unchanged after lookup.')
p = data / 'memoire-scout/report.md'
p.write_text(records['memoire-scout/report.md']+'\nUne nouvelle conclusion: freshnessneedle.\n')
changed = snapshot()
out, _ = run(['freshnessneedle'])
assert '   > Une nouvelle conclusion: freshnessneedle.' in out and 'index rebuilt' in out
out, _ = run(['freshnessneedle'])
assert 'index reused' in out
cache = home/'state/prior-art'
for p in [cache,*cache.rglob('*')]:
 assert p.stat().st_mode & 0o777 == (0o700 if p.is_dir() else 0o600), str(p)
transcript.append('Persisted cache permissions verified: directories 0700; every cached file 0600. Records remain 0600.')
# Reuse must repair older permissive caches.
for p in cache.rglob('*'):
 p.chmod(0o755 if p.is_dir() else 0o644)
cache.chmod(0o755)
run(['freshnessneedle'], record=False)
for p in [cache,*cache.rglob('*')]:
 assert p.stat().st_mode & 0o777 == (0o700 if p.is_dir() else 0o600), str(p)
transcript.append('A deliberately permissive cache was repaired on reuse to the same private modes.')
assert snapshot() == changed
outside = [str(p.relative_to(home)) for p in home.rglob('*') if p.is_file() and not p.is_relative_to(data) and not p.is_relative_to(cache)]
assert not outside, outside
transcript.append('No generated files exist outside state/prior-art in the fixture home. All lookups completed with network access denied.')
(evidence/'prior-art-cli-transcript.txt').write_text('\n'.join(transcript))
print('\n'.join(transcript))
