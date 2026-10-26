#!/usr/bin/env node
// Spec K6: tarball = www/ + types/ + native sources + plugin.xml (+ npm's always-included files).
import { execSync } from 'node:child_process';

const ALLOWED = /^(www\/edge-rum\.js|types\/.+\.d\.ts|android\/src\/main\/.+\.java|ios\/Sources\/.+\.swift|Package\.swift|plugin\.xml|package\.json|README\.md|LICENSE|CHANGELOG\.md)$/;
const REQUIRED = ['www/edge-rum.js', 'types/index.d.ts', 'plugin.xml', 'Package.swift'];

const root = new URL('..', import.meta.url).pathname;
const out = JSON.parse(execSync('npm pack --dry-run --json --ignore-scripts', { cwd: root, encoding: 'utf8' }));
const entry = Array.isArray(out) ? out[0] : Object.values(out)[0];
const files = entry.files.map((f) => f.path);

const extra = files.filter((f) => !ALLOWED.test(f));
const missing = REQUIRED.filter((f) => !files.includes(f));
for (const f of extra) console.error(`[pack-audit] unexpected: ${f}`);
for (const f of missing) console.error(`[pack-audit] missing: ${f} — run \`npm run build\` first?`);
if (extra.length || missing.length) process.exit(1);
console.log(`[pack-audit] OK — ${files.length} files`);
