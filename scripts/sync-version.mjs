#!/usr/bin/env node
// Spec V3: package.json is the single version source; `npm version` copies it into plugin.xml.
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const { version } = JSON.parse(readFileSync(root + 'package.json', 'utf8'));
const xml = readFileSync(root + 'plugin.xml', 'utf8');
writeFileSync(root + 'plugin.xml', xml.replace(/(<plugin[^>]*\sversion=")[^"]*"/, `$1${version}"`));
