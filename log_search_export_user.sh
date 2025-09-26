#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# --------------------------------------------------------
# access_log_search.sh
# Search Apache/Nginx access logs for a given pattern
# Supports rotated logs (*.log.1, *.log.gz)
# Output: CSV with columns logfile,matched_record
# --------------------------------------------------------

SEARCH=""
LOGPATHS=()
OUTFILE=""

usage() {
  cat <<EOF
Usage: $0 -s <pattern> [-p <path>] [-o <outfile>]

  -s <pattern>   string to search (email, serial, etc.)
  -p <path>      custom log path (optional)
                 default: /var/log/apache2/*access*.log* and /var/log/nginx/*access*.log*
  -o <file>      output CSV file (optional)
                 default: access_search_<keyword>_<timestamp>.csv
EOF
  exit 1
}

# arg parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) shift; [[ $# -gt 0 ]] || usage; SEARCH="$1"; shift ;;
    -p) shift; [[ $# -gt 0 ]] || usage; LOGPATHS=( "$1" ); shift ;;
    -o) shift; [[ $# -gt 0 ]] || usage; OUTFILE="$1"; shift ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) echo "Unexpected arg: $1" >&2; usage ;;
  esac
done

[[ -z "$SEARCH" ]] && { echo "Error: -s <pattern> required"; usage; }

# default log paths
if [[ ${#LOGPATHS[@]} -eq 0 ]]; then
  LOGPATHS=( /var/log/apache2/*access*.log* /var/log/nginx/*access*.log* )
fi

# default outfile
if [[ -z "$OUTFILE" ]]; then
  keyword="logs"
  for p in "${LOGPATHS[@]}"; do
    case "$p" in
      *nginx*) keyword="nginx"; break ;;
      *apache*) keyword="apache"; break ;;
    esac
  done
  TS=$(date +"%Y%m%d_%H%M%S")
  OUTFILE="access_search_${keyword}_${TS}.csv"
fi

# write header
echo "logfile,matched_record" > "$OUTFILE"

# function to append CSV rows safely
append_csv() {
  local logfile="$1"
  local record="$2"
  # escape double quotes
  logfile="${logfile//\"/\"\"}"
  record="${record//\"/\"\"}"
  printf "\"%s\",\"%s\"\n" "$logfile" "$record" >> "$OUTFILE"
}

# scan logs
for path in "${LOGPATHS[@]}"; do
  for file in $path; do
    [[ -e "$file" ]] || continue
    if [[ "$file" == *.gz ]]; then
      search_cmd=(zgrep -H -F -- "$SEARCH" "$file")
    else
      search_cmd=(grep -H -F -- "$SEARCH" "$file")
    fi

    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      logfile="${line%%:*}"
      record="${line#*:}"
      append_csv "$logfile" "$record"
    done < <(
      "${search_cmd[@]}" || true
    )
  done
done

echo "Done. Results in $OUTFILE"
