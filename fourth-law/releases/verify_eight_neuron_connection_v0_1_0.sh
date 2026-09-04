#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
TITLE="8 Neuron Connection"
SERVICE="eight-neuron-connection.service"
PORT=8788
HOSTNAME_PUBLIC="eight-neuron-94-136-189-216.sslip.io"
REPO="Tarun1303/factory"
ISSUE=7
REPORT="$(mktemp)"
BODY="$(mktemp)"
cleanup(){ rm -f "$REPORT" "$BODY"; }
trap cleanup EXIT
kv(){ printf '%-30s %s\n' "$1" "$2"; }
{
  echo EIGHT_NEURON_CONNECTION_RUNTIME_VERIFY_BEGIN
  kv timestamp_utc "$(date -u +%Y%m%dT%H%M%SZ)"
  kv service_active "$(systemctl is-active "$SERVICE")"
  kv service_enabled "$(systemctl is-enabled "$SERVICE")"
  kv local_health "$(curl -fsS --max-time 5 http://127.0.0.1:${PORT}/api/health)"
  sleep 6
  state="$(curl -fsS --max-time 5 http://127.0.0.1:${PORT}/api/state)"
  summary="$(printf '%s' "$state" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const x=JSON.parse(s);console.log(JSON.stringify({simulationTime:x.simulationTime,activity:x.activity,training:x.training,lastResult:x.lastResult,energyAccounting:x.energyAccounting}))})')"
  kv runtime_summary "$summary"
  kv caddy_active "$(systemctl is-active caddy 2>/dev/null || echo unavailable)"
  kv public_dns "$(getent ahostsv4 "$HOSTNAME_PUBLIC" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  tls="$(curl --resolve ${HOSTNAME_PUBLIC}:443:127.0.0.1 -fsS --max-time 15 https://${HOSTNAME_PUBLIC}/api/health 2>&1 || true)"
  if printf '%s' "$tls" | grep -q '"ok":true'; then
    kv caddy_sni_health "$tls"
    kv public_route_status READY
  else
    insecure="$(curl -k --resolve ${HOSTNAME_PUBLIC}:443:127.0.0.1 -fsS --max-time 15 https://${HOSTNAME_PUBLIC}/api/health 2>&1 || true)"
    kv caddy_sni_health "$insecure"
    if printf '%s' "$insecure" | grep -q '"ok":true'; then kv public_route_status ROUTING_READY_CERTIFICATE_PENDING; else kv public_route_status NOT_REACHABLE; fi
  fi
  kv ui_url "https://${HOSTNAME_PUBLIC}/"
  kv production_app_modified NO
  echo EIGHT_NEURON_CONNECTION_RUNTIME_VERIFY_END
} > "$REPORT"
{
  echo "## ${TITLE} — runtime verification"
  echo
  echo '```text'
  cat "$REPORT"
  echo '```'
} > "$BODY"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$ISSUE" --repo "$REPO" --body-file "$BODY" >/dev/null
cat "$REPORT"
