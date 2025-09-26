#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/log_search_export_user.sh"

tmpdir=$(mktemp -d)
apache_tmp_log="/var/log/apache2/db_search_test_other_vhost_access.log"

cleanup() {
  rm -rf "$tmpdir"
  rm -f "$apache_tmp_log"
}
trap cleanup EXIT

# Test 1: custom output file handles spaces in names
logfile="$tmpdir/access log with spaces.log"
output="$tmpdir/results.csv"
pattern="needle"

echo "${pattern} entry" > "$logfile"

bash "$script" -s "$pattern" -p "$tmpdir"'/'"*log" -o "$output"

grep -q "access log with spaces.log" "$output"

echo "Test passed: entries with spaces are captured."

# Test 2: default output filename prefers server type
mkdir -p "$(dirname "$apache_tmp_log")"
pattern2="apachepattern$$"
printf '%s from apache log\n' "$pattern2" > "$apache_tmp_log"

pushd "$tmpdir" >/dev/null
bash "$script" -s "$pattern2"
popd >/dev/null

mapfile -t default_outputs < <(find "$tmpdir" -maxdepth 1 -type f -name 'access_search_*.csv')
if [[ ${#default_outputs[@]} -ne 1 ]]; then
  echo "Expected exactly one default output file, found ${#default_outputs[@]}" >&2
  exit 1
fi
default_output="${default_outputs[0]}"

case "$default_output" in
  *apache*) ;;
  *)
    echo "Default output file does not include apache keyword: $default_output" >&2
    exit 1
    ;;
esac

grep -q "$pattern2" "$default_output"
rm -f "$default_output"

echo "Test passed: default CSV name reflects Apache logs."

# Test 3: binary logs stream matches instead of warnings
binary_log="$tmpdir/binary.log"
pattern3="binarypattern"
printf 'prefix\0%s suffix\n' "$pattern3" > "$binary_log"
binary_output="$tmpdir/binary.csv"

bash "$script" -s "$pattern3" -p "$binary_log" -o "$binary_output"

grep -q "$pattern3" "$binary_output"
if grep -q 'binary file matches' "$binary_output"; then
  echo "binary file matches warning detected in CSV output" >&2
  exit 1
fi

echo "Test passed: binary logs are exported correctly."

# Test 4: no matches yields no CSV output
no_match_log="$tmpdir/no_match.log"
absent_pattern="absentpattern$$"
printf 'this line does not match\n' > "$no_match_log"

mapfile -d '' -t before_csvs < <(find "$tmpdir" -maxdepth 1 -type f -name '*.csv' -print0 | sort -z)

summary=$(bash "$script" -s "$absent_pattern" -p "$no_match_log" 2>&1)

if [[ "$summary" != *"Done. No matches found."* ]]; then
  echo "Unexpected summary for no-match search: $summary" >&2
  exit 1
fi

mapfile -d '' -t after_csvs < <(find "$tmpdir" -maxdepth 1 -type f -name '*.csv' -print0 | sort -z)

if [[ ${#after_csvs[@]} -ne ${#before_csvs[@]} ]]; then
  echo "CSV files were created despite no matches being found" >&2
  printf 'Before:%s\n' "${before_csvs[*]}" >&2
  printf 'After:%s\n' "${after_csvs[*]}" >&2
  exit 1
fi

echo "Test passed: no matches produce no CSV output."
