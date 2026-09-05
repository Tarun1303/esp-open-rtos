#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

OWNER="Tarun1303"
NAME="eight-neuron-connection"
REPO="$OWNER/$NAME"
DESCRIPTION="Physics-first recurrent temporal-memory laboratory with local energy accounting, consolidation, and natural re-ignition"
REPORT_REPO="Tarun1303/factory"
REPORT_ISSUE=7
REPORT="$(mktemp)"
BODY="$(mktemp)"
trap 'rm -f "$REPORT" "$BODY"' EXIT
post(){
  {
    echo '## 8 Neuron Connection — private repository creation'
    echo
    echo '```text'
    cat "$REPORT"
    echo '```'
  } > "$BODY"
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh issue comment "$REPORT_ISSUE" --repo "$REPORT_REPO" --body-file "$BODY" >/dev/null 2>&1 || true
}
fail(){ rc=$?; echo "result=FAILED" >> "$REPORT"; echo "exit_code=$rc" >> "$REPORT"; post; exit "$rc"; }
trap fail ERR

for c in gh; do command -v "$c" >/dev/null; done
HOME=/root GH_CONFIG_DIR=/root/.config/gh gh auth status >/dev/null
login="$(HOME=/root GH_CONFIG_DIR=/root/.config/gh gh api user --jq .login)"
[[ "$login" == "$OWNER" ]]
{
  echo EIGHT_NEURON_PRIVATE_REPOSITORY_CREATE_BEGIN
  echo "authenticated_user=$login"
  echo "target_repository=$REPO"
  echo "requested_visibility=private"
  echo "credentials_printed=NO"
} > "$REPORT"

if HOME=/root GH_CONFIG_DIR=/root/.config/gh gh repo view "$REPO" >/dev/null 2>&1; then
  echo "creation=ALREADY_EXISTS" >> "$REPORT"
else
  HOME=/root GH_CONFIG_DIR=/root/.config/gh gh repo create "$REPO" --private --add-readme --description "$DESCRIPTION" >/dev/null
  echo "creation=CREATED" >> "$REPORT"
fi

private="$(HOME=/root GH_CONFIG_DIR=/root/.config/gh gh repo view "$REPO" --json isPrivate --jq .isPrivate)"
default_branch="$(HOME=/root GH_CONFIG_DIR=/root/.config/gh gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name // ""')"
[[ "$private" == true ]]
[[ "$default_branch" == main ]]
{
  echo "verified_private=$private"
  echo "default_branch=$default_branch"
  echo "repository_url=https://github.com/$REPO"
  echo "result=SUCCESS"
  echo EIGHT_NEURON_PRIVATE_REPOSITORY_CREATE_END
} >> "$REPORT"
post
cat "$REPORT"
