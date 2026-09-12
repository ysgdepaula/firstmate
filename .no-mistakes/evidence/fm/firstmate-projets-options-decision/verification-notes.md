# Projects decision/status validation

The screenshots and HTML are the actual shipped template rendered from a representative fleet snapshot through `bin/fm-projets-board.sh compose` and `render`.
The project uses its existing design unchanged.

Focused automated checks:
- `bash tests/fm-projets-board.test.sh`
- `bash tests/fm-projets-board-render.test.sh`
- `FM_PROJETS_CHROME_TEST=1 bash tests/fm-projets-board-chrome.test.sh`

All passed.
The Chrome test exercises the stable-address delivery refusal and folded/unfolded cards at 390 pixels.

Manual evidence checks:
- Execute base and target composers with identical held-task and correspondence-table fixtures, without quota access.
- Confirm the base emits the original completion option, while the target emits proceed/refuse/defer/discuss choices for the unconfigured decision.
- Confirm explicitly configured unknown state displays its admission, and custom hosting choices survive unchanged.
- Render target output and capture it in isolated headless Chrome at 1400 and 390 pixels.
- Visually inspect both screenshots and check for horizontal overflow.
- Click every default decision and status choice, plus a custom choice, using a local interception of the Lavish queue/send API.
- Verify the selected choice and nature in each delivered payload, visible success feedback, and the absence of keyed question/answer fields that would close a task.
- Reject delivery and verify visible “non transmis” feedback.
- Parse base and target workflow YAML with Ruby Psych, normalize the base serial timeout to 40, and assert complete semantic equality.

The PyYAML dependency probe found no installed module; the workflow check succeeded using the already-installed Ruby Psych parser.
No package installation was needed.
Live Lavish transport and downstream agent interpretation were not exercised; browser-interactions.json explicitly records the locally intercepted delivery boundary.
No source changes were required.
