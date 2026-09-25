#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check-alignment.sh — CI gate for the state-based migrations
# ---------------------------------------------------------------------------
# The CDS model and db/snapshots/schema.csn must remain aligned, and every
# snapshot change must ship with a migration. This is the automated check for
# that.
#
# Two independent failure modes are covered:
#
#   1. Model drift    — the CDS model no longer matches db/snapshots/schema.csn,
#                       i.e. someone changed .cds without generating a migration.
#   2. Orphan snapshot — schema.csn changed in this PR but no migration was added,
#                       i.e. the baseline moved with nothing to apply it.
#
# Usage:
#   npx cap-dbm check
#   BASE_REF=origin/main npx cap-dbm check
# ---------------------------------------------------------------------------

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/db-state.sh"

db_state::assert_project_root

CSN_SNAPSHOT="db/snapshots/schema.csn"
MIGRATIONS_DIR="db/migrations"
BASE_REF="${BASE_REF:-origin/develop}"
failed=0

if [ ! -s "$CSN_SNAPSHOT" ]; then
  echo "FAIL: $CSN_SNAPSHOT is missing or empty." >&2
  echo "      It is the baseline every delta is generated from and must be committed." >&2
  exit 1
fi

# --- 1. model drift ---------------------------------------------------------
# A dry delta against the committed snapshot must be empty. Any DDL here means
# the model moved without a migration to carry the change.
echo "Checking CDS model against $CSN_SNAPSHOT ..."
delta_out=$(mktemp)
trap 'rm -f "$delta_out"' EXIT

if ! npm run --silent delta > /dev/null 2>&1; then
  echo "FAIL: could not generate the delta (npm run delta)." >&2
  exit 1
fi

# npm run delta writes to delta.sql in the repo root
if [ -f delta.sql ]; then
  mv delta.sql "$delta_out"
fi

if grep -qE '^\s*(CREATE|ALTER|DROP)' "$delta_out" 2>/dev/null; then
  echo "" >&2
  echo "FAIL: the CDS model has changed but no migration was generated." >&2
  echo "      Pending DDL:" >&2
  grep -E '^\s*(CREATE|ALTER|DROP)' "$delta_out" | head -20 | sed 's/^/        /' >&2
  echo "" >&2
  echo "      Fix: npx cap-dbm delta, review the generated migration," >&2
  echo "           then commit it together with $CSN_SNAPSHOT." >&2
  failed=1
else
  echo "  OK — model and snapshot are aligned."
fi

# --- 2. orphan snapshot -----------------------------------------------------
# Only meaningful when the base ref is reachable; shallow clones may not have it.
if git rev-parse --verify --quiet "$BASE_REF" > /dev/null; then
  echo "Checking snapshot/migration pairing against $BASE_REF ..."
  changed=$(git diff --name-only "$BASE_REF...HEAD")

  if echo "$changed" | grep -qx "$CSN_SNAPSHOT"; then
    if echo "$changed" | grep -qE "^${MIGRATIONS_DIR}/V[0-9]+__.*\.sql$"; then
      echo "  OK — snapshot change ships with a migration."
    else
      echo "" >&2
      echo "FAIL: $CSN_SNAPSHOT changed but no $MIGRATIONS_DIR/V*.sql was added." >&2
      echo "      A moved baseline with no migration leaves every environment behind." >&2
      failed=1
    fi
  else
    echo "  OK — snapshot unchanged."
  fi
else
  echo "Skipping snapshot/migration pairing: $BASE_REF not available." >&2
fi

# --- 3. duplicate versions --------------------------------------------------
dupes=$(find "$MIGRATIONS_DIR" -maxdepth 1 -name 'V*.sql' -exec basename {} \; 2>/dev/null |
  sed -E 's/^V([0-9]+)__.*/\1/' | sort -n | uniq -d)

if [ -n "$dupes" ]; then
  echo "FAIL: duplicate migration versions: $(echo "$dupes" | tr '\n' ' ')" >&2
  echo "      Rebase and renumber to the next free version." >&2
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo ""
echo "✓ Migrations and CSN snapshot are aligned."
