import { CAMERA_IDS, resolveCameraId } from './camera-config';

describe('resolveCameraId', () => {
  it('resolves every configured camera id', () => {
    expect(CAMERA_IDS.map((id) => resolveCameraId(id))).toEqual([...CAMERA_IDS]);
  });

  it('rejects an id that is not one of the four configured cameras', () => {
    expect(resolveCameraId('nope')).toBeNull();
    expect(resolveCameraId('cam5')).toBeNull();
    expect(resolveCameraId('')).toBeNull();
    expect(resolveCameraId(null)).toBeNull();
  });

  it('is exact: ids are case-sensitive and never trimmed', () => {
    expect(resolveCameraId('CAM2')).toBeNull();
    expect(resolveCameraId(' cam2 ')).toBeNull();
    expect(resolveCameraId('cam1,cam2')).toBeNull();
  });
});
