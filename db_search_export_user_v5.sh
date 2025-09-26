#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# --------------------------------------------------------
# db_search_export_user_v6.sh
# Safe DB-wide exact-search tool for MySQL/MariaDB
# Fixes:
#  - DB names encoded with HEX() instead of TO_BASE64 (no newlines)
#  - safe decoding via xxd -r -p (checked)
#  - safe escaping of identifiers (backticks doubled)
#  - search string escaped via QUOTE(FROM_BASE64())
#  - CSV header uses mysql without --skip-column-names
#  - context fields in CSV quoted with csv_quote()
#  - CR stripped from mysql output
# --------------------------------------------------------

# default config
DB_USER="root"
DB_PASS=""
DB_HOST="localhost"
DB_PORT=3306

# defaults
SEARCH=""
DB_NAME=""
FORMAT="csv"
VERBOSE=0

usage() {
  cat <<EOF
Usage: $0 -s <search_term> [-d <database>] [-f <csv|txt>] [-v] [-u <user>] [-H <host>] [-P <port>]
  -s <search_term>   required (exact match)
  -d <database>      optional: specific database
  -f <csv|txt>       output format (default csv)
  -v                 verbose
  -u <user>          DB user (default root)
  -H <host>          DB host (default localhost)
  -P <port>          DB port (default 3306)
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

# parse args
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
  read -s -p "Enter password for MySQL user ${DB_USER}: " DB_PASS
  echo
fi

# check xxd
if ! command -v xxd >/dev/null 2>&1; then
  echo "Error: xxd is required for HEX decoding (install vim-common or equivalent)" >&2
  exit 1
fi

# prepare dirs
TS=$(date +"%Y%m%d_%H%M%S")
EXPORT_DIR="user_export"
mkdir -p "$EXPORT_DIR"
LOGFILE="${EXPORT_DIR}/search_${TS}.log"

echo "Search started: term='${SEARCH}', format='${FORMAT}', db='${DB_NAME:-ALL}', user='${DB_USER}', host='${DB_HOST}:${DB_PORT}'" | tee -a "$LOGFILE"

# helpers
_mysql_data() {
  mysql --batch --skip-column-names -u"$DB_USER" -p"$DB_PASS" -h "$DB_HOST" -P "$DB_PORT" -e "$1" 2>/dev/null | tr -d '\r'
}
_mysql_raw() {
  mysql -u"$DB_USER" -p"$DB_PASS" -h "$DB_HOST" -P "$DB_PORT" -e "$1" 2>/dev/null | tr -d '\r'
}

escape_ident() {
  local id="$1"
  id="$(printf "%s" "$id" | tr -d '\r\n')"
  id="${id//\`/\`\`}"
  printf "`%s`" "$id"
}

csv_quote() {
  local s="$1"
  s="$(printf "%s" "$s" | tr -d '\r')"
  s="${s//\"/\"\"}"
  printf "\"%s\"" "$s"
}

# get DB list
declare -a DBS_HEX
if [[ -n "$DB_NAME" ]]; then
  DBS_HEX=( "$(printf "%s" "$DB_NAME" | xxd -p | tr -d '\n')" )
else
  Q="SELECT HEX(SCHEMA_NAME) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','performance_schema','mysql','sys');"
  [[ $VERBOSE -eq 1 ]] && echo "[SQL] $Q" | tee -a "$LOGFILE"
  mapfile -t DBS_HEX < <(_mysql_data "$Q" || true)
fi
if [[ ${#DBS_HEX[@]} -eq 0 ]]; then
  echo "No databases to scan." | tee -a "$LOGFILE"
  exit 0
fi

# escaped search string
B64_SEARCH=$(printf "%s" "$SEARCH" | base64 | tr -d '\n')
QUOTE_SQL="SELECT QUOTE(FROM_BASE64('${B64_SEARCH}'));"
[[ $VERBOSE -eq 1 ]] && echo "[SQL] $QUOTE_SQL" | tee -a "$LOGFILE"
RAW_QUOTED=$(_mysql_data "$QUOTE_SQL" || true)
if [[ -z "$RAW_QUOTED" ]]; then
  echo "Error: failed to compute escaped search term" >&2
  exit 1
fi
ESCAPED_SEARCH=$(printf "%s" "$RAW_QUOTED" | sed -e "s/^'//" -e "s/'$//")

# main loop
for HEX_DB in "${DBS_HEX[@]}"; do
  DB=$(printf "%s" "$HEX_DB" | xxd -r -p)
  echo ">>> Scanning database: [$DB]" | tee -a "$LOGFILE"

  COLS_Q="SELECT TABLE_NAME, COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE SCHEMA_NAME = UNHEX('${HEX_DB}');"
  [[ $VERBOSE -eq 1 ]] && echo "[SQL] $COLS_Q" | tee -a "$LOGFILE"
  mapfile -t col_lines < <(_mysql_data "$COLS_Q" || true)

  for line in "${col_lines[@]}"; do
    IFS=$'\t' read -r TABLE COL <<< "$line"
    [[ -z "$TABLE" || -z "$COL" ]] && continue

    esc_db=$(escape_ident "$DB")
    esc_table=$(escape_ident "$TABLE")
    esc_col=$(escape_ident "$COL")

    SQL_COUNT="SELECT COUNT(*) FROM ${esc_db}.${esc_table} WHERE ${esc_col} = '${ESCAPED_SEARCH}';"
    [[ $VERBOSE -eq 1 ]] && echo "[SQL] $SQL_COUNT" | tee -a "$LOGFILE"
    COUNT=$(_mysql_data "$SQL_COUNT" || echo "0")
    COUNT=${COUNT:-0}
    if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then COUNT=0; fi

    if [[ "$COUNT" -gt 0 ]]; then
      echo "  Found in ${DB}.${TABLE}.${COL} -> ${COUNT} rows" | tee -a "$LOGFILE"

      if [[ "$FORMAT" == "txt" ]]; then
        OUT_FILE="${EXPORT_DIR}/search_${DB}_${TS}.txt"
        { echo "# Database: ${DB}"; echo "# Table: ${TABLE}"; echo "# Column: ${COL}"; } >> "$OUT_FILE"

        SQL_SELECT="SELECT * FROM ${esc_db}.${esc_table} WHERE ${esc_col} = '${ESCAPED_SEARCH}';"
        [[ $VERBOSE -eq 1 ]] && echo "[SQL] $SQL_SELECT" | tee -a "$LOGFILE"
        _mysql_raw "$SQL_SELECT" | awk 'NR==1{for(i=1;i<=NF;i++)h[i]=$i; next}{print "---"; for(i=1;i<=NF;i++)print h[i]"="$i}' >> "$OUT_FILE"
        echo "    -> appended to ${OUT_FILE}" | tee -a "$LOGFILE"

      else
        OUT_FILE="${EXPORT_DIR}/search_${DB}_${TS}.csv"
        if [[ ! -f "$OUT_FILE" ]]; then
          HEADER_LINE=$(_mysql_raw "SELECT * FROM ${esc_db}.${esc_table} LIMIT 1;" | head -n1 || true)
          if [[ -z "$HEADER_LINE" ]]; then
            echo "db_name,table_name,column_name,row_data" > "$OUT_FILE"
          else
            HEADER_COMMA=$(printf "%s" "$HEADER_LINE" | sed 's/\t/,/g')
            echo "db_name,table_name,column_name,${HEADER_COMMA}" > "$OUT_FILE"
          fi
        fi

        SQL_SELECT_CSV="SELECT t.* FROM ${esc_db}.${esc_table} t WHERE ${esc_col} = '${ESCAPED_SEARCH}';"
        [[ $VERBOSE -eq 1 ]] && echo "[SQL] $SQL_SELECT_CSV" | tee -a "$LOGFILE"
        _mysql_data "$SQL_SELECT_CSV" | while IFS= read -r rowline || [[ -n "$rowline" ]]; do
          row_csv=$(printf "%s" "$rowline" | sed 's/\t/,/g')
          pref=$(csv_quote "$DB"),$(csv_quote "$TABLE"),$(csv_quote "$COL")
          echo "$pref,$row_csv" >> "$OUT_FILE"
        done
        echo "    -> appended to ${OUT_FILE}" | tee -a "$LOGFILE"
      fi
    fi
  done
done

echo "Done. Results: ${EXPORT_DIR} (log: ${LOGFILE})" | tee -a "$LOGFILE"
