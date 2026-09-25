#!/usr/bin/env node
// ---------------------------------------------------------------------------
// deploy-data.js — seed db/data CSV/JSON files only, without schema evolution
// ---------------------------------------------------------------------------
// Usage:
//   npx cap-dbm seed [--csn <path>] [--data-dir <path>] [--only <names>]
//
//   --csn        path to the compiled CSN (default: db/csn.json)
//   --data-dir   scan this folder for .csv/.json files instead of the
//                convention-based lookup (db/data, db/csv, per model source)
//   --only       comma-separated list of file/entity names to restrict the
//                seed to, e.g. "Books,my.bookshop-Authors"
//
// Flyway (or an equivalent migration runner) owns the schema, and the runtime
// DB role is not the owner of Flyway-created objects (views, etc.), so CAP's
// automatic schema evolution must never run here — it would fail with
// "must be owner of view ..." errors. This bypasses deploy.schema entirely
// and calls deploy.data directly.
//
// Do NOT set cds.requires.db.schema_evolution = false to "disable" evolution:
// deploy.data reads the same flag (cds-deploy.js INSERT_from4) to choose UPSERT
// over plain INSERT. With it unset, the postgres default 'auto' applies and
// rows are UPSERTed; setting it to false would switch to INSERT and every
// redeploy would fail on duplicate keys. Evolution is already off here because
// deploy.schema is simply never called.
// ---------------------------------------------------------------------------
const fs = require('fs');
const path = require('path');
const cds = require('@sap/cds');
const deploy = require('@sap/cds/lib/dbs/cds-deploy');

function parseArgs(argv) {
  const out = { csnPath: 'db/csn.json', dataDir: null, only: null };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--csn') out.csnPath = argv[++i];
    else if (arg.startsWith('--csn=')) out.csnPath = arg.slice('--csn='.length);
    else if (arg === '--data-dir') out.dataDir = argv[++i];
    else if (arg.startsWith('--data-dir=')) out.dataDir = arg.slice('--data-dir='.length);
    else if (arg === '--only') out.only = argv[++i];
    else if (arg.startsWith('--only=')) out.only = arg.slice('--only='.length);
  }
  return out;
}

// Same "prefer the translated variant" rule cds.deploy.resources uses: skip
// 'Foo_texts.csv' when 'Foo_texts_en.csv' (etc.) is also present.
function scanDataDir(dir) {
  const entries = fs.readdirSync(dir).filter((f) => f[0] !== '-');
  const dataFiles = entries.filter((f) => ['.csv', '.json'].includes(path.extname(f)));
  const superseded = new Set();
  for (const f of dataFiles) {
    const base = f.slice(0, -path.extname(f).length);
    if (/[._]texts$/.test(base) && dataFiles.some((g) => g !== f && g.startsWith(base + '_'))) {
      superseded.add(f);
    }
  }
  const files = {};
  for (const f of dataFiles) {
    if (superseded.has(f)) continue;
    files[path.join(dir, f)] = fs.readFileSync(path.join(dir, f), 'utf8');
  }
  return files;
}

function filterByName(files, only) {
  if (!only) return files;
  const wanted = new Set(only.split(',').map((s) => s.trim()));
  const filtered = {};
  for (const [file, content] of Object.entries(files)) {
    const base = path.basename(file).replace(/\.(csv|json)$/, '');
    const entityName = base.replace(/-/g, '.');
    if (wanted.has(base) || wanted.has(entityName)) filtered[file] = content;
  }
  return filtered;
}

// Resolve which files to seed from: an explicit --data-dir, or CAP's own
// convention-based lookup (db/data, db/csv, next to each model source file).
async function resolveSrces(csn, dataDir, only) {
  if (!dataDir && !only) return undefined; // let deploy.prepare/deploy.data use their own default lookup

  let files;
  if (dataDir) {
    files = scanDataDir(path.resolve(dataDir));
  } else {
    const found = await deploy.resources(csn);
    files = {};
    for (const [file, entityName] of Object.entries(found)) {
      if (entityName === '*') continue; // init.js/init.ts, not a plain data file
      files[file] = await cds.utils.read(file, 'utf8');
    }
  }
  return filterByName(files, only);
}

// deploy.data only UPSERTs rows found in a CSV — it never removes rows whose
// key was deleted from the CSV. Diff each CSV against its table first and
// delete the leftovers, so the data files stay the single source of truth.
async function removeStaleRows(db, model, resources) {
  for (const [, entityName, src] of resources) {
    const entity = entityName && model.definitions[entityName];
    if (!entity?.keys) continue;

    const keyCols = Object.keys(entity.keys);
    const [cols, ...rows] = cds.parse.csv(src);
    if (!keyCols.every((k) => cols.includes(k))) continue; // can't safely diff without all key columns

    if (keyCols.length === 1) {
      // single-column key (the common case, e.g. CodeList.code): one native "not in" delete
      const [key] = keyCols;
      const keep = rows.map((row) => row[cols.indexOf(key)]);
      await db.run(DELETE.from(entity).where({ [key]: { 'not in': keep } }));
      continue;
    }

    // composite key (e.g. .texts entities): CQN has no tuple "not in", so diff row by row
    const keyOf = (row) => keyCols.map((k) => row[k]).join('\u0000');
    const keep = new Set(rows.map((row) => keyOf(Object.fromEntries(cols.map((c, i) => [c, row[i]])))));
    const existing = await db.run(SELECT.from(entity).columns(keyCols));
    for (const row of existing) {
      if (keep.has(keyOf(row))) continue;
      await db.run(DELETE.from(entity).where(row));
    }
  }
}

async function main() {
  const { csnPath, dataDir, only } = parseArgs(process.argv.slice(2));

  const csn = await cds.load(csnPath).then(cds.minify);
  const model = cds.compile.for.nodejs(csn);
  const db = await cds.connect.to('db');

  const srces = await resolveSrces(csn, dataDir, only);
  const resources = await deploy.prepare(csn, srces);

  await db.run(async (tx) => {
    await removeStaleRows(tx, model, resources);
    await deploy.data(tx, csn, {}, srces, (file) => console.log(' > init from', file));
  });
}

main()
  .then(() => {
    console.log('/> successfully seeded initial data');
    process.exit(0);
  })
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
