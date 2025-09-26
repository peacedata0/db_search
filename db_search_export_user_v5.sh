#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# --------------------------------------------------------
# db_search_export_user_v7.sh
# Hardened DB-wide exact-search tool for MySQL/MariaDB
# Update: data readers use --batch with escape-aware decoding
# so TXT and CSV exports handle embedded newlines safely.
# --------------------------------------------------------

DB_USER="root"
DB_PASS=""
DB_HOST="localhost"
DB_PORT=3306

SEARCH=""
DB_NAME=""
FORMAT="csv"
VERBOSE=0

usage() {
  cat <<EOF
Usage: $0 -s <search_term> [-d <database>] [-f <csv|txt>] [-v] [-u <user>] [-H <host>] [-P <port>]
EOF
  exit 1
}

require_value() {
  local opt="$1"; shift
  if [[ $# -lt 1 || -z "$1" || "$1" == -* ]]; then
    echo "Error: option $opt requires a value." >&2
    usage
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) shift; require_value -s "$@"; SEARCH="$1"; shift ;;
    -d) shift; require_value -d "$@"; DB_NAME="$1"; shift ;;
    -f) shift; require_value -f "$@"; FORMAT="$1"; shift ;;
    -v) VERBOSE=1; shift ;;
    -u) shift; require_value -u "$@"; DB_USER="$1"; shift ;;
    -H) shift; require_value -H "$@"; DB_HOST="$1"; shift ;;
    -P) shift; require_value -P "$@"; DB_PORT="$1"; shift ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) echo "Unexpected arg: $1" >&2; usage ;;
  esac
done

if [[ -z "$SEARCH" ]]; then
  echo "Error: search term required (-s <term>)" >&2
  usage
fi
if [[ "$FORMAT" != "csv" && "$FORMAT" != "txt" ]]; then
  echo "Error: format must be csv or txt" >&2
  usage
fi
if [[ -z "$DB_PASS" ]]; then
  read -r -s -p "Enter password for MySQL user ${DB_USER}: " DB_PASS
  echo
fi

MYSQL_DEFAULTS_FILE=$(mktemp)
chmod 600 "$MYSQL_DEFAULTS_FILE"
{
  printf '[client]\n'
  printf 'user=%s\n' "$DB_USER"
  printf 'password=%s\n' "$DB_PASS"
} >"$MYSQL_DEFAULTS_FILE"

cleanup_defaults_file() {
  if [[ -n "${MYSQL_DEFAULTS_FILE:-}" && -f "$MYSQL_DEFAULTS_FILE" ]]; then
    rm -f "$MYSQL_DEFAULTS_FILE"
  fi
}
trap cleanup_defaults_file EXIT
unset DB_PASS
if ! command -v xxd >/dev/null 2>&1; then
  echo "Error: xxd is required (install vim-common)" >&2
  exit 1
fi

TS=$(date +"%Y%m%d_%H%M%S")
EXPORT_DIR="user_export"
mkdir -p "$EXPORT_DIR"
LOGFILE="${EXPORT_DIR}/search_${TS}.log"

echo "Search started: term='${SEARCH}', format='${FORMAT}', db='${DB_NAME:-ALL}'" | tee -a "$LOGFILE"

_mysql_data() {
  mysql --defaults-extra-file="$MYSQL_DEFAULTS_FILE" --batch --skip-column-names \
    -h "$DB_HOST" -P "$DB_PORT" \
    -e "$1" | tr -d '\r'
}

mysql_capture() {
  local context="$1"
  local query="$2"
  local result
  if ! result=$(_mysql_data "$query"); then
    echo "ERROR: MySQL query failed while ${context}. Aborting." | tee -a "$LOGFILE" >&2
    exit 1
  fi
  if [[ -n "$result" ]]; then
    printf '%s\n' "$result"
  fi
}
get_table_header_line() {
  local schema_hex="$1"
  local table_hex="$2"
  local query
  query="SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = UNHEX('${schema_hex}') AND TABLE_NAME = UNHEX('${table_hex}') ORDER BY ORDINAL_POSITION;"
  _mysql_data "$query" | paste -sd $'\t'
}

