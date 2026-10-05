#!/usr/bin/env bash
#
# check-release.sh — fail when a change forgets the fork's release bookkeeping.
#
# Usage:
#   scripts/check-release.sh [BASE_REF]
#
# Checks:
#   1. Every manifest in .version-bump.json carries the same version.
#   2. Every platform manifest names the plugin "superpowers-custom" and none
#      points at the upstream repo, so no runtime mistakes the fork for the
#      official plugin.
#   3. No skill or hook references the upstream "superpowers:" namespace.
#   4. Scripts and hooks have LF line endings (CRLF breaks the shebang).
#   5. With BASE_REF: if the change touches shipped plugin content, the version
#      is greater than the version at BASE_REF.
#
set -euo pipefail

cd "$(dirname "$0")/.."

NAME="superpowers-custom"
fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

# 1. Versions in sync.
if ! bash scripts/bump-version.sh --check >/dev/null; then
  bash scripts/bump-version.sh --check >&2 || true
  err "manifest versions drift — run: bash scripts/bump-version.sh <new-version>"
fi
VERSION=$(jq -r .version .claude-plugin/plugin.json)

# 2. Fork identity in every manifest.
check_field() {
  local file="$1" path="$2" got
  got=$(jq -r "$path" "$file")
  [[ "$got" == "$NAME" ]] || err "$file $path is \"$got\", expected \"$NAME\""
}
check_field .claude-plugin/plugin.json      .name
check_field .claude-plugin/marketplace.json .name
check_field .claude-plugin/marketplace.json '.plugins[0].name'
check_field .codex-plugin/plugin.json       .name
check_field .cursor-plugin/plugin.json      .name
check_field .kimi-plugin/plugin.json        .name
check_field gemini-extension.json           .name

for f in .claude-plugin/plugin.json .claude-plugin/marketplace.json \
         .codex-plugin/plugin.json .cursor-plugin/plugin.json \
         .kimi-plugin/plugin.json gemini-extension.json; do
  if grep -q 'github.com/obra' "$f"; then
    err "$f still points at the upstream repo (github.com/obra)"
  fi
done

# 3. Namespace.
if refs=$(grep -rIoE 'superpowers:[a-z-]+' skills hooks); then
  echo "$refs" >&2
  err "upstream \"superpowers:\" references found — rewrite to \"$NAME:\""
fi

# 4. LF line endings for executable content.
while IFS= read -r f; do
  if grep -q $'\r' "$f"; then
    err "$f has CRLF line endings"
  fi
done < <(git ls-files 'hooks/*' 'skills/*/scripts/*' '*.sh')

# 5. Version bump when shipped content changes.
if [[ $# -ge 1 && -n "$1" ]]; then
  BASE="$1"
  SHIPPED='^(skills/|hooks/|assets/|\.claude-plugin/|\.codex-plugin/|\.cursor-plugin/|\.kimi-plugin/|gemini-extension\.json$|GEMINI\.md$)'
  changed=$(git diff --name-only "$BASE"...HEAD | grep -E "$SHIPPED" || true)
  if [[ -n "$changed" ]]; then
    BASE_VERSION=$(git show "$BASE:.claude-plugin/plugin.json" | jq -r .version)
    highest=$(printf '%s\n%s\n' "$BASE_VERSION" "$VERSION" | sort -V | tail -1)
    if [[ "$VERSION" == "$BASE_VERSION" || "$highest" != "$VERSION" ]]; then
      echo "Shipped files changed since $BASE:" >&2
      echo "$changed" | sed 's/^/  /' >&2
      err "version $VERSION is not greater than $BASE_VERSION at $BASE — run: bash scripts/bump-version.sh <new-version>"
    fi
  fi
fi

if [[ $fail -ne 0 ]]; then
  exit 1
fi
echo "Release checks passed (version $VERSION)."
