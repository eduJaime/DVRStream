import { CAMERA_IDS, CameraConfig, CameraId } from '../models/camera-config';

/** localStorage key for the persisted camera names and order. */
export const CAMERA_CONFIG_STORAGE_KEY = 'visor-camaras.config.v1';

export const CAMERA_NAME_MIN_LENGTH = 1;
export const CAMERA_NAME_MAX_LENGTH = 30;

/** Builds the default configuration: `Cámara 1..4`, order `0..3`. */
export function defaultCameraConfig(): CameraConfig[] {
  return CAMERA_IDS.map((id, index) => ({
    id,
    name: `Cámara ${index + 1}`,
    order: index,
  }));
}

/**
 * Normalizes a user-provided camera name.
 * Returns the trimmed name when valid (1..30 chars), or `null` when invalid.
 */
export function normalizeCameraName(raw: string): string | null {
  if (typeof raw !== 'string') return null;

  const name = raw.trim();
  if (name.length < CAMERA_NAME_MIN_LENGTH || name.length > CAMERA_NAME_MAX_LENGTH) {
    return null;
  }

  return name;
}

function isCameraId(value: unknown): value is CameraId {
  return typeof value === 'string' && (CAMERA_IDS as readonly string[]).includes(value);
}

function isValidOrder(value: unknown): value is number {
  return (
    typeof value === 'number' && Number.isInteger(value) && value >= 0 && value < CAMERA_IDS.length
  );
}

/**
 * Validates a raw `localStorage` value and returns a safe config.
 *
 * The parsed value must be an array of entries, each with a known `id`, a
 * non-empty `name` (1..30 chars) and a unique integer `order` in `0..3`.
 * Duplicated ids keep the first occurrence and drop the rest; afterwards the
 * result is re-validated so the four camera ids are present exactly once.
 *
 * Any other deviation (invalid JSON, wrong shape, an id missing after
 * deduplication, an invalid name, an unknown id, or duplicated/out-of-range
 * orders) falls back to the defaults.
 *
 * This function is pure so it can be unit-tested without Angular TestBed.
 */
export function parseStoredConfig(raw: string | null): CameraConfig[] {
  if (typeof raw !== 'string' || raw.length === 0) return defaultCameraConfig();

  let data: unknown;
  try {
    data = JSON.parse(raw);
  } catch {
    return defaultCameraConfig();
  }

  if (!Array.isArray(data)) return defaultCameraConfig();

  const seenIds = new Set<CameraId>();
  const seenOrders = new Set<number>();
  const result: CameraConfig[] = [];

  for (const entry of data) {
    if (typeof entry !== 'object' || entry === null) return defaultCameraConfig();

    const { id, name, order } = entry as Record<string, unknown>;

    if (!isCameraId(id)) return defaultCameraConfig();
    // First occurrence wins; later entries with the same id are dropped whole.
    if (seenIds.has(id)) continue;
    if (typeof name !== 'string' || normalizeCameraName(name) === null)
      return defaultCameraConfig();
    if (!isValidOrder(order) || seenOrders.has(order)) return defaultCameraConfig();

    seenIds.add(id);
    seenOrders.add(order);
    result.push({ id, name: (name as string).trim(), order });
  }

  if (result.length !== CAMERA_IDS.length) return defaultCameraConfig();

  return result.sort((a, b) => a.order - b.order);
}
