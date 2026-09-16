import { buildSnapshotFilename, normalizeSnapshotName } from './snapshot-filename';

describe('normalizeSnapshotName', () => {
  it('strips diacritics and replaces whitespace with a dash', () => {
    expect(normalizeSnapshotName('Cámara 1')).toBe('Camara-1');
    expect(normalizeSnapshotName('Portón N°2')).toBe('Porton-N2');
    expect(normalizeSnapshotName('ÁÉÍÓÚ')).toBe('AEIOU');
  });

  it('collapses whitespace runs and trims dashes', () => {
    expect(normalizeSnapshotName('  a   b  ')).toBe('a-b');
    expect(normalizeSnapshotName('a - b')).toBe('a-b');
    expect(normalizeSnapshotName('Cámara del Frente / Norte')).toBe('Camara-del-Frente-Norte');
  });

  it('removes characters unsafe for filenames', () => {
    expect(normalizeSnapshotName('a<b>c:d"e/f\\g|h?i*j')).toBe('abcdefghij');
  });

  it('falls back when nothing usable remains', () => {
    expect(normalizeSnapshotName('///')).toBe('camara');
    expect(normalizeSnapshotName('   ')).toBe('camara');
  });
});

describe('buildSnapshotFilename', () => {
  it('formats the date with zero padding', () => {
    const date = new Date(2026, 8, 15, 20, 30, 5);
    expect(buildSnapshotFilename('Cámara 1', date)).toBe('Camara-1_2026-09-15_20-30-05.jpg');
  });

  it('pads single digit components', () => {
    const date = new Date(2026, 0, 2, 3, 4, 5);
    expect(buildSnapshotFilename('Cam', date)).toBe('Cam_2026-01-02_03-04-05.jpg');
  });

  it('uses the fallback name together with the timestamp', () => {
    const date = new Date(2026, 11, 31, 23, 59, 59);
    expect(buildSnapshotFilename('***', date)).toBe('camara_2026-12-31_23-59-59.jpg');
  });
});
