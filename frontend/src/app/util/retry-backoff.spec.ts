import { nextRetryDelay } from './retry-backoff';

describe('nextRetryDelay', () => {
  it('returns the 5s/10s/20s/30s backoff sequence in seconds', () => {
    expect(nextRetryDelay(0)).toBe(5);
    expect(nextRetryDelay(1)).toBe(10);
    expect(nextRetryDelay(2)).toBe(20);
    expect(nextRetryDelay(3)).toBe(30);
  });

  it('caps the delay at 30s for later attempts', () => {
    expect(nextRetryDelay(4)).toBe(30);
    expect(nextRetryDelay(99)).toBe(30);
  });

  it('treats invalid (negative) attempts as the first one', () => {
    expect(nextRetryDelay(-1)).toBe(5);
  });
});
