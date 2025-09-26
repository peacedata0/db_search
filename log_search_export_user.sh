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
CUSTOM_PATH=0

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
    -p) shift; [[ $# -gt 0 ]] || usage; LOGPATHS=( "$1" ); CUSTOM_PATH=1; shift ;;
    -o) shift; [[ $# -gt 0 ]] || usage; OUTFILE="$1"; shift ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) echo "Unexpected arg: $1" >&2; usage ;;
  esac
done

[[ -z "$SEARCH" ]] && { echo "Error: -s <pattern> required"; usage; }

# default log paths
if [[ ${#LOGPATHS[@]} -eq 0 ]]; then
  LOGPATHS=( "/var/log/apache2/*access*.log*" "/var/log/nginx/*access*.log*" )
fi

TS=$(date +"%Y%m%d_%H%M%S")

declare -a RESOLVED_LOGS=()

shopt -s nullglob
for path in "${LOGPATHS[@]}"; do
  if [[ -d "$path" ]]; then
    while IFS= read -r -d '' file; do
      RESOLVED_LOGS+=( "$file" )
    done < <(find "$path" -maxdepth 1 -type f -name '*.log*' -print0 | sort -z)
  else
    # Preserve whitespace in expanded filenames by consuming a NUL-delimited stream
    # so custom glob patterns such as "/var/log/custom/* access.log" are handled safely.
    while IFS= read -r -d '' file; do
      [[ -f "$file" ]] || continue
      RESOLVED_LOGS+=( "$file" )
    done < <(
      { compgen -G "$path" 2>/dev/null || true; } | while IFS= read -r match; do
        [[ -z "$match" ]] && continue
        printf '%s\0' "$match"
      done
    )
  fi
done
shopt -u nullglob

if [[ -z "$OUTFILE" && $CUSTOM_PATH -eq 0 ]]; then
  keyword="logs"
  token=""
  for log in "${RESOLVED_LOGS[@]}"; do
    [[ -f "$log" ]] || continue
    base=$(basename "$log")
    stripped=$(printf '%s\n' "$base" | sed -E 's/\.log(\..*)?$//')
    OLDIFS=$IFS
    IFS='._-'
    read -ra parts <<< "$stripped"
    IFS=$OLDIFS
    for part in "${parts[@]}"; do
      [[ -z "$part" || "$part" == access ]] && continue
      token="$part"
      break 2
    done
  done
  if [[ -n "$token" ]]; then
    keyword="$token"
  else
    for p in "${LOGPATHS[@]}"; do
      case "$p" in
        *nginx*) keyword="nginx"; break ;;
        *apache*) keyword="apache"; break ;;
      esac
    done
  fi
  OUTFILE="access_search_${keyword}_${TS}.csv"
fi

declare -A WRITTEN_HEADERS=()

append_header_if_needed() {
  local outfile="$1"
  if [[ -z "${WRITTEN_HEADERS[$outfile]+x}" ]]; then
    echo "logfile,matched_record" > "$outfile"
    WRITTEN_HEADERS["$outfile"]=1
  fi
}

# function to append CSV rows safely
append_csv() {
  local outfile="$1"
  local logfile="$2"
  local record="$3"
  append_header_if_needed "$outfile"
  # escape double quotes
  logfile="${logfile//\"/\"\"}"
  record="${record//\"/\"\"}"
  printf "\"%s\",\"%s\"\n" "$logfile" "$record" >> "$outfile"
}

# scan logs
declare -A OUTPUTS_SEEN=()

if [[ -n "$OUTFILE" ]]; then
  append_header_if_needed "$OUTFILE"
  OUTPUTS_SEEN["$OUTFILE"]=1
fi

for file in "${RESOLVED_LOGS[@]}"; do
  [[ -e "$file" ]] || continue
  if [[ "$file" == *.gz ]]; then
    search_cmd=(zgrep -H -F -- "$SEARCH" "$file")
  else
    search_cmd=(grep -H -F -- "$SEARCH" "$file")
  fi

  if [[ -n "$OUTFILE" ]]; then
    current_outfile="$OUTFILE"
  elif [[ $CUSTOM_PATH -ne 0 ]]; then
    base=$(basename "$file")
    stripped=$(printf '%s\n' "$base" | sed -E 's/\.log(\..*)?$//')
    current_outfile="access_search_${stripped}_${TS}.csv"
  else
    current_outfile="access_search_${keyword}_${TS}.csv"
  fi

  OUTPUTS_SEEN["$current_outfile"]=1

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    logfile="${line%%:*}"
    record="${line#*:}"
    append_csv "$current_outfile" "$logfile" "$record"
  done < <(
    "${search_cmd[@]}" || true
  )
done

if [[ ${#OUTPUTS_SEEN[@]} -eq 0 ]]; then
  echo "Done. No matches found."
else
  if [[ ${#OUTPUTS_SEEN[@]} -eq 1 ]]; then
    for outfile in "${!OUTPUTS_SEEN[@]}"; do
      echo "Done. Results in $outfile"
    done
  else
    echo "Done. Results written to:"
    for outfile in "${!OUTPUTS_SEEN[@]}"; do
      echo "  $outfile"
    done
  fi
fi
