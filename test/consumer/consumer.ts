// Compiles against the generated typings the way a plain Cordova app would (spec K6):
// no import; the package is only listed under tsconfig "types".
const version: string = window.EdgeRum.sdkVersion;
window.EdgeRum.init({
  beforeSend: (e) => (e.eventName === 'custom_event' ? { ...e, attributes: { ...e.attributes, scrubbed: true } } : null),
  correlateRequestsTo: ['api.example.com', /\.example\.org$/],
});
window.EdgeRum.identify({ id: 'u1', email: 'a@b.c' });
window.EdgeRum.track('checkout', { plan: 'pro', items: 3, gift: false });
window.EdgeRum.time('load').end({ cached: true });
const session: Promise<string> = window.EdgeRum.getSessionId();
export { version, session };
