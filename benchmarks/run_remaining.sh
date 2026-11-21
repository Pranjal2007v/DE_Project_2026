#!/usr/bin/env bash
# Runs remaining large-baseline queries EXCEPT R19 (too slow without indexes).
# R13 was already captured (316460 ms). R19 is extrapolated in the report.
set -euo pipefail

PSQL="${PSQL:-psql}"
DB="${1:?database name required}"
RUNS="${2:-3}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKLOAD="$ROOT/queries/workload_30.sql"
OUT="$ROOT/benchmarks/results/large"
SUMMARY="$OUT/summary.csv"
mkdir -p "$OUT"

# Manually append R13 (already measured: 316460 ms single run captured)
if ! grep -q "^R13," "$SUMMARY" 2>/dev/null; then
  echo "R13,READ,316460.169,316460.169,316460.169,316460.169,Seq Scan on properties | Seq Scan on projects | Seq Scan on builders" >> "$SUMMARY"
  echo "R13  READ  avg 316460.169 ms  (measured, single run — 3×316s too slow to repeat)"
fi

# Split workload into temp files
TMP="$(mktemp -d)"
awk -v dir="$TMP" '
  /^-- @/ { id = ""; if ($2 ~ /^@[RW][0-9]+$/) { id = substr($2, 2); file = dir "/" id ".sql"; printf "" > file }; next }
  id != "" && !/^--/ { print >> file }
' "$WORKLOAD"

SKIP_LIST="R01 R02 R03 R04 R05 R06 R07 R08 R09 R10 R11 R12 R13 R19"

for f in $(ls "$TMP"/*.sql | sort -V); do
  id="$(basename "$f" .sql)"

  # Skip already-done and R19
  skip=false
  for s in $SKIP_LIST; do [[ "$id" == "$s" ]] && skip=true; done
  if grep -q "^$id," "$SUMMARY" 2>/dev/null; then skip=true; fi
  if $skip; then echo "SKIP $id"; continue; fi

  type="READ"; [[ "$id" == W* ]] && type="WRITE"
  query="$(cat "$f")"
  times=()
  : > "$OUT/$id.txt"
  for ((i = 1; i <= RUNS; i++)); do
    if [[ "$type" == "WRITE" ]]; then
      sql="SET search_path TO housing; BEGIN; EXPLAIN (ANALYZE, BUFFERS) $query ROLLBACK;"
    else
      sql="SET search_path TO housing; EXPLAIN (ANALYZE, BUFFERS) $query"
    fi
    plan="$(printf '%s\n' "$sql" | "$PSQL" -d "$DB" -X -q -A -t -v ON_ERROR_STOP=1)"
    echo "=== $id run $i ===" >> "$OUT/$id.txt"
    echo "$plan" >> "$OUT/$id.txt"
    t="$(echo "$plan" | grep -oE 'Execution Time: [0-9.]+' | awk '{print $3}')"
    times+=("$t")
  done
  sorted=($(printf '%s\n' "${times[@]}" | sort -g))
  median="${sorted[$((RUNS / 2))]}"
  avg="$(printf '%s\n' "${times[@]}" | awk '{ s += $1 } END { printf "%.3f", s / NR }')"
  node="$(echo "$plan" | grep -oE '(Parallel )?(Seq Scan|Index Scan|Index Only Scan|Bitmap Heap Scan|Bitmap Index Scan)( Backward)?( using [a-z0-9_]+)? on [a-z0-9_]+' | sed -E 's/Parallel //; s/ Backward//' | awk '!seen[$0]++' | paste -sd'|' - | sed 's/|/ | /g' || true)"
  node="${node:-(no scan)}"
  echo "$id,$type,$avg,$median,${sorted[0]},${sorted[$((RUNS - 1))]},$node" >> "$SUMMARY"
  printf '%-4s %-5s avg %9s ms   %s\n' "$id" "$type" "$avg" "$node"
done
rm -rf "$TMP"
echo "Done. Summary: $SUMMARY"
