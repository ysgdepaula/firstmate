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
         elif .state == "done" and .hold_kind != "captain" then
           {id,repo,kind:(if .completion.verb == "merged" then "merge" else "landed" end),what:.title,url:.pr_url,at:.completion.date}
         else empty end ]
   + [$evidence[] | select(.recorded != true) | . + {repo:(row(.id).repo // null),what:((if .kind == "merge" then "PR fusionnée : " else "livraison : " end) + (row(.id).title // .id))}])
  | map(. as $fallback | select(any($recorded[]; .id == $fallback.id and .kind == $fallback.kind and (.url == $fallback.url or $fallback.kind == "decision")) | not))
  | . + $recorded
  | to_entries
  | group_by([.value.id,.value.kind,.value.url,(if .value.recorded then .value.key else null end)])
  | map(sort_by([(.value.at // ""),-.key]) | last)
  | sort_by(.key) | map(.value | del(.recorded,.schema,.key));
