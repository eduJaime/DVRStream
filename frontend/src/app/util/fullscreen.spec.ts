import {
  FullscreenDocument,
  FullscreenTarget,
  detectFullscreenSupport,
  exitFullscreen,
  isFullscreenActive,
  requestFullscreen,
} from './fullscreen';

function fakeTarget(overrides: FullscreenTarget = {}): FullscreenTarget {
  return { ...overrides };
}

function fakeDocument(overrides: Partial<FullscreenDocument> = {}): FullscreenDocument {
  return {
    fullscreenEnabled: true,
    fullscreenElement: null,
    documentElement: fakeTarget({ requestFullscreen: () => Promise.resolve() }),
    exitFullscreen: () => Promise.resolve(),
    ...overrides,
  };
}

describe('detectFullscreenSupport', () => {
  it('accepts the standard API (fullscreenEnabled + requestFullscreen)', () => {
    const doc = fakeDocument();

    expect(detectFullscreenSupport(doc, doc.documentElement)).toBe(true);
  });

  it('accepts the webkit-prefixed API', () => {
    const doc = fakeDocument({
      documentElement: fakeTarget({ webkitRequestFullscreen: () => Promise.resolve() }),
    });

    expect(detectFullscreenSupport(doc, doc.documentElement)).toBe(true);
  });

  it('rejects a document where fullscreen is disabled, even with the API present', () => {
    const doc = fakeDocument({ fullscreenEnabled: false });

    expect(detectFullscreenSupport(doc, doc.documentElement)).toBe(false);
  });

  it('rejects a document without fullscreenEnabled (jsdom and non-supporting browsers)', () => {
    const doc = fakeDocument({ fullscreenEnabled: undefined });

    expect(detectFullscreenSupport(doc, doc.documentElement)).toBe(false);
  });

  it('rejects an element without a fullscreen request method', () => {
    const doc = fakeDocument();

    expect(detectFullscreenSupport(doc, fakeTarget())).toBe(false);
  });

  it('checks the given target, not the document element', () => {
    const doc = fakeDocument();

    // Capable documentElement, incapable target: the single view goes
    // fullscreen through its own host element, so that is what must count.
    expect(detectFullscreenSupport(doc, fakeTarget())).toBe(false);

    const capable = fakeTarget({ webkitRequestFullscreen: () => Promise.resolve() });
    expect(detectFullscreenSupport(doc, capable)).toBe(true);
  });

  it('reports the real jsdom document as unsupported', () => {
    // jsdom implements no Fullscreen API at all: this is the in-test default
    // and the reason detection takes the document/element as parameters.
    expect(detectFullscreenSupport(document as unknown as FullscreenDocument)).toBe(false);
  });
});

describe('isFullscreenActive', () => {
  it('is false when no element is fullscreen', () => {
    expect(isFullscreenActive(fakeDocument())).toBe(false);
  });

  it('is false when the document does not expose fullscreenElement', () => {
    expect(isFullscreenActive(fakeDocument({ fullscreenElement: undefined }))).toBe(false);
  });

  it('is true while an element is fullscreen', () => {
    const doc = fakeDocument({ fullscreenElement: document.createElement('div') });

    expect(isFullscreenActive(doc)).toBe(true);
  });
});

describe('requestFullscreen', () => {
  it('returns the promise from the standard API', () => {
    const promise = Promise.resolve();
    const request = vi.fn(() => promise);

    expect(requestFullscreen(fakeTarget({ requestFullscreen: request }))).toBe(promise);
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('falls back to the webkit-prefixed API', () => {
    const promise = Promise.resolve();
    const request = vi.fn(() => promise);

    expect(requestFullscreen(fakeTarget({ webkitRequestFullscreen: request }))).toBe(promise);
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('returns null when the element cannot go fullscreen', () => {
    expect(requestFullscreen(fakeTarget())).toBeNull();
  });
});

describe('exitFullscreen', () => {
  it('returns the promise from the standard API', () => {
    const promise = Promise.resolve();
    const exit = vi.fn(() => promise);

    expect(exitFullscreen(fakeDocument({ exitFullscreen: exit }))).toBe(promise);
    expect(exit).toHaveBeenCalledTimes(1);
  });

  it('falls back to the webkit-prefixed API', () => {
    const promise = Promise.resolve();
    const exit = vi.fn(() => promise);

    expect(
      exitFullscreen(fakeDocument({ exitFullscreen: undefined, webkitExitFullscreen: exit })),
    ).toBe(promise);
    expect(exit).toHaveBeenCalledTimes(1);
  });

  it('returns null when the document cannot exit fullscreen', () => {
    expect(
      exitFullscreen(fakeDocument({ exitFullscreen: undefined, webkitExitFullscreen: undefined })),
    ).toBeNull();
  });
});
