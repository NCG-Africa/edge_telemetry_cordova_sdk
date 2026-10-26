import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const script = new URL('../scripts/terminology-check.mjs', import.meta.url).pathname;
const dir = mkdtempSync(join(tmpdir(), 'edge-rum-terms-'));

function check(text: string): number | null {
  const file = join(dir, 'sample.d.ts');
  writeFileSync(file, text);
  return spawnSync(process.execPath, [script, file]).status;
}

describe('terminology check (N4)', () => {
  it('passes consumer words', () => {
    expect(check('/** Capture an event and its performance data. */\nexport declare function track(): void;')).toBe(0);
  });

  it.each(['telemetry', 'Span', 'traces', 'Tracer', 'metric', 'metrics', 'instrumentation', 'OTel', 'OTLP'])(
    'fails on %s',
    (word) => expect(check(`/** ${word} */`)).toBe(1),
  );

  it('ignores substrings inside identifiers (e.g. repo names)', () => {
    expect(check('see edge_telemetry_cordova_sdk')).toBe(0);
  });
});
