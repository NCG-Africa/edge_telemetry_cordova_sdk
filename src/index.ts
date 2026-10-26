/** Public `EdgeRum` object, available as `window.EdgeRum` once the plugin loads. */
export interface EdgeRumApi {
  /** Version of this plugin, e.g. `1.0.0`. */
  readonly sdkVersion: string;
}

declare global {
  interface Window {
    EdgeRum: EdgeRumApi;
  }
}

export const sdkVersion: string = __SDK_VERSION__;
