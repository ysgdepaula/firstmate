# Projects decision/status validation

Identical synthetic fleet records were composed and rendered using base 437b4a06 and target b242ae7f.
The base offers “c’est fait” for an unconfigured decision and no admission of unknown completion.
The target offers “on y va / on ne le fait pas / pas maintenant / on en parle” for that decision.
Explicit status cards say “je ne sais pas si c’est déjà fait” and offer “je l’ai fait / pas encore / on en parle”.
Configured decision and status choices are preserved, and configured status choices still show the uncertainty admission.

## Executed checks

- `TMPDIR="$PWD/.test-phase-tmp" FM_TEST_SKIP_ORPHAN_REAP=1 bash tests/fm-projets-board.test.sh`
- `TMPDIR="$PWD/.test-phase-tmp" FM_TEST_SKIP_ORPHAN_REAP=1 bash tests/fm-projets-board-render.test.sh`
- `TMPDIR="$PWD/.test-phase-tmp" FM_TEST_SKIP_ORPHAN_REAP=1 FM_PROJETS_CHROME_TEST=1 bash tests/fm-projets-board-chrome.test.sh`
- `python3 .test-phase-tmp/compose-evidence.py` (script retained beside this report).
- `node .test-phase-tmp/browser-evidence.mjs` (script retained beside this report).
- The shipped DOM harness exercised `click=torre/torre-domaine/je-l-ai-fait` and `click=torre/torre-relance/on-ne-le-fait-pas` against `after.html`; payload assertions passed.
- Ruby YAML parsing and normalized comparison with the base verified that the sole workflow semantic change is the portable serial timeout from 20 to 40 minutes.
- Visually inspected `after-desktop.png` and `after-phone.png`; both show readable, separate decision and status cards.

All focused tests passed, including malformed status-card rejection, delivery refusal without Lavish, and folded/unfolded 390px geometry.
The initial chrome-devtools-axi capture attempt failed because its MCP calls omitted required pageId; direct Chrome DevTools Protocol capture succeeded after selecting the page target instead of the extension target.
Browser clicks used a local Lavish API stub to capture outgoing payloads and verify visible confirmation; live external delivery was not exercised.
No source changes were required, no full-suite or lint checks were run, and temporary files were removed from the worktree.
