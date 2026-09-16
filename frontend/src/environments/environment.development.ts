import { Environment } from './environment.interface';

export const environment: Environment = {
  production: false,
  // Same origin, like production: `ng serve` proxies /api (WebSocket included)
  // to the real go2rtc via proxy.conf.json, which is the single place where the
  // IP_LXC placeholder lives. An absolute URL here would be cross-origin and
  // go2rtc does not send CORS headers by default.
  // See "Desviación del plan (§4.3)" in the root README.md.
  go2rtcBaseUrl: '',
};
