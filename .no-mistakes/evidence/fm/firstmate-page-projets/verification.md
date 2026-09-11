# Project-page test evidence

Validated commit 533404df42dbdd3f8b49d860b2964e4bf3e1ccc9 using synthetic, isolated homes.
The screenshots use the shipped project template and public init, compose and render commands with the established behavioral fixture, extended to all seven seed projects and recommendation, creation and brain article examples.
Mobile screenshots contain a 390 px iframe inside a 500 px Chrome host; the grey strip is outside the tested viewport.
The opt-in browser test independently asserted the selected card, 390 px viewport, folded/expanded state, no overflow and no covered text or controls for Torre and Cerveau.

Commands executed:

- `TMPDIR="$PWD/.test-tmp" bash tests/fm-projets-board.test.sh`
- `TMPDIR="$PWD/.test-tmp" bash tests/fm-projets-board-render.test.sh`
- `TMPDIR="$PWD/.test-tmp" bash tests/fm-projets-events.test.sh`
- `TMPDIR="$PWD/.test-tmp" bash tests/fm-projets-couts.test.sh`
- `TMPDIR="$PWD/.test-tmp" bash tests/fm-projets-serve.test.sh`
- `TMPDIR="$PWD/.test-tmp" FM_PROJETS_CHROME_TEST=1 bash tests/fm-projets-board-chrome.test.sh`
- `python3 .test-tmp/capture-evidence.py`: public composition/rendering, actual loopback HTTP GETs for the index, page and shared document, and headless Chrome screenshots. Chrome initially retained a process after screenshot output; bounded process-group cleanup resolved capture teardown and the driver completed successfully.
- `node tests/assets/projets-render-harness.mjs <evidence>/projets-rendered.html click=torre/torre-hebergement/chez-toi`: captured the emitted Lavish prompt and bridge calls in answer-submission.json using the test bridge.
- Visually inspected desktop, folded and expanded mobile cards, HTTP index and fallback screenshots.

All focused tests passed. HTTP availability probes and file delivery used real loopback servers. Lavish and launchctl integration used test doubles; no live session was messaged, no user service was installed, and reboot/MagicDNS reachability were not exercised. The launchd test consumed the generated plist and verified install/start/stop/uninstall behavior with its recording stand-in. No full suite, linter, formatter, push or CI phase was run. Test fixtures were removed after completion.
