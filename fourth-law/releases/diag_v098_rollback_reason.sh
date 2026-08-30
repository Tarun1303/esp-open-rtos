#!/usr/bin/env bash
set -euo pipefail
UNIT='fourthlaw-release-1788095432-53a25cdd.service'
OUT="$(journalctl -u "$UNIT" --no-pager -n 120 2>/dev/null | grep -Ei 'anchor missing|Traceback|SyntaxError|SystemExit|AssertionError|ERROR|failed|V098|not found|unbound|NameError|ImportError|ModuleNotFoundError' | tail -40 || true)"
[[ -n "$OUT" ]] || OUT='NO_MATCHING_ERROR_LINES'
# Remove obvious credential-like assignments defensively.
OUT="$(printf '%s' "$OUT" | sed -E 's/(ADMIN_TOKEN|OPENAI_API_KEY|GITHUB_TOKEN|GH_TOKEN)=[^[:space:]]+/\1=[REDACTED]/g' | head -c 10000)"
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment 7 --repo Tarun1303/factory --body "V098_ROLLBACK_DIAGNOSTIC
\`\`\`text
$OUT
\`\`\`" >/dev/null 2>&1 || true
echo V098_DIAG_READY
