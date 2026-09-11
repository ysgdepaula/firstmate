# Projects decision/status validation

Executed the public composer and renderer with the included `snapshot.json` and `config.json`. These are synthetic held tasks, not private fleet data.

- `TMPDIR="$PWD/.test-tmp" bash tests/fm-projets-board.test.sh`: passed.
- `TMPDIR="$PWD/.test-tmp" bash tests/fm-projets-board-render.test.sh`: passed.
- `TMPDIR="$PWD/.test-tmp" FM_PROJETS_CHROME_TEST=1 bash tests/fm-projets-board-chrome.test.sh`: passed, including folded/unfolded cards at 390 px and visible delivery failure without Lavish.
- `python3 .test-tmp/compose-evidence.py`: executed baseline 437b4a06 and current composer against identical fixtures, asserted the old done-state fallback and the new separate decision/status outputs, preserved configured choices, and rendered the current payload.
- `node .test-tmp/browser-evidence.mjs`: loaded the generated page in isolated Chrome at 1280 px and 390 px, asserted visible choices and admission, captured screenshots, then used real pointer events for “on ne le fait pas”, “pas encore”, and “je l’ai fait”. Correct project, task, choice, and nature reached the transport double. No live Lavish messages were sent.
- Visually inspected all three screenshots: question wording, explicit unknown-state admission, wrapped buttons, and acknowledgment text remain readable.

The rendered HTML uses the repository’s shipped design and template. The transport is an in-memory Lavish double; this validates emitted requests and acknowledgments, not delivery to a live Firstmate session. Existing focused tests also exercised unavailable and rejected delivery.

Temporary fixtures, baseline executable, and browser profiles were removed from the worktree. No source changes, lint, full-suite run, push, PR, or CI operations were performed.
