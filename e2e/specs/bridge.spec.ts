import { expect, test, type Page } from '@playwright/test';

// Spec Q2: pins the A2 action table against the fake native, end to end through mock-ingest.
const INGEST = 'http://localhost:4319';

interface Exec { service: string; action: string; args: unknown[] }
interface Batch { events: { eventName?: string; attributes: Record<string, unknown> }[] }

const execLog = (page: Page) => page.evaluate(() => (window as unknown as { __exec: Exec[] }).__exec);

test.beforeEach(async ({ page, request }) => {
  await request.post(`${INGEST}/__reset`);
  await page.goto('/');
});

test('A2 action names and args', async ({ page }) => {
  await page.evaluate(() => {
    const E = window.EdgeRum;
    E.init({ apiKey: 'k', endpoint: 'https://ingest.example' });
    E.identify({ id: 'u1', email: 'a@b.c' });
    E.track('checkout', { plan: 'pro' });
    E.markReady();
    document.dispatchEvent(new Event('deviceready'));
  });
  await expect.poll(async () => (await execLog(page)).some((c) => c.action === 'enqueue')).toBe(true);
  await page.evaluate(() => {
    const E = window.EdgeRum;
    E.clearUser();
    E.disable();
    E.enable();
    E.reset();
  });

  const log = await execLog(page);
  expect(log.every((c) => c.service === 'EdgeRum')).toBe(true);
  expect(log.map(({ action, args }) => ({ action, args }))).toEqual([
    { action: 'subscribe', args: [] },
    { action: 'getState', args: [] },
    { action: 'configure', args: [{ apiKey: 'k', endpoint: 'https://ingest.example' }] },
    { action: 'identify', args: [{ id: 'u1', email: 'a@b.c' }] },
    { action: 'markPhase', args: [{ phase: 'markReady', ts: expect.any(Number) }] },
    { action: 'enqueue', args: [{ events: [expect.objectContaining({ eventName: 'custom_event' })], breadcrumbs: [] }] },
    { action: 'clearUser', args: [] },
    { action: 'disable', args: [] },
    { action: 'enable', args: [] },
    { action: 'reset', args: [] },
  ]);
});

test('a custom event reaches mock-ingest', async ({ page, request }) => {
  await page.evaluate(() => {
    document.dispatchEvent(new Event('deviceready'));
    window.EdgeRum.identify({ id: 'u1' });
    window.EdgeRum.setAttribute('tenant', 'acme');
    window.EdgeRum.track('checkout', { plan: 'pro' });
  });
  const custom = async () => {
    const { payloads } = (await (await request.get(`${INGEST}/__payloads`)).json()) as { payloads: Batch[] };
    return payloads.flatMap((p) => p.events).find((e) => e.eventName === 'custom_event');
  };
  // T1: the 2 s hand-off timer, then the fake sender's POST.
  await expect.poll(custom, { timeout: 10_000 }).toMatchObject({
    attributes: { 'event.name': 'checkout', plan: 'pro', tenant: 'acme', 'session.id': 'harness-session', 'user.id': 'u1' },
  });
});

test('a thrown error reaches mock-ingest as a fatal app.crash with breadcrumbs', async ({ page, request }) => {
  await page.evaluate(() => {
    document.dispatchEvent(new Event('deviceready'));
    console.warn('before the throw');
    setTimeout(() => {
      throw new TypeError('harness boom');
    });
  });
  const crash = async () => {
    const { payloads } = (await (await request.get(`${INGEST}/__payloads`)).json()) as { payloads: Batch[] };
    return payloads.flatMap((p) => p.events).find((e) => e.eventName === 'app.crash');
  };
  // T1: a crash is handed off at once, no 2 s wait.
  await expect.poll(crash, { timeout: 5_000 }).toMatchObject({
    attributes: { message: 'harness boom', exception_type: 'TypeError', handled: false, is_fatal: true, runtime: 'webview' },
  });
  const a = (await crash())?.attributes ?? {};
  expect(JSON.parse(a['crash.breadcrumbs'] as string)).toEqual([expect.objectContaining({ category: 'console', message: 'before the throw' })]);
});
