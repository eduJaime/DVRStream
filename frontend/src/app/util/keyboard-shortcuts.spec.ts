import { CameraConfig } from '../models/camera-config';
import { cameraIdForKey, isTypingTarget } from './keyboard-shortcuts';

/** Deliberately not in `cam1..cam4` order: position, not id, must decide. */
const ORDERED: CameraConfig[] = [
  { id: 'cam3', name: 'Portón', order: 0 },
  { id: 'cam1', name: 'Cámara 1', order: 1 },
  { id: 'cam4', name: 'Cámara 4', order: 2 },
  { id: 'cam2', name: 'Cámara 2', order: 3 },
];

describe('cameraIdForKey', () => {
  it('maps 1-4 to the camera at that position, not by id', () => {
    expect(cameraIdForKey('1', ORDERED)).toBe('cam3');
    expect(cameraIdForKey('2', ORDERED)).toBe('cam1');
    expect(cameraIdForKey('3', ORDERED)).toBe('cam4');
    expect(cameraIdForKey('4', ORDERED)).toBe('cam2');
  });

  it('returns null for keys outside the camera range', () => {
    expect(cameraIdForKey('0', ORDERED)).toBeNull();
    expect(cameraIdForKey('5', ORDERED)).toBeNull();
    expect(cameraIdForKey('', ORDERED)).toBeNull();
  });

  it('returns null for non-digit keys', () => {
    expect(cameraIdForKey('a', ORDERED)).toBeNull();
    expect(cameraIdForKey('ArrowLeft', ORDERED)).toBeNull();
    expect(cameraIdForKey('Enter', ORDERED)).toBeNull();
    expect(cameraIdForKey('11', ORDERED)).toBeNull();
  });

  it('returns null when no camera sits at that position', () => {
    expect(cameraIdForKey('2', [ORDERED[0]])).toBeNull();
    expect(cameraIdForKey('1', [])).toBeNull();
  });
});

describe('isTypingTarget', () => {
  it('is true for input and textarea elements', () => {
    expect(isTypingTarget(document.createElement('input'))).toBe(true);
    expect(isTypingTarget(document.createElement('textarea'))).toBe(true);
  });

  it('is true inside a contenteditable element', () => {
    const editable = document.createElement('div');
    editable.setAttribute('contenteditable', 'true');
    const child = document.createElement('span');
    editable.appendChild(child);

    expect(isTypingTarget(editable)).toBe(true);
    expect(isTypingTarget(child)).toBe(true);
  });

  it('is false for non-editing targets', () => {
    expect(isTypingTarget(document.createElement('div'))).toBe(false);
    expect(isTypingTarget(document.body)).toBe(false);
    expect(isTypingTarget(document)).toBe(false);
    expect(isTypingTarget(null)).toBe(false);
  });

  it('is false for an explicitly non-editable contenteditable subtree', () => {
    const wrapper = document.createElement('div');
    wrapper.setAttribute('contenteditable', 'true');
    const readonly = document.createElement('div');
    readonly.setAttribute('contenteditable', 'false');
    wrapper.appendChild(readonly);

    expect(isTypingTarget(readonly)).toBe(false);
  });
});
