#!/usr/bin/env node
// Spec K6: compile test/consumer against the package as an app installs it (node_modules + package.json "types").
import { execFileSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const app = mkdtempSync(join(tmpdir(), 'edge-rum-consumer-'));
try {
  cpSync(join(root, 'test/consumer'), app, { recursive: true });
  mkdirSync(join(app, 'node_modules/@nathanclaire'), { recursive: true });
  symlinkSync(root, join(app, 'node_modules/@nathanclaire/rum-cordova'), 'dir');
  execFileSync(process.execPath, [join(root, 'node_modules/typescript/bin/tsc'), '-p', app], { stdio: 'inherit' });
  console.log('[check-typings] OK');
} finally {
  rmSync(app, { recursive: true, force: true });
}
