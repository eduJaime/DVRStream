/**
 * Single source of truth for the four go2rtc stream ids.
 * The ids are immutable and map 1:1 to the `streams` keys in go2rtc.yaml;
 * only the visible names and the grid order are user-editable.
 */
export const CAMERA_IDS = ['cam1', 'cam2', 'cam3', 'cam4'] as const;

export type CameraId = (typeof CAMERA_IDS)[number];

export interface CameraConfig {
  id: CameraId;
  name: string;
  order: number;
}

/**
 * Resolves a raw route param to a configured camera id.
 *
 * Exact match only: an unknown id, an empty string or a missing param returns
 * `null`, so `cam/:id` can redirect to the grid instead of rendering a broken
 * view. Pure and TestBed-free (design D2).
 */
export function resolveCameraId(raw: string | null): CameraId | null {
  return CAMERA_IDS.find((id) => id === raw) ?? null;
}
