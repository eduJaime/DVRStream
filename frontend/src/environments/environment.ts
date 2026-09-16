import { Environment } from './environment.interface';

export const environment: Environment = {
  production: true,
  // Same origin: go2rtc serves the API and the static frontend.
  go2rtcBaseUrl: '',
};