escape_ident() {
  local id="$1"
  id="$(printf "%s" "$id" | tr -d '\r\n')"
  id="${id//\`/\`\`}" 
  printf "%s" "\`$id\`"
}

sanitize_filename() {
  local raw="$1"
  local trimmed="$(printf "%s" "$raw" | tr -d '\r\n')"
  local cleaned="$(printf "%s" "$trimmed" | sed 's/[^A-Za-z0-9._-]/_/g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="unnamed"
  fi
  if [[ "$cleaned" != "$trimmed" ]]; then
    local hex_suffix
    hex_suffix=$(printf "%s" "$trimmed" | xxd -p | tr -d '\n' | head -c 8)
    cleaned+="_${hex_suffix}"
  fi
  printf "%s" "$cleaned"
}

csv_quote() {
  local s="$1"
  s="$(printf "%s" "$s" | tr -d '\r')"
  s="${s//\"/\"\"}"
  printf "\"%s\"" "$s"
}

join_csv_fields() {
  local line="$1"
  local IFS=$'\t'
  read -r -a fields <<< "$line" || fields=()
  local out=""
  local field
  for field in "${fields[@]}"; do
    local quoted
    quoted=$(csv_quote "$field")
    if [[ -z "$out" ]]; then
      out="$quoted"
    else
      out+=",$quoted"
    fi
  done
  printf "%s" "$out"
}

# get DB list
declare -a DBS_HEX
if [[ -n "$DB_NAME" ]]; then
  DBS_HEX=( "$(printf "%s" "$DB_NAME" | xxd -p | tr -d '\n')" )
else
  Q="SELECT HEX(SCHEMA_NAME) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','performance_schema','mysql','sys');"
  mapfile -t DBS_HEX < <(mysql_capture "listing databases" "$Q")
