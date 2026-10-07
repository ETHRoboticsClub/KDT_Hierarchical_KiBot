#!/usr/bin/env bash
# Sheet ownership guard for KiCad feature branches.
#
# A branch feature/<name> may only change the KiCad source files that
# .github/sheet-ownership.conf assigns to <name>. Non-KiCad files (docs,
# CHANGELOG, footprints in *.pretty/, 3D models ...) are always allowed.
#
# Environment:
#   FEATURE_BRANCH  e.g. feature/power-gen            (required)
#   BASE_REF        branch to compare against          (default origin/dev)
#   HEAD_REF        commit to check                     (default HEAD)
#   GUARD_MODE      fail | warn                         (default fail)
#   OWNERSHIP_FILE  mapping file   (default .github/sheet-ownership.conf)
#
# Run locally from the repo root:
#   FEATURE_BRANCH=$(git branch --show-current) bash .github/scripts/check_sheet_ownership.sh

set -euo pipefail

FEATURE_BRANCH="${FEATURE_BRANCH:?FEATURE_BRANCH is required, e.g. feature/power-gen}"
BASE_REF="${BASE_REF:-origin/dev}"
HEAD_REF="${HEAD_REF:-HEAD}"
GUARD_MODE="${GUARD_MODE:-fail}"
OWNERSHIP_FILE="${OWNERSHIP_FILE:-.github/sheet-ownership.conf}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
ON_CI="${GITHUB_ACTIONS:-false}"

# Files that hold shared design state. Everything else is unrestricted.
PROTECTED=('*.kicad_sch' '*.kicad_pcb' '*.kicad_pro' '*.kicad_dru' '*.kicad_sym' 'sym-lib-table' 'fp-lib-table')

feature="${FEATURE_BRANCH#feature/}"

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

is_protected() {
  local f="$1" base p
  base="${f##*/}"
  for p in "${PROTECTED[@]}"; do
    # shellcheck disable=SC2053  # intentional glob match
    [[ $base == $p ]] && return 0
  done
  return 1
}

# --- read the mapping ---------------------------------------------------------
if [[ ! -f "$OWNERSHIP_FILE" ]]; then
  echo "::error::$OWNERSHIP_FILE not found"
  exit 1
fi

allowed=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  [[ "$line" == *=* ]] || continue
  name="$(trim "${line%%=*}")"
  pattern="$(trim "${line#*=}")"
  [[ -n "$name" && -n "$pattern" ]] || continue
  [[ "$name" == "$feature" ]] && allowed+=("$pattern")
done < "$OWNERSHIP_FILE"

if ((${#allowed[@]} == 0)); then
  msg="Branch '$FEATURE_BRANCH' has no entry in $OWNERSHIP_FILE. Add a line '$feature = <sheet file>' (via dev) before working on this branch."
  echo "::error::$msg"
  { echo "### Sheet ownership guard"; echo; echo "❌ $msg"; } >> "$SUMMARY"
  exit 1
fi

# --- compare against the merge base ------------------------------------------
if ! git rev-parse --verify -q "$BASE_REF" >/dev/null; then
  echo "::error::Base ref '$BASE_REF' not found (did checkout use fetch-depth: 0?)"
  exit 1
fi

merge_base="$(git merge-base "$BASE_REF" "$HEAD_REF")"

violations=()
owned=()
while IFS= read -r -d '' f; do
  is_protected "$f" || continue
  ok=false
  for p in "${allowed[@]}"; do
    # shellcheck disable=SC2053
    [[ $f == $p ]] && ok=true && break
  done
  if $ok; then owned+=("$f"); else violations+=("$f"); fi
done < <(git diff --name-only --no-renames -z "$merge_base" "$HEAD_REF")

# --- report -------------------------------------------------------------------
{
  echo "### Sheet ownership guard: \`$FEATURE_BRANCH\`"
  echo
  # shellcheck disable=SC2016  # backticks are markdown, not expansion
  echo "Owned patterns: $(printf '`%s` ' "${allowed[@]}")"
  echo
  for f in "${owned[@]}";      do echo "- ✅ \`$f\`"; done
  for f in "${violations[@]}"; do echo "- ❌ \`$f\` (not owned by this branch)"; done
  ((${#owned[@]} + ${#violations[@]})) || echo "_No KiCad source files changed._"
} >> "$SUMMARY"

echo "Branch:  $FEATURE_BRANCH  (feature '$feature')"
echo "Compare: $(git rev-parse --short "$merge_base")..$(git rev-parse --short "$HEAD_REF")  (merge base with $BASE_REF)"
echo "Owned:   ${allowed[*]}"
for f in "${owned[@]}"; do echo "  ok        $f"; done

if ((${#violations[@]} == 0)); then
  echo "Result: OK"
  exit 0
fi

level=error; [[ "$GUARD_MODE" == "warn" ]] && level=warning
for f in "${violations[@]}"; do
  echo "  NOT OWNED $f"
  [[ "$ON_CI" == "true" ]] && echo "::$level file=$f,title=Sheet ownership::$f is not owned by $FEATURE_BRANCH. Revert it, or ask the integrator to make this change on dev."
done
echo "Result: ${#violations[@]} file(s) outside this branch's ownership"
[[ "$GUARD_MODE" == "warn" ]] && exit 0
exit 1
