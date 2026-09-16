import { CameraConfig, CameraId } from '../models/camera-config';

/** Elements whose keystrokes belong to the user, never to a view shortcut. */
const TYPING_TAGS = new Set(['INPUT', 'TEXTAREA', 'SELECT']);

/**
 * Maps a keyboard key to the camera at that 1-based position in `cameras`.
 *
 * `cameras` is expected in display order (`CameraConfigService.ordered()`), so
 * key `1` is the first camera on screen — not `CAMERA_IDS[0]`. Keys outside
 * `1..9` and positions without a camera return `null` (no navigation).
 */
export function cameraIdForKey(key: string, cameras: readonly CameraConfig[]): CameraId | null {
  if (!/^[1-9]$/.test(key)) return null;
  return cameras[Number(key) - 1]?.id ?? null;
}

/**
 * True when the keyboard event belongs to a text field, so grid shortcuts must
 * stay inert (typing "1" in the rename editor must never open a camera).
 *
 * The nearest `contenteditable` ancestor wins, so an explicit
 * `contenteditable="false"` subtree counts as non-editing.
 */
export function isTypingTarget(target: EventTarget | null): boolean {
  if (!(target instanceof Element)) return false;
  if (TYPING_TAGS.has(target.tagName)) return true;

  const editable = target.closest('[contenteditable]');
  return editable !== null && editable.getAttribute('contenteditable') !== 'false';
}
