# Projects decision-card verification

The screenshots show the shipped page template and composer output using a synthetic fleet with three captain questions: an unconfigured action decision, an explicitly configured unknown status, and an existing custom choice.
The design is the repository’s existing projects-page design.

- Ran `TMPDIR="$PWD/.test-phase-tmp" bash tests/fm-projets-board.test.sh`.
- Ran `TMPDIR="$PWD/.test-phase-tmp" bash tests/fm-projets-board-render.test.sh`.
- Ran `TMPDIR="$PWD/.test-phase-tmp" FM_PROJETS_CHROME_TEST=1 bash tests/fm-projets-board-chrome.test.sh`.
- Ran `TMPDIR="$PWD/.test-phase-tmp" bash tests/fm-task-inbox.test.sh`.
- Executed the base commit’s composer and the target composer with the identical saved `snapshot.json` and `config.json`, `--no-quota --now 2026-09-12T10:00:00Z`.
- Asserted the old completion fallback is reproduced at base, the target separates decision and unknown status choices, and configured choices remain unchanged.
- Rendered `composed-payload.json` through `bin/fm-projets-board.sh render` and saved the resulting unmodified `projets.html`.
- Ran `node .test-phase-tmp/capture.mjs` using isolated headless Chrome, then inspected desktop and phone screenshots.
- The capture script clicked “on ne le fait pas” and “pas encore” in the real page with a local Lavish test adapter, verifying outgoing project, decision, choice and nature values, no keyed answer, visible delivery acknowledgement, and all cards remaining present.
- Parsed base and target workflow YAML with Ruby YAML and compared normalized objects after substituting the serial-job timeout: the only semantic change is 20 to 40 minutes.

All targeted checks passed.
The browser test adapter records outbound calls without sending to a live supervisor; it does not claim live Lavish transport validation.
The baseline and target payloads, before/after transcript, rendered HTML, browser interaction record, screenshots and capture script are retained beside this record.
