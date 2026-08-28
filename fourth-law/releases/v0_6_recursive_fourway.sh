#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT=/opt/fourth-law-agent
BASE=https://raw.githubusercontent.com/Tarun1303/esp-open-rtos/fourth-law-bootstrap/fourth-law/releases
[[ $EUID -eq 0 ]]
[[ -d "$PROJECT" && -f "$PROJECT/.env" ]]
cd "$PROJECT"
mkdir -p app/static /usr/local/lib/fourthlaw-bridge /var/lib/fourthlaw-bridge
python3 - <<'PY'
from pathlib import Path
p=Path("/opt/fourth-law-agent/.env")
rows={}; order=[]
for line in p.read_text().splitlines():
    if "=" in line and not line.lstrip().startswith("#"):
        k,v=line.split("=",1); rows[k]=v
        if k not in order: order.append(k)
updates={"SUPERVISOR_MODEL":"gpt-5.6-terra","MASTER_MODEL":"gpt-5.6-terra","WORKER_MODEL":"gpt-5.6-luna","MAX_CONCURRENCY":"8","DEFAULT_MAX_DEPTH":"3","MAX_AGENTS":"85","API_RETRIES":"4","NODE_RECOVERY_ATTEMPTS":"2"}
rows.update(updates)
for k in updates:
    if k not in order: order.append(k)
p.write_text("\n".join(f"{k}={rows[k]}" for k in order if k in rows)+"\n"); p.chmod(0o600)
PY
curl -fsSL "$BASE/v0_6_main.py" -o app/main.py
curl -fsSL "$BASE/v0_6_console.html" -o app/static/console.html
python3 -m py_compile app/main.py
docker compose build agent
docker compose up -d agent
ok=0
for i in $(seq 1 50); do
  if curl -fsS http://127.0.0.1:8787/health >/tmp/flv06-health.json 2>/dev/null; then ok=1; break; fi
  sleep 2
done
[[ "$ok" = 1 ]]
grep -q '0.6.0' /tmp/flv06-health.json
curl -fsSL "$BASE/v0_6_bridge.py" -o /usr/local/lib/fourthlaw-bridge/bridge.py
chmod 700 /usr/local/lib/fourthlaw-bridge/bridge.py
cat > /etc/systemd/system/fourthlaw-command-bridge.service <<'EOF'
[Unit]
Description=Fourth Law GitHub Command Bridge
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=simple
Environment=HOME=/root
Environment=GH_CONFIG_DIR=/root/.config/gh
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/bin/python3 /usr/local/lib/fourthlaw-bridge/bridge.py
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=/var/lib/fourthlaw-bridge /var/log /opt/fourth-law-agent /tmp
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now fourthlaw-command-bridge.service
systemctl restart fourthlaw-command-bridge.service
if [[ -x /usr/local/bin/fourthlaw-diagnostic-sync ]]; then /usr/local/bin/fourthlaw-diagnostic-sync || true; fi
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh issue comment 7 --repo Tarun1303/factory --body 'CONTROL_ROOM_V0_6_DEPLOYED' >/dev/null 2>&1 || true
fi
echo FOURTHLAW_V0_6_READY
cat /tmp/flv06-health.json
