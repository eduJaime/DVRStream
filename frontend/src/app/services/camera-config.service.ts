import { Injectable, Signal, computed, signal } from '@angular/core';
import { CameraConfig, CameraId } from '../models/camera-config';
import {
  CAMERA_CONFIG_STORAGE_KEY,
  defaultCameraConfig,
  normalizeCameraName,
  parseStoredConfig,
} from './camera-config.parser';

@Injectable({ providedIn: 'root' })
export class CameraConfigService {
  private readonly configSignal = signal<CameraConfig[]>(this.load());

  /** Read-only source of truth, in stored order. */
  readonly config: Signal<CameraConfig[]> = this.configSignal.asReadonly();

  /** Cameras sorted by their `order` value (grid order). */
  readonly ordered: Signal<CameraConfig[]> = computed(() =>
    [...this.configSignal()].sort((a, b) => a.order - b.order),
  );

  /**
   * Renames a camera and persists the change.
   *
   * Invalid names (empty, all-whitespace or longer than 30 chars) are rejected:
   * the previous name is kept, nothing is persisted and `false` is returned so
   * the caller can surface an inline error. The name is never truncated.
   */
  rename(id: CameraId, name: string): boolean {
    const normalized = normalizeCameraName(name);
    if (normalized === null) return false;

    this.persist(
      this.configSignal().map((camera) =>
        camera.id === id ? { ...camera, name: normalized } : camera,
      ),
    );
    return true;
  }

  /** Moves the camera at `fromIndex` to `toIndex` and renumbers `order`. */
  reorder(fromIndex: number, toIndex: number): void {
    const current = [...this.configSignal()].sort((a, b) => a.order - b.order);

    if (!this.isValidIndex(fromIndex) || !this.isValidIndex(toIndex) || fromIndex === toIndex) {
      return;
    }

    const [moved] = current.splice(fromIndex, 1);
    current.splice(toIndex, 0, moved);

    this.persist(current.map((camera, index) => ({ ...camera, order: index })));
  }

  /** Restores the default names and order and persists them. */
  reset(): void {
    this.persist(defaultCameraConfig());
  }

  private load(): CameraConfig[] {
    try {
      return parseStoredConfig(localStorage.getItem(CAMERA_CONFIG_STORAGE_KEY));
    } catch {
      // localStorage can be unavailable (private mode, disabled storage).
      return defaultCameraConfig();
    }
  }

  private persist(next: CameraConfig[]): void {
    this.configSignal.set(next);
    try {
      localStorage.setItem(CAMERA_CONFIG_STORAGE_KEY, JSON.stringify(next));
    } catch {
      // In-memory state stays valid even when persistence fails.
    }
  }

  private isValidIndex(index: number): boolean {
    return Number.isInteger(index) && index >= 0 && index < this.configSignal().length;
  }
}
