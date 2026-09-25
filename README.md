# cap-dbm

State-based, Flyway-style database migrations generated from SAP CAP's CDS delta/init output.

Not published yet — use it locally via a `file:` dependency until it's published to a registry:

```sh
npm install --save-dev file:../a-cap-libs/cap-dbm
```

## Usage

Run from the root of a CAP project:

```sh
npx cap-dbm init    # first state only — full schema baseline
npx cap-dbm delta   # every state after — diff against the last snapshot
npx cap-dbm check   # verify snapshot and migrations are aligned (CI gate)
npx cap-dbm seed    # deploy db/data CSV/JSON files only, no schema evolution
```

`seed` accepts:

- `--csn <path>` — compiled CSN to read (default: `db/csn.json`)
- `--data-dir <path>` — scan this folder for `.csv`/`.json` files instead of CAP's
  convention-based lookup (`db/data`, `db/csv`, next to each model source file)
- `--only <names>` — comma-separated file or entity names to restrict the seed to,
  e.g. `--only Books,my.bookshop-Authors`

See [docs/schema-migration.md](docs/schema-migration.md) and
[docs/state-based-migrations.md](docs/state-based-migrations.md) for the full workflow.

## Required npm scripts

This tool shells out to a few CDS-specific scripts that must exist in the consuming project's
`package.json`:

```json
{
  "scripts": {
    "db:initial": "cds deploy --profile production --to postgres --script --dry > initial.sql",
    "capture": "cds deploy --profile production --dry --model-only > db/snapshots/schema.csn",
    "delta": "cds deploy --profile production --to postgres --script --dry --delta-from db/snapshots/schema.csn > delta.sql"
  }
}
```

## Layout expected in the consuming project

```text
db/migrations/V<N>__migration.sql   one file per state: DDL + DML, one transaction
db/snapshots/schema.csn             CSN baseline the next delta is computed against
```
