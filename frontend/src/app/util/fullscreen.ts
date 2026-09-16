/**
 * Fullscreen capability detection and request/exit wrappers (design D30).
 *
 * Everything is pure over an injected document/target so it can be unit-tested
 * with fake capabilities: jsdom implements no Fullscreen API, and production
 * must not assume one is present (iOS Safari cannot fullscreen a non-`<video>`
 * element).
 */

/** The subset of `Element` needed to go fullscreen (standard + WebKit prefix). */
export interface FullscreenTarget {
  requestFullscreen?(): Promise<void>;
  webkitRequestFullscreen?(): Promise<void>;
}

/** The subset of `Document` needed to detect and leave fullscreen. */
export interface FullscreenDocument {
  readonly fullscreenEnabled?: boolean;
  readonly fullscreenElement?: Element | null;
  readonly documentElement: FullscreenTarget;
  exitFullscreen?(): Promise<void>;
  webkitExitFullscreen?(): Promise<void>;
}

/**
 * True only when the document reports fullscreen as enabled AND the target
 * (the single-view host, by default the document element) exposes a request
 * method. `disabled` + explanation is the fallback, never a dead end.
 */
export function detectFullscreenSupport(
  doc: FullscreenDocument,
  target?: FullscreenTarget,
): boolean {
  if (doc.fullscreenEnabled !== true) return false;
  const element = target ?? doc.documentElement;
  return (
    typeof element.requestFullscreen === 'function' ||
    typeof element.webkitRequestFullscreen === 'function'
  );
}

/** True while any element is fullscreen in this document. */
export function isFullscreenActive(doc: FullscreenDocument): boolean {
  return (doc.fullscreenElement ?? null) !== null;
}

/** Requests fullscreen on `target`, preferring the standard API. */
export function requestFullscreen(target: FullscreenTarget): Promise<void> | null {
  if (typeof target.requestFullscreen === 'function') return target.requestFullscreen();
  if (typeof target.webkitRequestFullscreen === 'function') return target.webkitRequestFullscreen();
  return null;
}

/** Exits fullscreen on `doc`, preferring the standard API. */
export function exitFullscreen(doc: FullscreenDocument): Promise<void> | null {
  if (typeof doc.exitFullscreen === 'function') return doc.exitFullscreen();
  if (typeof doc.webkitExitFullscreen === 'function') return doc.webkitExitFullscreen();
  return null;
}
