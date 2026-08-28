#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/fourth-law-agent
ISSUE_REPO=Tarun1303/factory
ISSUE_NUM=7

post(){
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$ISSUE_NUM" --repo "$ISSUE_REPO" --body "$1" >/dev/null 2>&1 || true
}

fail(){
  post "PERMANENT_CONTROL_ROOM_FAILED {\"stage\":\"${1:-unknown}\"}"
  exit 1
}

# Discover the VPS public IPv4. Prefer an external view; fall back to the default route address.
IP="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
if [[ -z "$IP" ]]; then
  IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
fi
[[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail public_ip

DASH_IP="${IP//./-}"
CANDIDATES=("fourth-law-${DASH_IP}.sslip.io" "fourth-law-${DASH_IP}.nip.io")
HOST=""
for h in "${CANDIDATES[@]}"; do
  if getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | grep -qx "$IP"; then
    HOST="$h"
    break
  fi
done
[[ -n "$HOST" ]] || fail wildcard_dns

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/tmp/fl094-apt-update.log 2>&1 || fail apt_update
apt-get install -y caddy >/tmp/fl094-caddy-install.log 2>&1 || fail caddy_install

# Keep the private agent API bound to localhost. Only Control Room paths are exposed.
cat >/etc/caddy/Caddyfile <<EOF
$HOST {
    encode zstd gzip

    @control path /control-room /control-room/*
    handle @control {
        reverse_proxy 127.0.0.1:8787 {
            flush_interval -1
        }
    }

    handle {
        respond "Not Found" 404
    }

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer"
        X-Frame-Options "DENY"
        Permissions-Policy "camera=(), microphone=(), geolocation=()"
    }
}
EOF

caddy validate --config /etc/caddy/Caddyfile >/tmp/fl094-caddy-validate.log 2>&1 || fail caddy_validate

# Open only standard HTTPS/ACME ports if UFW is active.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
fi

systemctl enable caddy >/dev/null 2>&1 || true
systemctl restart caddy || fail caddy_start

# Wait for a trusted public TLS certificate and the actual Control Room page.
ok=0
for i in $(seq 1 60); do
  if curl -4fsS --max-time 12 "https://$HOST/control-room" 2>/dev/null | grep -q 'Fourth Law · Control Room'; then
    ok=1
    break
  fi
  sleep 2
done

# If sslip.io certificate issuance was unavailable/rate-limited, try nip.io automatically.
if [[ "$ok" != 1 && "$HOST" == *.sslip.io ]]; then
  ALT="fourth-law-${DASH_IP}.nip.io"
  if getent ahostsv4 "$ALT" 2>/dev/null | awk '{print $1}' | grep -qx "$IP"; then
    HOST="$ALT"
    python3 - <<PY
from pathlib import Path
p=Path('/etc/caddy/Caddyfile')
s=p.read_text()
s=s.replace('fourth-law-${DASH_IP}.sslip.io', 'fourth-law-${DASH_IP}.nip.io', 1)
p.write_text(s)
PY
    caddy validate --config /etc/caddy/Caddyfile >/tmp/fl094-caddy-alt-validate.log 2>&1 || fail caddy_alt_validate
    systemctl restart caddy || fail caddy_alt_start
    for i in $(seq 1 60); do
      if curl -4fsS --max-time 12 "https://$HOST/control-room" 2>/dev/null | grep -q 'Fourth Law · Control Room'; then
        ok=1
        break
      fi
      sleep 2
    done
  fi
fi
[[ "$ok" = 1 ]] || fail https_validation

# Verify the backend itself is still private/local and healthy.
curl -fsS http://127.0.0.1:8787/health >/tmp/fl094-health.json || fail local_health
grep -q '"ok":true' /tmp/fl094-health.json || fail local_health_payload

# New hostname means a new secure cookie origin. Issue a fresh 30-minute one-time pair code.
cd "$PROJECT"
PAIR="$(docker compose exec -T agent python - <<'PY'
from app.control_room import generate_pair_code
print(generate_pair_code())
PY
)"
[[ -n "$PAIR" ]] || fail pairing_code

# Prove the public route does not expose the rest of the agent API.
STATUS="$(curl -4sS -o /tmp/fl094-root -w '%{http_code}' "https://$HOST/health" || true)"
[[ "$STATUS" = "404" ]] || fail public_api_scope

# Persist the stable URL locally for helpers/diagnostics.
install -d -m 700 /var/lib/fourthlaw
cat >/var/lib/fourthlaw/control-room-url <<EOF
https://$HOST/control-room
EOF
chmod 600 /var/lib/fourthlaw/control-room-url

post "PERMANENT_CONTROL_ROOM_READY {\"url\":\"https://$HOST/control-room\",\"pair_code\":\"$PAIR\",\"pair_ttl_minutes\":30,\"https\":\"Caddy+public-CA\",\"dns\":\"IP-derived wildcard DNS\",\"reboot_persistent\":true,\"certificate_auto_renew\":true,\"public_scope\":\"/control-room only\",\"quick_tunnel_required\":false}"

echo "PERMANENT_CONTROL_ROOM_READY"
echo "https://$HOST/control-room"
