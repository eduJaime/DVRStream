export interface Environment {
  production: boolean;
  /**
   * Base URL of the go2rtc instance.
   * Empty string means "same origin", which is the production setup: go2rtc
   * serves both the API and the static frontend from the same host and port.
   */
  go2rtcBaseUrl: string;
}
