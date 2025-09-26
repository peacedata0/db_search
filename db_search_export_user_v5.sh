#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# --------------------------------------------------------
# db_search.sh — hardened fixes
# - safe handling of DB names (base64 transport and decoding)
# - safe escaping of SQL identifiers (backtick doubling)
# - header retrieval without --skip-column-names
# - DB list kept as array (spaces preserved)
# - strip CR (\r) from mysql output
# - CSV context columns are quoted for CSV safety
# NOTE: For absolute RFC4180 correctness (fields with newlines/commas/quotes)
# a Python CSV writer is preferable; this script hardens injection points.
# --------------------------------------------------------

# default config
DB_USER="root"
DB_PASS=""              # prompt if empty
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
  -d <database>      optional: specific database; if omitted -> scan all user DBs
  -f <csv|txt>       output format (default: csv)
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

# basic checks
if [[ -z "$SEARCH" ]]; then
  echo "Error: search term required (-s <term>)" >&2
  usage
fi
if [[ "$FORMAT" != "csv" && "$FORMAT" != "txt" ]]; then
  echo "Error: format must be csv or txt" >&2
  usage
fi

# password prompt if empty
if [[ -z "$DB_PASS" ]]; then
  read -s -p "Enter password for MySQL user ${DB_USER}: " DB_PASS
  echo
fi

# prepare dirs / log
TS=$(date +"%Y%m%d_%H%M%S")
EXPORT_DIR="user_export"
mkdir -p "$EXPORT_DIR"
LOGFILE="${EXPORT_DIR}/search_${TS}.log"
echo "Search started: term='${SEARCH}', format='${FORMAT}', db='${DB_NAME:-ALL}', user='${DB_USER}', host='${DB_HOST}:${DB_PORT}'" | tee -a "$LOGFILE"

# helpers
_mysql_data() {
  # returns tab-separated rows WITHOUT header, strips CR
  mysql --batch --skip-column-names -u"$DB_USER" -p"$DB_PASS" -h "$DB_HOST" -P "$DB_PORT" -e "$1" 2>/dev/null | tr -d '\r'
}
_mysql_raw() {
  # returns rows INCLUDING header, strips CR
  mysql -u"$DB_USER" -p"$DB_PASS" -h "$DB_HOST" -P "$DB_PORT" -e "$1" 2>/dev/null | tr -d '\r'
}

# safe identifier escaping for MySQL: double any backticks and wrap in backticks
# usage: escape_ident "name" -> prints backticked identifier
escape_ident() {
  local id="$1"
  # remove CR/LF from identifier to avoid breaking SQL
  id="$(printf "%s" "$id" | tr -d '\r\n')"
  # double any backticks
  id="${id//\`/\`\`}"
  printf "`%s`" "$id"
}

# safe CSV quoting for context columns: wrap in double quotes, double internal quotes
csv_quote() {
  local s="$1"
  # remove CRs but keep \n inside field (we'll not try to handle multiline CSV perfectly)
  s="$(printf "%s" "$s" | tr -d '\r')"
  # double quotes
  s="${s//\"/\"\"}"
  printf "\"%s\"" "$s"
}

# 1) get DB list as base64 array to preserve arbitrary names
declare -a DBS_B64
if [[ -n "$DB_NAME" ]]; then
  # direct user input: encode in base64 (no newline)
  DBS_B64=( "$(printf "%s" "$DB_NAME" | base64 | tr -d '\n')" )
else
  Q="SELECT TO_BASE64(SCHEMA_NAME) FROM INFORMATION_SCHEMA.SCHEMATA WHERE NOT (SCHEMA_NAME IN ('information_schema','performance_schema','mysql','sys'));"
  [[ $VERBOSE -eq 1 ]] && echo "[SQL] $Q" | tee -a "$LOGFILE"
  # read lines into array (each is base64 string)
  mapfile -t DBS_B64 < <(_mysql_data "$Q" || true)
fi

