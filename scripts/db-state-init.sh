#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# db-state-init.sh — generate the FIRST state (full schema baseline)
# ---------------------------------------------------------------------------
# Usage:
#   npx cap-dbm init
#
# Produces, with the migration number derived from db/migrations:
#
#   db/migrations/V<N>__migration.sql   single file: full DDL + DML placeholder
#   db/snapshots/schema.csn             CSN baseline for the next delta, updated
#                                       in place (no version in the filename)
#
# Use this only for the initial/baseline state of a database. For every state
# after that use `npx cap-dbm delta`.
# ---------------------------------------------------------------------------

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/db-state.sh"

db_state::assert_project_root

VERSION=$(db_state::next_version)
if [ "$VERSION" -ne 1 ]; then
  echo "ERROR: migrations already exist; use 'npx cap-dbm delta'" >&2
  exit 1
fi

echo "Generating state $VERSION (initial baseline) ..."
echo ""

# --- 1. full schema DDL ------------------------------------------------------
echo "Generating full schema DDL (npm run db:initial) ..."
db_state::run_npm db:initial

if [ ! -s initial.sql ]; then
  echo "ERROR: npm run db:initial produced no output at initial.sql" >&2
  exit 1
fi

TARGET="$MIGRATIONS_DIR/V${VERSION}__migration.sql"

# --- 2. write single migration file (DDL + DML placeholder) ------------------
db_state::write_migration_inline "$VERSION" "$TARGET" initial.sql "initial schema for state ${VERSION}"

# --- 3. capture CSN baseline for the next delta ------------------------------
db_state::capture_csn

db_state::summary_inline "$VERSION" "$TARGET"
