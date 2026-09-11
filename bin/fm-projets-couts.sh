#!/usr/bin/env bash
# fm-projets-couts.sh - measure this month's Claude session usage by project.
# Usage: fm-projets-couts.sh [--period YYYY-MM] [--eur-rate EUR_PER_USD]
# Reads FM_PROJETS_CLAUDE_ROOT (default ~/.claude/projects) without modifying it.
# FM_HOME, FM_CONFIG_OVERRIDE and FM_DATA_OVERRIDE scope configuration and output.
# Includes nested subagent logs with parent attribution and global request deduplication.
# Projects without usable requests retain null measurements and missing-source notes.
# Writes data/projets-couts.json and an incremental projets-couts-cache.json.
# Python 3 owns JSONL parsing, request deduplication, attribution and dated prices.
# Without --eur-rate, USD is measured and EUR explicitly remains unavailable.
# No report-derived exchange rate is bundled: the private CRIA report is absent
# from this shared repository. Pass its rate explicitly when available.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-projets-couts.py" "$@"
