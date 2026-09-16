/**
 * Builds the go2rtc WebSocket URL for a camera stream.
 *
 * `baseUrl` is `environment.go2rtcBaseUrl`: an empty string means "same origin"
 * (production, and development through the `ng serve` proxy), so the page
 * origin is used instead. The function is pure (the origin is a parameter) so
 * it can be unit-tested without Angular TestBed or a DOM.
 */
export function buildStreamUrl(cameraId: string, baseUrl: string, origin: string): string {
  const base = baseUrl.length > 0 ? baseUrl : origin;
  const normalizedBase = base.endsWith('/') ? base : `${base}/`;

  const url = new URL(`api/ws?src=${encodeURIComponent(cameraId)}`, normalizedBase);
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';

  return url.href;
}
