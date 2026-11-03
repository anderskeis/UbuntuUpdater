#!/usr/bin/env node
'use strict';
// filter-global-npm.js <npm-global-root>
//
// Reads `npm ls --global --depth=0 --json` from stdin and prints the names of
// globally installed packages that are safe to update with `npm update -g`,
// one per line. Excludes the runtime/package manager itself and OpenClaw
// (which manages its own updates), and only keeps packages whose canonical
// (fully resolved) path is exactly under the canonical global root, so
// symlinked scope/package directories cannot escape the root.
const fs = require('fs');
const path = require('path');

const PROTECTED = new Set(['npm', 'node', 'corepack', 'openclaw']);
const PROTECTED_PREFIXES = ['@openclaw/'];

function fail(code, msg) {
  console.error('filter-global-npm: ' + msg);
  process.exit(code);
}

function main() {
  const root = process.argv[2];
  if (!root || !path.isAbsolute(root)) {
    fail(64, 'usage: filter-global-npm.js <absolute npm global root>');
  }
  let realRoot;
  try {
    realRoot = fs.realpathSync(root);
  } catch (err) {
    fail(65, 'cannot resolve npm global root ' + root + ': ' + err.message);
  }
  let raw;
  try {
    raw = fs.readFileSync(0, 'utf8'); // fd 0 = stdin
  } catch (err) {
    fail(65, 'cannot read inventory from stdin: ' + err.message);
  }
  let tree;
  try {
    tree = JSON.parse(raw);
  } catch (err) {
    fail(66, 'inventory is not valid JSON: ' + err.message);
  }
  const deps =
    tree && typeof tree === 'object' && tree.dependencies && typeof tree.dependencies === 'object'
      ? tree.dependencies
      : {};
  const eligible = [];
  for (const name of Object.keys(deps)) {
    if (PROTECTED.has(name)) continue;
    if (PROTECTED_PREFIXES.some((p) => name.startsWith(p))) continue;
    if (deps[name] && deps[name].invalid === true) {
      console.error('filter-global-npm: skipping invalid package: ' + name);
      continue;
    }
    const dir = path.join(root, name);
    let real;
    try {
      real = fs.realpathSync(dir);
    } catch {
      console.error('filter-global-npm: skipping missing package dir: ' + dir);
      continue;
    }
    if (real !== path.join(realRoot, name)) {
      console.error('filter-global-npm: skipping package resolving outside global root: ' + dir + ' -> ' + real);
      continue;
    }
    eligible.push(name);
  }
  eligible.sort();
  for (const name of eligible) console.log(name);
}

main();