if [[ ${#DBS_B64[@]} -eq 0 ]]; then
  echo "No databases to scan." | tee -a "$LOGFILE"
  exit 0
fi

# 2) compute server-side escaped search literal via QUOTE(FROM_BASE64(...))
B64_SEARCH=$(printf "%s" "$SEARCH" | base64 | tr -d '\n')
QUOTE_SQL="SELECT QUOTE(FROM_BASE64('${B64_SEARCH}'));"
[[ $VERBOSE -eq 1 ]] && echo "[SQL] ${QUOTE_SQL}" | tee -a "$LOGFILE"
RAW_QUOTED=$(_mysql_data "$QUOTE_SQL" || true)
if [[ -z "$RAW_QUOTED" ]]; then
  echo "Error: failed to compute escaped search term via QUOTE()." | tee -a "$LOGFILE" >&2
  exit 1
fi
# RAW_QUOTED like: 'escaped_text' -> strip outer quotes
ESCAPED_SEARCH=$(printf "%s" "$RAW_QUOTED" | sed -e "s/^'//" -e "s/'$//")

# iterate DBs (decoded safely)
for B64_DB in "${DBS_B64[@]}"; do
  DB="$(printf "%s" "$B64_DB" | base64 --decode)"
  echo ">>> Scanning database: [$DB]" | tee -a "$LOGFILE"

  # get table/column list using FROM_BASE64 to avoid injecting raw DB name
  COLS_Q="SELECT TABLE_NAME, COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = FROM_BASE64('${B64_DB}');"
  [[ $VERBOSE -eq 1 ]] && echo "[SQL] ${COLS_Q}" | tee -a "$LOGFILE"
  mapfile -t col_lines < <(_mysql_data "$COLS_Q" || true)

  for line in "${col_lines[@]}"; do
    # split tab -> table, col
    IFS=$'\t' read -r TABLE COL <<< "$line"
    [[ -z "$TABLE" || -z "$COL" ]] && continue

    # safe identifiers (escape backticks)
    esc_db_ident=$(escape_ident "$DB")
    esc_table_ident=$(escape_ident "$TABLE")
    esc_col_ident=$(escape_ident "$COL")

    # COUNT query: identifiers inserted as escaped identifiers, search as escaped literal
    SQL_COUNT="SELECT COUNT(*) FROM ${esc_db_ident}.${esc_table_ident} WHERE ${esc_col_ident} = '${ESCAPED_SEARCH}';"
    [[ $VERBOSE -eq 1 ]] && echo "[SQL] ${SQL_COUNT}" | tee -a "$LOGFILE"
    COUNT=$(_mysql_data "$SQL_COUNT" || echo "0")
    COUNT=${COUNT:-0}
    if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then COUNT=0; fi

    if [[ "$COUNT" -gt 0 ]]; then
      echo "  Found in ${DB}.${TABLE}.${COL} -> ${COUNT} rows" | tee -a "$LOGFILE"

      if [[ "$FORMAT" == "txt" ]]; then
        OUT_FILE="${EXPORT_DIR}/search_${DB}_${TS}.txt"
        {
          printf "%s\n" "# Database: ${DB}"
          printf "%s\n" "# Table: ${TABLE}"
          printf "%s\n" "# Column: ${COL}"
        } >> "$OUT_FILE"

        SQL_SELECT="SELECT * FROM ${esc_db_ident}.${esc_table_ident} WHERE ${esc_col_ident} = '${ESCAPED_SEARCH}';"
        [[ $VERBOSE -eq 1 ]] && echo "[SQL] ${SQL_SELECT}" | tee -a "$LOGFILE"
        # raw output includes header
        _mysql_raw "$SQL_SELECT" | awk -v RS='\n' -v ORS='\n' -v OFS='\n' '
          NR==1{ for(i=1;i<=NF;i++)h[i]=$i; next }
          { print "---"; for(i=1;i<=NF;i++) print h[i]"="$i }' >> "$OUT_FILE"
        echo "    -> appended to ${OUT_FILE}" | tee -a "$LOGFILE"

      else
        OUT_FILE="${EXPORT_DIR}/search_${DB}_${TS}.csv"
        # header extraction using raw call (with header), safe
        if [[ ! -f "$OUT_FILE" ]]; then
          HEADER_LINE=$(_mysql_raw "SELECT * FROM ${esc_db_ident}.${esc_table_ident} LIMIT 1;" | head -n1 || true)
          if [[ -z "$HEADER_LINE" ]]; then
            echo "db_name,table_name,column_name,row_data" > "$OUT_FILE"
          else
            HEADER_COMMA=$(printf "%s" "$HEADER_LINE" | sed 's/\t/,/g')
            echo "db_name,table_name,column_name,${HEADER_COMMA}" > "$OUT_FILE"
          fi
        fi

        SQL_SELECT_CSV="SELECT t.* FROM ${esc_db_ident}.${esc_table_ident} t WHERE ${esc_col_ident} = '${ESCAPED_SEARCH}';"
        [[ $VERBOSE -eq 1 ]] && echo "[SQL] ${SQL_SELECT_CSV}" | tee -a "$LOGFILE"
        # output rows (tabs->commas), but prefix each row with quoted context columns
        # read mysql output line-by-line to prefix safely
        _mysql_data "$SQL_SELECT_CSV" | while IFS= read -r rowline || [[ -n "$rowline" ]]; do
          # convert tabs to commas (note: fields themselves may include commas/newlines; for perfect CSV use Python)
          row_csv=$(printf "%s" "$rowline" | sed 's/\t/,/g')
          pref=$(csv_quote "$DB"),$(csv_quote "$TABLE"),$(csv_quote "$COL")
          printf "%s,%s\n" "$pref" "$row_csv" >> "$OUT_FILE"
        done
        echo "    -> appended to ${OUT_FILE}" | tee -a "$LOGFILE"
      fi
    fi
  done
done

echo "Done. Results: ${EXPORT_DIR} (log: ${LOGFILE})" | tee -a "$LOGFILE"
