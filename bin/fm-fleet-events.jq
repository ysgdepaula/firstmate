def fleet_events($backlog; $tasks; $evidence):
  def row($id): ([$backlog.records[]? | select(.id == $id)] | last) // {};
  ([$evidence[] | select(.recorded == true) | . + {repo:(.repo // row(.id).repo)}]) as $recorded
  | ([ $tasks[] | select(.kind != "secondmate" and .pr.url != null)
     | {id,repo:(row(.id).repo // .project),kind:"pr",what:("PR ouverte : " + (row(.id).title // .id)),url:.pr.url,at:(.pr.recorded_at // null)} ]
   + [ $backlog.records[]? | select(.structured)
       | ((.body_lines // []) | join("\n")) as $body
       | if ($body | test("Resolution recorded by fm-(captain|decision)-hold\\.")) then
           {id,repo,kind:"decision",what:("décision répondue : " + .title),url:.pr_url,
            at:(([ $body | scan("Resolution at: ([0-9T:Z+.-]+)") | .[0] ] | first) // .completion.date)}
         else empty end,
         if .state == "done" and .hold_kind != "captain" then
           {id,repo,kind:(if .completion.verb == "merged" then "merge" else "landed" end),what:.title,url:.pr_url,at:.completion.date}
         else empty end ]
   + [$evidence[] | select(.recorded != true) | . + {repo:(row(.id).repo // null),what:((if .kind == "merge" then "PR fusionnée : " else "livraison : " end) + (row(.id).title // .id))}])
  | map(. as $fallback | select(any($recorded[]; .id == $fallback.id and .kind == $fallback.kind and (.url == $fallback.url or $fallback.kind == "decision")) | not))
  | . + $recorded
  | to_entries
  | group_by([.value.id,.value.kind,.value.url,(if .value.recorded then .value.key else null end)])
  | map(sort_by([(.value.at // ""),-.key]) | last)
  | sort_by(.key) | map(.value | del(.recorded,.schema,.key));

def fleet_event_projection($events; $per_task; $total):
  ($events | to_entries | sort_by([(.value.at // ""), -.key]) | reverse | map(.value)) as $ordered
  | reduce $ordered[] as $event ({events:[], counts:{}, bytes:2};
      if (.counts[$event.id] // 0) < $per_task and (.events | length) < $total then
        ($event | {id,repo,owner,kind,what:((.what // "") | if length > 240 then .[:240] + "…" else . end),url,at}) as $row
        | ($row | tojson | utf8bytelength) as $bytes
        | if .bytes + $bytes + 1 <= 32768 then
            .events += [$row] | .counts[$event.id] = ((.counts[$event.id] // 0) + 1) | .bytes += ($bytes + 1)
          else . end
      else . end)
  | {events, omitted:([
      (if ($events | length) > (.events | length) then
        {surface:"events_truncated",count:(($events | length) - (.events | length)),reveal:"FM_SNAPSHOT_SECONDMATE_EVENTS_PER_TASK / FM_SNAPSHOT_SECONDMATE_EVENTS; 32768-byte event budget"}
       else empty end),
      (([.events[] | select((.what | length) > 240)] | length) as $n
      | if $n > 0 then {surface:"events_text_truncated",count:$n,reveal:"read the durable task journal"} else empty end)
    ])};
