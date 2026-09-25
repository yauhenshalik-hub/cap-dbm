#!/usr/bin/env node
'use strict';

const { spawnSync } = require('child_process');
const path = require('path');

const COMMANDS = {
  init: { runner: 'bash', file: 'db-state-init.sh' },
  delta: { runner: 'bash', file: 'db-state-delta.sh' },
  check: { runner: 'bash', file: 'check-alignment.sh' },
  seed: { runner: process.execPath, file: 'deploy-data.js' },
};

const [, , cmd, ...rest] = process.argv;
const entry = COMMANDS[cmd];

if (!entry) {
  console.error(`Usage: cap-dbm <${Object.keys(COMMANDS).join('|')}> [options]`);
  console.error('');
  console.error('  init   generate the first migration state (full schema baseline)');
  console.error('  delta  generate the next migration state (diff against the last one)');
  console.error('  check  verify the CSN snapshot and migrations are aligned');
  console.error('  seed   deploy db/data CSV/JSON files only, no schema evolution');
  console.error('         options: --csn <path> --data-dir <path> --only <names>');
  process.exit(1);
}

// Runs against the caller's cwd so it can be invoked as `npx cap-dbm <cmd>`
// from the root of any CAP project.
const result = spawnSync(entry.runner, [path.join(__dirname, '..', 'scripts', entry.file), ...rest], {
  stdio: 'inherit',
  cwd: process.cwd(),
});

process.exit(result.status === null ? 1 : result.status);
