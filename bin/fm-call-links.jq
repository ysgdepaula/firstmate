# Candidate extraction shared by snapshots and completion: supplied links keep
# their order, followed by all status lines newest first; duplicates keep their
# first occurrence. There is no candidate-count cap. Prose delimiters and final
# punctuation are stripped, IPv6 authority brackets retained, and clipped URLs
# or URLs longer than 500 characters discarded. Consumers own URL eligibility.
def call_link_candidates($row_links; $status_text):
  [ ($row_links // [])[], (($status_text // "") | split("\n") | reverse[]) ]
  | map(select(type == "string") | scan("https?://(?:\\[[0-9A-Fa-f:.]+\\])?[^[:space:])\"<>`\u0027\\]}]+"))
  | map(select(test("(…|[.][.][.])[.,;:!?]*$") | not))
  | map(sub("[.,;:!?]+$"; ""))
  | map(select(length > 0 and length <= 500))
  | reduce .[] as $u ([]; if index($u) == null then . + [$u] else . end);
