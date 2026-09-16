import { CameraConfig } from '../models/camera-config';
import {
  defaultCameraConfig,
  normalizeCameraName,
  parseStoredConfig,
} from './camera-config.parser';

const DEFAULTS = defaultCameraConfig();

function validConfig(): CameraConfig[] {
  return [
    { id: 'cam1', name: 'Entrada', order: 0 },
    { id: 'cam2', name: 'Patio', order: 1 },
    { id: 'cam3', name: 'Garage', order: 2 },
    { id: 'cam4', name: 'Fondo', order: 3 },
  ];
}

describe('defaultCameraConfig', () => {
  it('returns Cámara 1..4 with order 0..3', () => {
    expect(DEFAULTS.map((c) => c.id)).toEqual(['cam1', 'cam2', 'cam3', 'cam4']);
    expect(DEFAULTS.map((c) => c.name)).toEqual(['Cámara 1', 'Cámara 2', 'Cámara 3', 'Cámara 4']);
    expect(DEFAULTS.map((c) => c.order)).toEqual([0, 1, 2, 3]);
  });
});

describe('normalizeCameraName', () => {
  it('trims valid names', () => {
    expect(normalizeCameraName('  Entrada  ')).toBe('Entrada');
  });

  it('rejects empty names', () => {
    expect(normalizeCameraName('')).toBeNull();
    expect(normalizeCameraName('   ')).toBeNull();
  });

  it('rejects names longer than 30 characters', () => {
    expect(normalizeCameraName('a'.repeat(30))).toBe('a'.repeat(30));
    expect(normalizeCameraName('a'.repeat(31))).toBeNull();
  });
});

describe('parseStoredConfig', () => {
  it('falls back to defaults for missing or empty input', () => {
    expect(parseStoredConfig(null)).toEqual(DEFAULTS);
    expect(parseStoredConfig('')).toEqual(DEFAULTS);
  });

  it('falls back to defaults for corrupt JSON', () => {
    expect(parseStoredConfig('{not json')).toEqual(DEFAULTS);
    expect(parseStoredConfig('42')).toEqual(DEFAULTS);
    expect(parseStoredConfig('{"id":"cam1"}')).toEqual(DEFAULTS);
  });

  it('parses a valid config and sorts by order', () => {
    const shuffled = [...validConfig()].reverse();
    expect(parseStoredConfig(JSON.stringify(shuffled))).toEqual(validConfig());
  });

  it('rejects a config with a missing id', () => {
    const config = validConfig().slice(0, 3);
    expect(parseStoredConfig(JSON.stringify(config))).toEqual(DEFAULTS);
  });

  it('falls back to defaults when dropping duplicate ids leaves an id missing', () => {
    const config = validConfig().map((c) => (c.id === 'cam4' ? { ...c, id: 'cam1' } : c));
    expect(parseStoredConfig(JSON.stringify(config))).toEqual(DEFAULTS);
  });

  it('keeps the first occurrence of a duplicated id and drops the rest', () => {
    const stored = [
      { id: 'cam1', name: 'Entrada', order: 3 },
      { id: 'cam4', name: 'Fondo', order: 0 },
      { id: 'cam1', name: 'Duplicada', order: 1 },
      { id: 'cam2', name: 'Patio', order: 2 },
      { id: 'cam3', name: 'Garage', order: 1 },
    ];

    expect(parseStoredConfig(JSON.stringify(stored))).toEqual([
      { id: 'cam4', name: 'Fondo', order: 0 },
      { id: 'cam3', name: 'Garage', order: 1 },
      { id: 'cam2', name: 'Patio', order: 2 },
      { id: 'cam1', name: 'Entrada', order: 3 },
    ]);
  });

  it('drops an extra duplicate entry and revalidates the four unique cameras', () => {
    const stored = [...validConfig(), { id: 'cam1', name: 'Extra', order: 1 }];
    expect(parseStoredConfig(JSON.stringify(stored))).toEqual(validConfig());
  });

  it('does not let a corrupt duplicate entry poison the config', () => {
    const stored = [...validConfig(), { id: 'cam1', name: 'x'.repeat(200), order: 99 }];
    expect(parseStoredConfig(JSON.stringify(stored))).toEqual(validConfig());
  });

  it('rejects duplicated or out-of-range order values', () => {
    const duplicated = validConfig().map((c) => (c.id === 'cam2' ? { ...c, order: 0 } : c));
    expect(parseStoredConfig(JSON.stringify(duplicated))).toEqual(DEFAULTS);

    const outOfRange = validConfig().map((c) => (c.id === 'cam1' ? { ...c, order: 4 } : c));
    expect(parseStoredConfig(JSON.stringify(outOfRange))).toEqual(DEFAULTS);
  });

  it('rejects invalid entries and names', () => {
    const wrongShape = [null, ...validConfig().slice(1)];
    expect(parseStoredConfig(JSON.stringify(wrongShape))).toEqual(DEFAULTS);

    const emptyName = validConfig().map((c) => (c.id === 'cam3' ? { ...c, name: '   ' } : c));
    expect(parseStoredConfig(JSON.stringify(emptyName))).toEqual(DEFAULTS);

    const longName = validConfig().map((c) =>
      c.id === 'cam2' ? { ...c, name: 'x'.repeat(31) } : c,
    );
    expect(parseStoredConfig(JSON.stringify(longName))).toEqual(DEFAULTS);
  });

  it('falls back to defaults when an extra entry has an unknown id', () => {
    const extra = [...validConfig(), { id: 'cam5', name: 'Extra', order: 4 }];
    expect(parseStoredConfig(JSON.stringify(extra))).toEqual(DEFAULTS);
  });
});
