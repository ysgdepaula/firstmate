# Decision pages: observed behavior

Validated target `6cdc1d543f5e4e816d625bd809d5f9369ef06d06` in an isolated fixture home, with the shipped page templates and an isolated installed Lavish server bound to `[::1]:4387`.
The fixture used fictional decisions modeled on the requested Club workflow. No live fleet tasks or user sessions were modified.

## End-to-end steps

1. Create `club-rose` with `bin/fm-captain-hold.sh hold`, title “Les quatre arbitrages qui débloquent le rosé Anglades”, and a draft review URL. Re-hold the same title with the active review URL. Create `club-audit` without a page and `divers-budget` without a matching project.
2. Execute `bin/fm-bearings-snapshot.sh --json --all-decisions`, then `bin/fm-projets-board.sh compose --snapshot <snapshot.json> --no-quota`, and `render` for both `projets` and `a-valider`.
3. Serve both generated pages in isolated Lavish sessions. Run the real `bin/fm-projets-serve.py` on loopback port 19390. Navigate Chrome through `/projets` and `/a-valider`; each redirects to its distinct active Lavish session.
4. On Projets, click “on y va” for the rosé decision and “on en parle” for the audit. Select both checkboxes and click “créer une page Lavish pour la sélection”. All three requests appear in the actual Conversation queue. Before Send, the server has no pending prompts and the attached poll has produced no feedback.
5. Click Lavish’s “Send to Agent”. One poll response delivers exactly three requests: two `choice` prompts and one `create-lavish` request containing both decision identifiers. See `projets-delivered-prompts.txt`.
6. Verify the persisted backlog still has all three captain holds. The rosé title remains unchanged; its active page precedes the draft fallback. Fetching that active review URL returns HTTP 200. See `held-tasks-after-send.md`.
7. On À valider, verify all three calls appear, including the unmatched budget on Cerveau. Select only the audit and queue a dedicated-page request. Remove it with Lavish’s “Remove queued prompt”; the queue clears and the poll times out without delivery.
8. Render both pages at 390 px in Chrome. Content width remains 390 px; Projets starts with only “Il manque de toi” expanded. Visually inspect the screenshots. Existing Chrome tests also exercise unfolded blocks and check reachability and overlap.

The browser wrapper’s snapshot/evaluate calls failed because its installed MCP requires pageId. Verification continued successfully through Chrome DevTools Protocol with the same installed Chrome, without installing or upgrading tools.

## Targeted automated commands

- `bash tests/fm-projets-board.test.sh`
- `bash tests/fm-projets-board-render.test.sh`
- `bash tests/fm-projets-serve.test.sh`
- `FM_PROJETS_CHROME_TEST=1 bash tests/fm-projets-board-chrome.test.sh`
- `bash tests/fm-captain-hold-lifecycle.test.sh --completion-pages`
- `bash tests/fm-bearings-snapshot.test.sh --captain-links`

All completed successfully. An initial `bash tests/fm-captain-hold-lifecycle.test.sh` was intentionally stopped after four relevant checks when its focused selector was discovered, then rerun with `--completion-pages`. No full repository suite, linters, static analysis, or other pipeline phases were run.

Screenshots and rendered HTML use the project’s existing design. HTML copies are standalone evidence; they are not live Lavish sessions and cannot queue requests when opened alone.
