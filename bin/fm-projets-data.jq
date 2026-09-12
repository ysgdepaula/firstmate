# Allowed links: HTTPS anywhere; HTTP only on loopback, RFC 1918 private ranges,
# the 100.64/10 shared range the captain's Tailscale network uses, and .ts.net hosts.
def project_url:
  . as $url
  | if type != "string" then false
    elif test("[[:space:]\\\\<>\"[:cntrl:]]") then false
    else ((try capture("^(?<scheme>https?)://(?<host>\\[[0-9A-Fa-f:]+\\]|[A-Za-z0-9][A-Za-z0-9.-]*)(?::(?<port>[0-9]{1,5}))?(?:[/?#].*)?$"; "i") catch null) // null) as $u
    | if $u == null then false
      elif $u.port != null and (($u.port | tonumber) < 1 or ($u.port | tonumber) > 65535) then false
      elif ($u.scheme | ascii_downcase) == "https" then true
      else ($u.host | ascii_downcase) as $h
      | if $h == "localhost" or $h == "[::1]" or ($h | endswith(".ts.net")) then true
        elif ($h | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")) then
          ($h | split(".")) as $parts
          | ($parts | map(tonumber)) as $ip
          | all($parts[]; . == "0" or (startswith("0") | not))
            and all($ip[]; . >= 0 and . <= 255)
            and ($ip[0] == 127 or $ip[0] == 10 or ($ip[0] == 172 and $ip[1] >= 16 and $ip[1] <= 31) or ($ip[0] == 192 and $ip[1] == 168)
                 or ($ip[0] == 100 and $ip[1] >= 64 and $ip[1] <= 127))
        else false end
      end
    end;
def project_link:
  if . == null or . == "" or . == "-" then {url:null}
  elif project_url then {url:.} else {url:null,url_refused:.} end;
def project_epoch:
  if type != "string" then null else
    (try (capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.[0-9]+)?(?<zone>Z|[+-][0-9]{2}:[0-9]{2})$") as $t
      | ($t.base + "Z" | fromdateiso8601) -
        (if $t.zone == "Z" then 0 else
          (($t.zone[1:3] | tonumber) * 3600 + ($t.zone[4:6] | tonumber) * 60)
          * (if $t.zone[:1] == "+" then 1 else -1 end) end)) catch null) // null
  end;
# "Projects page" in docs/configuration.md owns decision-link eligibility and
# the custom-port limitation; keep this narrower than ordinary project links
# so a document or PR is not presented as the page for settling the decision.
def project_page_url:
  if (project_url | not) then false
  else ((try capture("^https?://(?<host>\\[[0-9A-Fa-f:]+\\]|[A-Za-z0-9][A-Za-z0-9.-]*)(?::(?<port>[0-9]{1,5}))?(?:[/?#].*)?$"; "i") catch null) // null) as $u
    | if $u == null then false
      else ($u.host | ascii_downcase) as $h
      | (($u.port // "") == "4387" or ($u.port // "") == "4390")
        and ($h == "localhost" or $h == "127.0.0.1" or $h == "[::1]" or ($h | endswith(".ts.net")))
      end
  end;
# Input: the candidate links recorded for one held call, best first. Output: the
# first one that is a decision page, or null so the page can name the gap.
def project_page:
  [ (.[]? | select(type == "string") | select(project_page_url)) ] | .[0]
  | if . == null then null else {url: .} end;
