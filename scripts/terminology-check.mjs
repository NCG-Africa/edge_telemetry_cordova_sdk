#!/usr/bin/env node
// Spec N4 terminology firewall: consumer-facing text must not use these words.
// Usage: terminology-check.mjs [file...]  (defaults to the shipped consumer surface)
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const BANNED = /\b(telemetry|spans?|traces?|tracer|metrics?|instrumentation|otel|otlp)\b/i;
const root = new URL('..', import.meta.url).pathname;

function consumerSurface() {
  const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
  const xml = readFileSync(join(root, 'plugin.xml'), 'utf8');
  const texts = [
    ['package.json', [pkg.name, pkg.description, ...pkg.keywords].join('\n')],
    // ponytail: only <name>/<description>/id; rest of plugin.xml is wire/pref names.
    ['plugin.xml', (xml.match(/<(name|description)>[^<]*|id="[^"]*"/g) ?? []).join('\n')],
  ];
  const typesDir = join(root, 'types');
  if (!existsSync(typesDir)) {
    console.error('[terminology-check] types/ missing — run `npm run build` first');
    process.exit(2);
  }
  for (const f of readdirSync(typesDir, { recursive: true })) {
    if (String(f).endsWith('.d.ts')) texts.push([join('types', String(f)), readFileSync(join(typesDir, String(f)), 'utf8')]);
  }
  if (existsSync(join(root, 'README.md'))) texts.push(['README.md', readFileSync(join(root, 'README.md'), 'utf8')]);
  return texts;
}

const args = process.argv.slice(2);
const texts = args.length ? args.map((f) => [f, readFileSync(f, 'utf8')]) : consumerSurface();

let violations = 0;
for (const [file, text] of texts) {
  text.split('\n').forEach((line, i) => {
    if (BANNED.test(line)) {
      console.error(`${file}:${i + 1}  ${line.trim()}`);
      violations++;
    }
  });
}

if (violations) {
  console.error(`[terminology-check] FAIL: ${violations} line(s) use banned words (spec N4)`);
  process.exit(1);
}
console.log(`[terminology-check] OK — ${texts.length} source(s) scanned`);
