import { buildStreamUrl } from './stream-url';

describe('buildStreamUrl', () => {
  it('falls back to the page origin when the configured base URL is empty (same-origin dev/prod)', () => {
    expect(buildStreamUrl('cam1', '', 'http://localhost:4200')).toBe(
      'ws://localhost:4200/api/ws?src=cam1',
    );
  });

  it('uses the configured base URL when present, ignoring the page origin', () => {
    expect(buildStreamUrl('cam2', 'http://go2rtc.test:1984', 'http://localhost:4200')).toBe(
      'ws://go2rtc.test:1984/api/ws?src=cam2',
    );
  });

  it('tolerates a trailing slash in the base URL', () => {
    expect(buildStreamUrl('cam1', 'http://go2rtc.test:1984/', 'http://localhost:4200')).toBe(
      'ws://go2rtc.test:1984/api/ws?src=cam1',
    );
  });

  it('upgrades the WebSocket protocol to wss for https origins', () => {
    expect(buildStreamUrl('cam3', 'https://go2rtc.test:1984', 'http://localhost:4200')).toBe(
      'wss://go2rtc.test:1984/api/ws?src=cam3',
    );
  });

  it('encodes the camera id in the src query parameter', () => {
    expect(buildStreamUrl('cam 1&x', '', 'http://localhost:4200')).toBe(
      'ws://localhost:4200/api/ws?src=cam%201%26x',
    );
  });
});
