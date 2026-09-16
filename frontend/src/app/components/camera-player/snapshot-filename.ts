/** Fallback used when a name has no usable characters left after normalization. */
const FALLBACK_NAME = 'camara';

function pad(value: number, length = 2): string {
  return value.toString().padStart(length, '0');
}

function formatDate(date: Date): string {
  const day = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  const time = `${pad(date.getHours())}-${pad(date.getMinutes())}-${pad(date.getSeconds())}`;
  return `${day}_${time}`;
}

/**
 * Normalizes a camera name into a filesystem-safe slug.
 *
 * Scheme:
 * 1. Unicode NFD decomposition + strip combining diacritical marks,
 *    so "Cámara" -> "Camara" and "ñ" -> "n".
 * 2. Replace every run of whitespace with a single `-`.
 * 3. Drop every character outside `[A-Za-z0-9._-]` (removes accents left over,
 *    slashes, colons, quotes and other characters unsafe for filenames).
 * 4. Collapse repeated `-` and trim leading/trailing `-` / `.`.
 * 5. Fall back to `camara` when nothing usable remains.
 */
export function normalizeSnapshotName(name: string): string {
  const slug = name
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/\s+/g, '-')
    .replace(/[^A-Za-z0-9._-]/g, '')
    .replace(/-+/g, '-')
    .replace(/^[-.]+|[-.]+$/g, '');

  return slug.length > 0 ? slug : FALLBACK_NAME;
}

/**
 * Builds a JPEG snapshot filename: `{normalized-name}_{YYYY-MM-DD_HH-mm-ss}.jpg`.
 * The timestamp is in local time and every component is zero-padded.
 */
export function buildSnapshotFilename(name: string, date: Date): string {
  return `${normalizeSnapshotName(name)}_${formatDate(date)}.jpg`;
}
