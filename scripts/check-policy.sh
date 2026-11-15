#!/bin/bash
# Project policy checks. Run in CI and before every commit. No dependencies.
#   1. Tool code makes no network calls and never uses eval or
#      Invoke-Expression.
#   2. Every recursive rm in tool code is guarded with "${var:?}".
#   3. No personal home paths are committed.
# Run from anywhere: bash scripts/check-policy.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
tool_files=(mac/ghdp windows/ghdp.ps1 install-mac.command uninstall-mac.command)

# 1. Banned commands (comment lines are ignored): network tools, other
#    script runtimes, raw sockets, eval.
banned='(\b(curl|wget|nc|ncat|telnet|ssh|scp|sftp|nscurl|python[0-9.]*|perl|ruby|php|node|Invoke-WebRequest|Invoke-RestMethod|iwr|irm|WebClient|DownloadString|DownloadFile|Start-BitsTransfer|eval|Invoke-Expression|iex)\b|/dev/(tcp|udp)/)'
hits="$(grep -n -E -i "$banned" "${tool_files[@]}" | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [ -n "$hits" ]; then
  printf '%s\n' "$hits"
  echo "Policy: a network or eval command was found in tool code (above)."
  fail=1
fi

# 2. Unguarded recursive rm (any spelling: -rf, -fr, -Rf, -r -f, ...).
hits="$(grep -n -E '\brm[[:space:]]+-[A-Za-z]*[rR]' "${tool_files[@]}" | grep -v -E '"\$\{[A-Za-z_]+:\?\}' || true)"
if [ -n "$hits" ]; then
  printf '%s\n' "$hits"
  # shellcheck disable=SC2016 # the ${var:?} text is meant literally
  echo 'Policy: every rm -rf must use "${var:?}" (above).'
  fail=1
fi

# 3. Personal home paths (placeholders like /Users/you are fine).
hits="$(git ls-files -z | xargs -0 grep -n -I -E '/Users/[a-z][a-z0-9._-]+/|[A-Z]:\\Users\\[A-Za-z]' 2>/dev/null |
  grep -v -E '/Users/you/|scripts/check-policy\.sh' || true)"
if [ -n "$hits" ]; then
  printf '%s\n' "$hits"
  echo "Policy: a personal home path was found (above)."
  fail=1
fi

if [ "$fail" -eq 0 ]; then echo "Policy checks passed."; fi
exit "$fail"
