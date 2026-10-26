import js from '@eslint/js';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  { ignores: ['www/', 'types/', 'node_modules/', '.build/', 'android/build/'] },
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
);
