#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# db-state-delta.sh — generate the NEXT state (delta against the last one)
# ---------------------------------------------------------------------------
# Usage:
#   npx cap-dbm delta
#
# Produces, with the migration number derived from db/migrations:
#
#   db/migrations/V<N>__migration.sql  single file: DDL delta + DML placeholder
#
# The delta is computed against db/snapshots/schema.csn, which is a single
# tracked file updated in place after the migration is written (no version in
# the filename) and committed alongside the migration.
# ---------------------------------------------------------------------------

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/db-state.sh"

db_state::assert_project_root

# --- Ensure the previous CSN snapshot is available ---------------------------
db_state::ensure_csn

VERSION=$(db_state::next_version)

echo "Generating state $VERSION (delta from $CSN_SNAPSHOT) ..."
echo ""

# --- 1. migration_to_model_<N>.sql (DDL) ------------------------------------
echo "Generating delta DDL (npm run delta) ..."
db_state::run_npm delta

if ! grep -qE '^\s*(CREATE|ALTER|DROP|INSERT|UPDATE|DELETE)' delta.sql 2>/dev/null; then
  echo "No schema changes detected — nothing to generate."
  echo "Review your db/schema.cds edits and try again."
  rm -f delta.sql
  exit 0
fi

if grep -q '\[WARNING\] this statement is lossy' delta.sql; then
  echo ""
  echo "WARNING: the delta contains lossy statements (DROP / type change)."
  echo "         Do not ship this as-is — follow the Major Change Case documented in"
  echo "         docs/schema-migration.md."
  echo ""
fi

TARGET="$MIGRATIONS_DIR/V${VERSION}__migration.sql"

# --- 2. write single migration file (DDL + DML placeholder) -----------------
db_state::write_migration_inline "$VERSION" "$TARGET"

# --- 3. capture new CSN for the next delta -----------------------------------
db_state::capture_csn

db_state::summary_inline "$VERSION" "$TARGET"
