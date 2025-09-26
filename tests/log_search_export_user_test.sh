#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/log_search_export_user.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

logfile="$tmpdir/access log with spaces.log"
output="$tmpdir/results.csv"
pattern="needle"

echo "${pattern} entry" > "$logfile"

bash "$script" -s "$pattern" -p "$tmpdir"'/'"*log" -o "$output"

grep -q "access log with spaces.log" "$output"

echo "Test passed: entries with spaces are captured."
