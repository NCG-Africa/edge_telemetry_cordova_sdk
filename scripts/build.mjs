#!/usr/bin/env node
// Bundles src/ into the single <js-module> www/edge-rum.js (spec K6, V3).
import { build } from 'esbuild';
import { readFileSync } from 'node:fs';

const root = new URL('..', import.meta.url).pathname;
const { version } = JSON.parse(readFileSync(root + 'package.json', 'utf8'));

await build({
  entryPoints: [root + 'src/index.ts'],
  outfile: root + 'www/edge-rum.js',
  bundle: true,
  // cjs: cordova.define wraps the file and clobbers window.EdgeRum with module.exports.
  format: 'cjs',
  target: 'es2017',
  define: { __SDK_VERSION__: JSON.stringify(version) },
  logLevel: 'warning',
});
