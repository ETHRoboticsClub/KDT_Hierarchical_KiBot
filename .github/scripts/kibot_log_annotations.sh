#!/usr/bin/env bash
# Surface KiBot errors as GitHub annotations after a failed step.
#
# KiBot writes its full output to the --log files (kibot_*.log). Those end up
# in artifacts, which nobody opens when a check is red. This prints the
# relevant lines as one annotation per log file, so the reason shows up
# directly on the run page and on the PR's checks tab.
#
# Only logs that contain errors are annotated. If none does (KiBot died
# without logging an ERROR), the last non-DEBUG lines of each log are shown.
#
# Usage: bash .github/scripts/kibot_log_annotations.sh [log files...]
#        (default: every kibot_*.log in the current directory)
# Env:   KIBOT_ANNOTATION_LEVEL  error | warning   (default error)
#        KIBOT_ANNOTATION_LINES  max lines per log (default 40)

set -uo pipefail
shopt -s nullglob

files=("$@")
((${#files[@]})) || files=(kibot_*.log)

lines="${KIBOT_ANNOTATION_LINES:-40}"
level="${KIBOT_ANNOTATION_LEVEL:-error}"
pattern='ERROR|Traceback|Exception|[Ee]rror:'

annotate() { # file message
  local msg="$2"
  # Workflow-command escaping: % first, then CR/LF.
  msg="${msg//'%'/'%25'}"
  msg="${msg//$'\r'/}"
  msg="${msg//$'\n'/'%0A'}"
  echo "::${level} title=KiBot: $1::${msg}"
}

existing=()
for f in "${files[@]}"; do [[ -s "$f" ]] && existing+=("$f"); done
if ((${#existing[@]} == 0)); then
  echo "::warning title=KiBot::No KiBot log files found (KiBot probably failed before it started; see the step output)."
  exit 0
fi

annotated=false
for f in "${existing[@]}"; do
  msg="$(grep -v '^DEBUG:' "$f" | grep -E -A3 "$pattern" | grep -v '^--$' | tail -n "$lines")"
  [[ -n "$msg" ]] || continue
  annotate "$f" "$msg"
  annotated=true
done

if ! $annotated; then
  for f in "${existing[@]}"; do
    annotate "$f" "$(grep -v '^DEBUG:' "$f" | tail -n "$lines")"
  done
fi
exit 0
