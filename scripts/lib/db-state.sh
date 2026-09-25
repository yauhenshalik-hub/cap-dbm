#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# db-state.sh — shared helpers for the state-based migration generators
# ---------------------------------------------------------------------------
# Sourced by:
#   scripts/db-state-init.sh    (first state — full DDL from db:initial)
#   scripts/db-state-delta.sh   (follow-up states — delta DDL from npm run delta)
#   scripts/check-alignment.sh
#
# Layout produced by the delta script, relative to the CAP project root:
#
#   db/migrations/V<N>__migration.sql     DDL delta + DML placeholder
#   db/snapshots/schema.csn                CSN baseline for the next delta, updated in place
# ---------------------------------------------------------------------------

MIGRATIONS_DIR="db/migrations"
SNAPSHOTS_DIR="db/snapshots"
CSN_SNAPSHOT="$SNAPSHOTS_DIR/schema.csn"

# --- confirm we are running from a CAP project root -------------------------
# This tool is invoked via `npx cap-dbm <cmd>` from the consuming
# project, so the working directory is already the project root — nothing to
# cd into, just fail fast with a clear message if it looks wrong.
db_state::assert_project_root() {
  if [ ! -f package.json ]; then
    echo "ERROR: no package.json in $(pwd)." >&2
    echo "       Run cap-dbm from the root of your CAP project." >&2
    exit 1
  fi
}

# --- next migration number ---------------------------------------------------
# Scans both `V<n>__*.sql` files and `V<n>` state folders so the number stays
# unique even if one of the two is missing.
db_state::next_version() {
  local highest
  highest=$(
    {
      ls -d "$MIGRATIONS_DIR"/V[0-9]* 2>/dev/null || true
    } | sed -E 's#.*/V([0-9]+).*#\1#' | sort -n | tail -1
  )
  echo $(( ${highest:-0} + 1 ))
}

# --- run an npm script, surfacing stderr only on failure --------------------
# CDS writes compiler warnings to stderr even on success, so stderr is captured
# and dropped when the command succeeds. On failure the tail is printed -
# without this the caller aborts silently under `set -e` (e.g. when the npm
# script itself is missing from package.json).
db_state::run_npm() {
  local script="$1"
  local log
  log=$(mktemp)

  if ! npm run --silent "$script" >/dev/null 2>"$log"; then
    echo "ERROR: 'npm run $script' failed:" >&2
    tail -20 "$log" >&2
    rm -f "$log"
    exit 1
  fi

  rm -f "$log"
}

# --- Ensure schema.csn exists for 'npm run delta' ----------------------------
# schema.csn is a single tracked file, updated in place by every state — it
# should only be missing on a broken checkout, never as part of normal usage.
db_state::ensure_csn() {
  if [ -s "$CSN_SNAPSHOT" ]; then
    return 0
  fi

  echo "ERROR: $CSN_SNAPSHOT not found." >&2
  echo "" >&2
  echo "Pick one:" >&2
  echo "  git checkout $CSN_SNAPSHOT      # restore the committed baseline" >&2
  echo "  npx cap-dbm init      # no state exists yet — create the baseline instead" >&2
  echo "  npm run capture                 # re-baseline from the CURRENT model" >&2
  exit 1
}

# --- CSN snapshot ------------------------------------------------------------
# The baseline lives in Git as db/snapshots/schema.csn and nowhere else. This
# tool intentionally never writes CAP's automatic `cds_model` table: that
# would be a second baseline that nothing reads and that silently drifts from
# the committed snapshot.
db_state::capture_csn() {
  echo "Capturing CSN model (npm run capture) ..."
  db_state::run_npm capture

  if [ ! -s "$CSN_SNAPSHOT" ]; then
    echo "ERROR: npm run capture produced no output at $CSN_SNAPSHOT" >&2
    exit 1
  fi
}

# --- V<N>__migration.sql (single-file, no subfolder) -------------------------
# $3 — DDL source file (default: delta.sql)
# $4 — DDL section label (default: "delta to model <N>")
db_state::write_migration_inline() {
  local version="$1"
  local target="$2"
  local ddl_file="${3:-delta.sql}"
  local ddl_label="${4:-delta to model ${version}}"

  cat > "$target" <<EOF
-- ---------------------------------------------------------------------------
-- V${version}__migration.sql — state ${version}
-- ---------------------------------------------------------------------------
-- Applied by Flyway (or an equivalent migration runner) as part of your
-- deployment pipeline, which should run every unapplied V*.sql in order.
--
-- Flyway wraps the whole file in one transaction, so the state applies
-- completely or not at all.
--
-- To apply by hand locally:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f $target
-- ---------------------------------------------------------------------------


-- === DDL — ${ddl_label} =============================================

EOF

  cat "$ddl_file" >> "$target"
  rm -f "$ddl_file"

  cat >> "$target" <<EOF


-- === DML — reference and seed data for state ${version} ==========================
--
-- Placeholder: this state ships no data changes yet.
--
-- Add INSERT / UPDATE / DELETE statements here for anything the schema change
-- needs at runtime — new code-list entries, backfills for a newly added column,
-- mapping table rows, and so on.
--
-- Runs inside the same transaction as the DDL above, so a failure here rolls
-- the whole state back. Keep statements idempotent where possible
-- (ON CONFLICT DO NOTHING / WHERE NOT EXISTS).
EOF

  echo "  $target"
}

# --- summary (single-file flow) ----------------------------------------------
db_state::summary_inline() {
  local version="$1"
  local target="$2"

  echo ""
  echo "✓ State ${version} created:"
  echo "  Migration: $target"
  echo "  Snapshot:  $CSN_SNAPSHOT (updated in place — commit with the migration)"
  echo ""
  echo "Review the generated SQL, add DML at the bottom of $target if needed,"
  echo "then commit everything together with your .cds changes."
}