fi
[[ ${#DBS_HEX[@]} -eq 0 ]] && { echo "No DBs." | tee -a "$LOGFILE"; exit 0; }

# escaped search string
B64_SEARCH=$(printf "%s" "$SEARCH" | base64 | tr -d '\n')
RAW_QUOTED=$(_mysql_data "SELECT QUOTE(FROM_BASE64('${B64_SEARCH}'));")
[[ -z "$RAW_QUOTED" ]] && { echo "Escape failed." >&2; exit 1; }
ESCAPED_SEARCH=$(printf "%s" "$RAW_QUOTED" | sed -e "s/^'//" -e "s/'$//")

for HEX_DB in "${DBS_HEX[@]}"; do
  DB=$(printf "%s" "$HEX_DB" | xxd -r -p)
  safe_db=$(sanitize_filename "$DB")
  echo ">>> Scanning DB: [$DB]" | tee -a "$LOGFILE"

  COLS_Q="SELECT TABLE_NAME, COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE SCHEMA_NAME = UNHEX('${HEX_DB}');"
  mapfile -t col_lines < <(mysql_capture "listing columns for ${DB}" "$COLS_Q")

  for line in "${col_lines[@]}"; do
    IFS=$'\t' read -r TABLE COL <<< "$line"
    [[ -z "$TABLE" || -z "$COL" ]] && continue

    esc_db=$(escape_ident "$DB")
    esc_table=$(escape_ident "$TABLE")
    esc_col=$(escape_ident "$COL")

    if ! COUNT=$(_mysql_data "SELECT COUNT(*) FROM ${esc_db}.${esc_table} WHERE ${esc_col} = '${ESCAPED_SEARCH}';"); then
      echo "ERROR: Failed to count matches for ${DB}.${TABLE}.${COL}. Aborting." | tee -a "$LOGFILE" >&2
      exit 1
    fi
    COUNT=${COUNT:-0}
    [[ ! "$COUNT" =~ ^[0-9]+$ ]] && COUNT=0

    if [[ "$COUNT" -gt 0 ]]; then
      echo "  Found in ${DB}.${TABLE}.${COL} -> ${COUNT} rows" | tee -a "$LOGFILE"

      table_hex=$(printf "%s" "$TABLE" | xxd -p | tr -d '\n')
      header_line=$(get_table_header_line "$HEX_DB" "$table_hex")
      if [[ -z "$header_line" ]]; then
        header_line=$(_mysql_data "DESCRIBE ${esc_db}.${esc_table};" | awk '{print $1}' | paste -sd $'\t')
      fi

      if [[ "$FORMAT" == "txt" ]]; then
        OUT="${EXPORT_DIR}/search_${safe_db}_${TS}.txt"
        { echo "# DB: ${DB}"; echo "# Table: ${TABLE}"; echo "# Column: ${COL}"; } >> "$OUT"
        _mysql_data "SELECT t.* FROM ${esc_db}.${esc_table} t WHERE ${esc_col} = '${ESCAPED_SEARCH}';" \
          | python3 -c 'import sys, codecs
headers_arg = sys.argv[1] if len(sys.argv) > 1 else ""
headers = headers_arg.split("\t") if headers_arg else []

def decode(value: str) -> str:
    if value in ("NULL", r"\N"):
        return value
    try:
        return codecs.decode(value.encode("utf-8"), "unicode_escape")
    except Exception:
        return value

for raw_line in sys.stdin:
    if not raw_line:
        continue
    fields = raw_line.rstrip("\n").split("\t")
    sys.stdout.write("---\n")
    for idx, name in enumerate(headers):
        val = fields[idx] if idx < len(fields) else ""
        if val in ("NULL", r"\N"):
            sys.stdout.write(f"{name}=NULL\n")
        else:
            sys.stdout.write(f"{name}={decode(val)}\n")
' "$header_line" >> "$OUT"

      else
        safe_table=$(sanitize_filename "$TABLE")
        OUT="${EXPORT_DIR}/search_${safe_db}_${safe_table}_${TS}.csv"
        if [[ ! -f "$OUT" ]]; then
          HEADER_SOURCE="$header_line"
          if [[ -z "$HEADER_SOURCE" ]]; then
            HEADER_SOURCE=$(_mysql_data "DESCRIBE ${esc_db}.${esc_table};" | awk '{print $1}' | paste -sd $'\t')
          fi
          HEADER_COMMA=$(join_csv_fields "$HEADER_SOURCE")
          echo "db_name,table_name,column_name,${HEADER_COMMA}" > "$OUT"
        fi
        _mysql_data "SELECT t.* FROM ${esc_db}.${esc_table} t WHERE ${esc_col} = '${ESCAPED_SEARCH}';" \
          | python3 -c 'import sys, csv, codecs

db_name, table_name, column_name, header_arg = sys.argv[1:5]
headers = header_arg.split("\t") if header_arg else []
writer = csv.writer(sys.stdout, lineterminator="\n")
prefix = [db_name, table_name, column_name]

def decode(value: str) -> str:
    if value in ("NULL", r"\N"):
        return value
    try:
        return codecs.decode(value.encode("utf-8"), "unicode_escape")
    except Exception:
        return value

for raw_line in sys.stdin:
    if not raw_line:
        continue
    fields = raw_line.rstrip("\n").split("\t")
    row = prefix.copy()
    for idx, name in enumerate(headers):
        val = fields[idx] if idx < len(fields) else ""
        if val in ("NULL", r"\N"):
            row.append("NULL")
        else:
            row.append(decode(val))
    writer.writerow(row)
' "$DB" "$TABLE" "$COL" "$header_line" >> "$OUT"
      fi
    fi
  done
done

echo "Done. Results in ${EXPORT_DIR}, log: ${LOGFILE}" | tee -a "$LOGFILE"
