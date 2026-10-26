import { execSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { beforeAll, describe, expect, it } from 'vitest';

const root = new URL('..', import.meta.url).pathname;
const read = (p: string) => readFileSync(root + p, 'utf8');
const pkg = JSON.parse(read('package.json')) as { name: string; version: string; cordova: { id: string } };

describe('plugin metadata (K1, V3)', () => {
  const xml = read('plugin.xml');

  it('plugin.xml id and version match package.json', () => {
    expect(xml).toContain(`id="${pkg.name}"`);
    expect(xml).toMatch(new RegExp(`<plugin[^>]*version="${pkg.version}"`));
    expect(pkg.cordova.id).toBe(pkg.name);
  });

  it('no plugin variable name is a prefix of another (cordova substitutes $VAR greedily)', () => {
    const vars = [...xml.matchAll(/<preference name="([A-Z_]+)" default=/g)].map((m) => m[1]);
    expect(vars.length).toBe(13);
    const collisions = vars.filter((a) => vars.some((b) => a !== b && b.startsWith(a)));
    expect(collisions).toEqual([]);
  });

  it('Package.swift product is named after the plugin id (cordova-ios 8 links by id)', () => {
    expect(read('Package.swift')).toContain(`.library(name: "${pkg.name}"`);
  });
});

describe('www/edge-rum.js (K6)', () => {
  let exported: Record<string, unknown>;

  beforeAll(() => {
    execSync('node scripts/build.mjs', { cwd: root });
    // Mimic cordova.define's module wrapper, which hands module.exports to <clobbers>.
    const module = { exports: {} as Record<string, unknown> };
    new Function('require', 'exports', 'module', read('www/edge-rum.js'))(() => undefined, module.exports, module);
    exported = module.exports;
  });

  it('exports sdkVersion injected from package.json', () => {
    expect(exported.sdkVersion).toBe(pkg.version);
  });

  it('is ES2017 (no optional chaining or nullish coalescing)', () => {
    expect(read('www/edge-rum.js')).not.toMatch(/\?\.|\?\?/);
  });
});
