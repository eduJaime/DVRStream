/** Retry backoff in seconds: 5, 10, 20, then 30 capped (design §Stream Lifecycle). */
const RETRY_DELAYS_SECONDS = [5, 10, 20, 30] as const;

/**
 * Pure backoff schedule for the camera player.
 * `attempt` is zero-based: 0 → 5s, 1 → 10s, 2 → 20s, 3 and beyond → 30s.
 */
export function nextRetryDelay(attempt: number): number {
  const index = Math.min(Math.max(attempt, 0), RETRY_DELAYS_SECONDS.length - 1);
  return RETRY_DELAYS_SECONDS[index];
}
