import js from '@eslint/js';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  { ignores: ['www/', 'types/', 'node_modules/', '.build/', 'android/build/', 'test-results/', 'playwright-report/', 'example/platforms/', 'example/plugins/', 'example/node_modules/'] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    rules: {
      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/no-non-null-assertion': 'error',
      '@typescript-eslint/consistent-type-imports': 'error',
      'no-console': ['error', { allow: ['warn', 'error'] }],
    },
  },
  {
    // Node build/CI scripts: not shipped, may log.
    files: ['scripts/**'],
    languageOptions: { globals: { URL: 'readonly', process: 'readonly', console: 'readonly' } },
    rules: { 'no-console': 'off' },
  },
  {
    // Q2 harness: mock servers (Node) and the fake native page script (browser).
    files: ['e2e/*.mjs'],
    languageOptions: { globals: { URL: 'readonly', process: 'readonly', console: 'readonly', Buffer: 'readonly' } },
    rules: { 'no-console': 'off' },
  },
  {
    // Q4 device driver (Node).
    files: ['e2e/device/*.mjs'],
    languageOptions: { globals: { process: 'readonly', console: 'readonly', fetch: 'readonly', setTimeout: 'readonly' } },
    rules: { 'no-console': 'off' },
  },
  {
    // Q5 example app (browser, Cordova WebView).
    files: ['example/www/*.js'],
    languageOptions: { globals: { window: 'readonly', document: 'readonly', location: 'readonly', navigator: 'readonly', fetch: 'readonly', setTimeout: 'readonly' } },
  },
  {
    files: ['e2e/*.js'],
    languageOptions: { globals: { window: 'readonly', fetch: 'readonly', setTimeout: 'readonly' } },
  },
);
