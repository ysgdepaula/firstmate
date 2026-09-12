def call_link_candidates($row_links; $status_text):
  [ ($row_links // [])[], (($status_text // "") | scan("https?://[^[:space:])\"<>]+")) ]
  | map(select(type == "string" and length > 0 and length <= 500))
  | map(select(endswith("…") or endswith("...") | not))
  | reduce .[] as $u ([]; if index($u) == null then . + [$u] else . end);
