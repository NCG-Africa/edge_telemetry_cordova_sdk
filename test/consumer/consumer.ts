// Compiles against the generated typings the way an app would (spec K6).
import type { EdgeRumApi } from '@nathanclaire/rum-cordova';

const api: EdgeRumApi = window.EdgeRum;
const version: string = api.sdkVersion;
export { version };
