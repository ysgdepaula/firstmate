#!/usr/bin/env bash
# Durable task events shared by PR registration, merge publication and answers.
# fm_task_event_append <data-root> <task-id> <key> <at> <kind> <what> <url> [repo]
# writes one fm-task-events.v1 JSON object per line in data/<id>/events.jsonl:
# schema, key (idempotency identity), at (ISO UTC), kind (pr, merge, decision,
# landed), what, url (string or null), repo (optional routing name or null).
# A repeated key or PR URL preserves its original event across worker generations.
# Publication uses an atomic replace
# under events.jsonl.lock; callers must have loaded fm-wake-lib.sh lock helpers.
# Task cleanup retains this file with the other durable data/<id>/ artifacts.
fm_task_event_append() (
  local data=$1 id=$2 key=$3 at=$4 kind=$5 what=$6 url=$7 repo=${8:-}
  local dir file lock tmp='' row
  case "$id" in ''|.|..|*[!A-Za-z0-9._-]*) return 2 ;; esac
  case "$kind" in pr|merge|decision|landed) ;; *) return 2 ;; esac
  row=$(jq -cn --arg key "$key" --arg at "$at" --arg kind "$kind" --arg what "$what" --arg url "$url" --arg repo "$repo" '
    select(($key | length) > 0 and ($at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
    | {schema:"fm-task-events.v1",key:$key,at:$at,kind:$kind,what:$what,
       url:($url | if . == "" then null else . end),repo:($repo | if . == "" then null else . end)}') || return 1
  [ -n "$row" ] || return 2
  dir="$data/$id"
  file="$dir/events.jsonl"
  lock="$dir/events.jsonl.lock"
  [ ! -L "$data" ] && [ ! -L "$dir" ] && [ ! -L "$file" ] || return 1
  umask 077
  mkdir -p "$dir" || return 1
  fm_lock_acquire_wait "$lock" || return 1
  trap '[ -z "$tmp" ] || rm -f -- "$tmp"; fm_lock_release "$lock"' EXIT
  [ ! -L "$file" ] || return 1
  if [ -f "$file" ]; then
    jq -se 'all(.[]; .schema == "fm-task-events.v1")' "$file" >/dev/null || return 1
    if jq -se --arg key "$key" --arg kind "$kind" --arg url "$url" '
      any(.[]; .key == $key or ($kind == "pr" and $url != "" and .kind == "pr" and .url == $url))
    ' "$file" >/dev/null; then return 0; fi
  fi
  tmp=$(mktemp "$dir/.events.XXXXXX") || return 1
  if [ -f "$file" ]; then cat "$file" > "$tmp" || return 1; fi
  printf '%s\n' "$row" >> "$tmp" || return 1
  mv -f -- "$tmp" "$file" || return 1
  tmp=''
)
