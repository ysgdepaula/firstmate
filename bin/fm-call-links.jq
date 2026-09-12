def call_link_candidates($row_links; $status_text):
  [ ($row_links // [])[], ($status_text // "") ]
  | map(select(type == "string") | scan("https?://[^[:space:])\"<>`\u0027\\]}]+"))
  | map(select(test("(…|[.][.][.])[.,;:!?]*$") | not))
  | map(sub("[.,;:!?]+$"; ""))
  | map(select(length > 0 and length <= 500))
  | reduce .[] as $u ([]; if index($u) == null then . + [$u] else . end);
