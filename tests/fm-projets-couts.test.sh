#!/usr/bin/env bash
# Behavioral measurement of synthetic Claude JSONL logs through the public command.
set -eu
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-projets-couts)
export FM_HOME="$TMP_ROOT/home" FM_PROJETS_CLAUDE_ROOT="$TMP_ROOT/logs"
unset FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE
mkdir -p "$FM_HOME" "$FM_PROJETS_CLAUDE_ROOT/-Users-test-agent-platform" "$FM_PROJETS_CLAUDE_ROOT/-Users-test-Solos"
"$ROOT/bin/fm-projets-board.sh" init >/dev/null
python3 - "$FM_PROJETS_CLAUDE_ROOT" <<'PY'
import json, sys
from pathlib import Path
root=Path(sys.argv[1])
def assistant(rid, model, usage, month="09"):
    return {"type":"assistant","requestId":rid,"timestamp":f"2026-{month}-11T10:00:00Z","message":{"model":model,"usage":usage}}
a=assistant("one","claude-opus-4-6",{"input_tokens":1000000,"output_tokens":100000,"cache_creation_input_tokens":300000,"cache_creation":{"ephemeral_5m_input_tokens":200000,"ephemeral_1h_input_tokens":100000},"cache_read_input_tokens":500000})
rows=[{"type":"user","message":{"content":[{"type":"text","text":"Write state/torre-test.status"}]}},a,a,assistant("old","claude-opus-4-6",{"input_tokens":99999999},"08")]
(root/"-Users-test-agent-platform"/"one.jsonl").write_text("\n".join(map(json.dumps,rows))+"\n")
(root/"-Users-test-Solos"/"two.jsonl").write_text(json.dumps(assistant("two","claude-sonnet-4-6",{"input_tokens":100000}))+"\n")
PY
"$ROOT/bin/fm-projets-couts.sh" --period 2026-09 --eur-rate 0.9 >/dev/null
jq -e '.period == "2026-09" and .projects.torre.tokens_api_usd == 10 and .projects.torre.tokens_api_eur == 9 and .projects.solos.tokens_api_usd == 0.3
  and .projects.torre.subscription_share_pct == 95 and .projects.solos.subscription_share_pct == 5
  and (.projects.torre.sources.missing | index("Codex : journaux non lus") != null)' "$FM_HOME/data/projets-couts.json" >/dev/null || fail "costs or attribution incorrect"
cp "$FM_HOME/data/projets-couts.json" "$TMP_ROOT/first.json"
"$ROOT/bin/fm-projets-couts.sh" --period 2026-09 --eur-rate 0.9 >/dev/null
cmp "$TMP_ROOT/first.json" "$FM_HOME/data/projets-couts.json" || fail "cache changed measured output"
printf '%s\n' '{"type":"assistant","requestId":"unknown","timestamp":"2026-09-11T11:00:00Z","message":{"model":"unknown","usage":{"input_tokens":100000}}}' >> "$FM_PROJETS_CLAUDE_ROOT/-Users-test-Solos/two.jsonl"
"$ROOT/bin/fm-projets-couts.sh" --period 2026-09 >/dev/null
jq -e '.projects.torre.tokens_api_eur == null and .projects.solos.tokens_api_usd == 0.3
  and (.projects.solos.sources.missing | index("modèle inconnu : prix absent") != null)
  and .projects.torre.subscription_share_pct < 95' "$FM_HOME/data/projets-couts.json" >/dev/null || fail "incremental append or missing model handling failed"
"$ROOT/bin/fm-projets-couts.sh" --period 2026-08 --eur-rate 0.9 >/dev/null
jq -e '.period == "2026-08" and .projects.torre.tokens_api_usd > 499' "$FM_HOME/data/projets-couts.json" >/dev/null || fail "month change reused old cache"
pass "monthly costs deduplicate requests, price cache tiers, attribute projects and refresh incrementally"

mkdir -p "$FM_PROJETS_CLAUDE_ROOT/-Users-test-agent-platform/one/subagents"
python3 - "$FM_PROJETS_CLAUDE_ROOT" <<'PYLOG'
import json, sys
from pathlib import Path
root=Path(sys.argv[1])
parent=root/"-Users-test-agent-platform/one.jsonl"
a=json.loads(parent.read_text().splitlines()[1])
b={"type":"assistant","requestId":"child","timestamp":"2026-09-11T10:00:00Z","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":1000000}}}
child=root/"-Users-test-agent-platform/one/subagents/agent-one.jsonl"
child.write_text("\n".join(map(json.dumps,[{"type":"user","message":{"content":"state/solos-incorrect.status"}},a,b]))+"\n")
PYLOG
"$ROOT/bin/fm-projets-couts.sh" --period 2026-09 >/dev/null
jq -e '.projects.torre.tokens_api_usd == 13 and .projects.solos.tokens_api_usd == 0.3 and .projects.torre.subscription_share_pct == 93.55' "$FM_HOME/data/projets-couts.json" >/dev/null || fail "nested usage attribution or global deduplication failed"
for content in 'malformed' '{"type":"user","message":{"content":"state/torre-test.status"}}' '{"type":"assistant","requestId":"empty","timestamp":"2026-09-11T10:00:00Z","message":{"model":"claude-sonnet-4-6","usage":{}}}'; do
  mkdir -p "$TMP_ROOT/unusable/project"
  printf '%s\n' "$content" > "$TMP_ROOT/unusable/project/log.jsonl"
  FM_PROJETS_CLAUDE_ROOT="$TMP_ROOT/unusable" "$ROOT/bin/fm-projets-couts.sh" --period 2026-09 >/dev/null
  jq -e '.projects | all(.[]; .tokens_api_usd == null and .subscription_share_pct == null and .sources.measured == [] and any(.sources.missing[]; contains("aucune requête exploitable")))' "$FM_HOME/data/projets-couts.json" >/dev/null || fail "unusable logs reported measured zero"
done
pass "nested requests inherit parent attribution and unusable logs remain unmeasured"
