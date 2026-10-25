#!/bin/bash
# Weekly maintenance: REPORTS new images, installs nothing.
# Policy: every image is pinned by digest; an update goes through analysis,
# a lab copy and an explicit approval.
# Before: this job pulled a floating tag and recreated the container by itself.
#
# For each image: registry digest for the tag, compared with the pinned digest;
# if it differs -> log + Telegram (name, tag, two short digests).
# Then a check that the service answers.
set -uo pipefail
LOG=${LOG:-/var/log/weekly-maintenance.log}
TG=${TG:-/etc/weekly-maintenance/telegram.env}
log() { echo "$(date -Is) $*" >> "$LOG"; }

# container name | tracked tag | pinned digest | health URL
# The digest below is INVENTED for this example: put the one your container runs.
IMAGES=(
  "uptime-kuma|louislam/uptime-kuma:1|sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef|http://100.x.y.z:3001/"
)
# Recreate uptime-kuma (only for an accepted update, pinned digest changed above):
#   docker rm -f uptime-kuma && docker run -d --name uptime-kuma --restart unless-stopped \
#     -p 100.x.y.z:3001:3001 -v /srv/uptime-kuma-data:/app/data louislam/uptime-kuma:1@<digest>

telegram() {
  [ -r "$TG" ] || { log "telegram: $TG missing, message not sent"; return 0; }
  local token chat
  token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$TG" | tr -d "\"'")
  chat=$(sed -n 's/^TELEGRAM_CHAT_ID=//p' "$TG" | tr -d "\"'")
  [ -n "$token" ] && [ -n "$chat" ] || { log "telegram: incomplete configuration"; return 0; }
  # URL (with the token) passed on stdin: it does not show in the process list.
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" \
    | curl -s -o /dev/null --max-time 30 -K - --data-urlencode "chat_id=$chat" --data-urlencode "text=$1" \
    || log "telegram: send failed"
}

log "=== weekly maintenance (report only) ==="
rc=0
news=()
for entry in "${IMAGES[@]}"; do
  IFS='|' read -r name tag pinned url <<< "$entry"
  remote=$(docker buildx imagetools inspect "$tag" --format '{{.Manifest.Digest}}' 2>/dev/null)
  running=$(docker inspect "$name" --format '{{.Image}}' 2>/dev/null || echo none)
  if [ -z "$remote" ]; then
    log "$name: registry unreachable for $tag"; rc=1
  elif [ "$remote" = "$pinned" ]; then
    log "$name: up to date ($tag = ${pinned:7:12})"
  else
    log "$name: NEW IMAGE for $tag: ${remote:7:12} (pinned ${pinned:7:12}) - nothing installed"
    news+=("$name ($tag): ${remote:7:12}, pinned ${pinned:7:12}")
  fi
  [ "$running" = "$pinned" ] || { log "$name: WARNING, running ${running:7:12} != pinned ${pinned:7:12}"; rc=1; }
  ok=0
  for i in $(seq 1 6); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null)
    case "$code" in 2*|3*) log "$name: OK (HTTP $code)"; ok=1; break;; esac
    sleep 10
  done
  [ $ok = 1 ] || { log "$name: ERROR - no answer (HTTP ${code:-no response})"; rc=1; }
done

if [ ${#news[@]} -gt 0 ]; then
  telegram "Weekly maintenance: ${#news[@]} new image(s), nothing installed. $(printf '%s ; ' "${news[@]}")See /var/log/weekly-maintenance.log"
fi
[ $rc = 0 ] || telegram "Weekly maintenance: anomaly (rc=$rc). See /var/log/weekly-maintenance.log"
log "=== end (rc=$rc) ==="
exit $rc
