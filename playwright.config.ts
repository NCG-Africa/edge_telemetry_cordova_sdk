import { defineConfig } from '@playwright/test';

// Spec Q2: copied from edge_telemetry_ionic_angular_capacitor; the harness serves www/edge-rum.js.
const MOCK_INGEST_PORT = 4319;
const HARNESS_PORT = 4320;

export default defineConfig({
  testDir: './e2e/specs',
  timeout: 30_000,
  fullyParallel: false,
  workers: 1,
  reporter: [['list']],
  use: {
    baseURL: `http://localhost:${HARNESS_PORT}`,
    trace: 'retain-on-failure',
  },
  webServer: [
    {
      command: 'node e2e/mock-ingest-server.mjs',
      url: `http://localhost:${MOCK_INGEST_PORT}/__health`,
      reuseExistingServer: !process.env.CI,
      env: { MOCK_INGEST_PORT: String(MOCK_INGEST_PORT) },
      timeout: 10_000,
    },
    {
      command: 'node e2e/harness-server.mjs',
      url: `http://localhost:${HARNESS_PORT}/`,
      reuseExistingServer: !process.env.CI,
      env: { HARNESS_PORT: String(HARNESS_PORT) },
      timeout: 10_000,
    },
  ],
  projects: [{ name: 'chromium', use: { browserName: 'chromium' } }],
});
