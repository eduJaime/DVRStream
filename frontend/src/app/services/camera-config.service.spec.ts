import { CAMERA_CONFIG_STORAGE_KEY, defaultCameraConfig } from './camera-config.parser';
import { CameraConfigService } from './camera-config.service';

const DEFAULTS = defaultCameraConfig();

function ids(service: CameraConfigService): string[] {
  return service.ordered().map((camera) => camera.id);
}

describe('CameraConfigService', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('starts with the defaults when storage is empty', () => {
    const service = new CameraConfigService();
    expect(service.config()).toEqual(DEFAULTS);
  });

  it('persists and reloads renamed cameras', () => {
    const service = new CameraConfigService();
    service.rename('cam2', '  Patio  ');

    expect(service.config().find((c) => c.id === 'cam2')?.name).toBe('Patio');

    const reloaded = new CameraConfigService();
    expect(reloaded.config().find((c) => c.id === 'cam2')?.name).toBe('Patio');
  });

  it('rejects invalid names without changing state', () => {
    const service = new CameraConfigService();
    expect(service.rename('cam1', '')).toBe(false);
    expect(service.rename('cam1', '   ')).toBe(false);
    expect(service.rename('cam1', 'x'.repeat(31))).toBe(false);

    expect(service.config()).toEqual(DEFAULTS);
  });

  it('reports acceptance of a valid rename', () => {
    const service = new CameraConfigService();
    expect(service.rename('cam2', '  Patio  ')).toBe(true);
    expect(service.config().find((c) => c.id === 'cam2')?.name).toBe('Patio');
  });

  it('rejects invalid names without persisting and keeps the previous name', () => {
    const service = new CameraConfigService();
    service.rename('cam1', 'Entrada');

    const setSpy = vi.spyOn(localStorage, 'setItem');
    expect(service.rename('cam1', '   ')).toBe(false);
    expect(service.rename('cam1', 'x'.repeat(31))).toBe(false);

    expect(setSpy).not.toHaveBeenCalled();
    expect(service.config().find((c) => c.id === 'cam1')?.name).toBe('Entrada');
    expect(new CameraConfigService().config().find((c) => c.id === 'cam1')?.name).toBe('Entrada');
  });

  it('never truncates an over-length name', () => {
    const service = new CameraConfigService();
    expect(service.rename('cam1', 'x'.repeat(45))).toBe(false);
    expect(service.config().find((c) => c.id === 'cam1')?.name).toBe('Cámara 1');
  });

  it('reorders cameras and renumbers order values', () => {
    const service = new CameraConfigService();
    service.reorder(0, 2);

    expect(ids(service)).toEqual(['cam2', 'cam3', 'cam1', 'cam4']);
    expect(service.ordered().map((c) => c.order)).toEqual([0, 1, 2, 3]);
  });

  it('ignores out-of-range reorder requests', () => {
    const service = new CameraConfigService();
    service.reorder(-1, 2);
    service.reorder(0, 9);
    service.reorder(1, 1);

    expect(ids(service)).toEqual(['cam1', 'cam2', 'cam3', 'cam4']);
  });

  it('resets back to the defaults and persists them', () => {
    const service = new CameraConfigService();
    service.rename('cam1', 'Entrada');
    service.reorder(0, 3);
    service.reset();

    expect(service.config()).toEqual(DEFAULTS);
    expect(new CameraConfigService().config()).toEqual(DEFAULTS);
  });

  it('falls back to defaults without throwing on corrupt storage', () => {
    localStorage.setItem(CAMERA_CONFIG_STORAGE_KEY, '{ not valid json');
    const service = new CameraConfigService();
    expect(service.config()).toEqual(DEFAULTS);
  });
});
