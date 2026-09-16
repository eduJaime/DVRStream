import { DownloadHost, downloadBlob } from './download-blob';

function restoreStatic(
  target: typeof URL,
  key: 'createObjectURL' | 'revokeObjectURL',
  original: unknown,
): void {
  if (original === undefined) {
    delete (target as unknown as Record<string, unknown>)[key];
  } else {
    Object.defineProperty(target, key, { value: original, configurable: true, writable: true });
  }
}

describe('downloadBlob', () => {
  it('creates an object URL, clicks the download and revokes the URL', () => {
    const calls: string[] = [];
    const host: DownloadHost = {
      createObjectUrl: (blob) => {
        calls.push(`create:${blob.size}`);
        return 'blob:first';
      },
      clickDownload: (url, filename) => calls.push(`click:${url}:${filename}`),
      revokeObjectUrl: (url) => calls.push(`revoke:${url}`),
    };

    downloadBlob(new Blob(['frame']), 'Camara-1_2026-09-15_10-20-30.jpg', host);

    expect(calls).toEqual([
      'create:5',
      'click:blob:first:Camara-1_2026-09-15_10-20-30.jpg',
      'revoke:blob:first',
    ]);
  });

  it('passes the blob and filename straight through to the host', () => {
    const blob = new Blob(['second frame'], { type: 'image/jpeg' });
    const createObjectUrl = vi.fn(() => 'blob:second');
    const clickDownload = vi.fn();
    const revokeObjectUrl = vi.fn();

    downloadBlob(blob, 'Patio_2026-01-02_03-04-05.jpg', {
      createObjectUrl,
      clickDownload,
      revokeObjectUrl,
    });

    expect(createObjectUrl).toHaveBeenCalledWith(blob);
    expect(clickDownload).toHaveBeenCalledWith('blob:second', 'Patio_2026-01-02_03-04-05.jpg');
    expect(revokeObjectUrl).toHaveBeenCalledWith('blob:second');
  });

  it('revokes the object URL when triggering the download throws', () => {
    const revoked: string[] = [];
    const host: DownloadHost = {
      createObjectUrl: () => 'blob:broken',
      clickDownload: () => {
        throw new Error('download blocked');
      },
      revokeObjectUrl: (url) => void revoked.push(url),
    };

    expect(() => downloadBlob(new Blob(['x']), 'x.jpg', host)).toThrow('download blocked');
    expect(revoked).toEqual(['blob:broken']);
  });

  describe('browser host', () => {
    let originalCreate: unknown;
    let originalRevoke: unknown;
    let createSpy: ReturnType<typeof vi.fn>;
    let revokeSpy: ReturnType<typeof vi.fn>;

    beforeEach(() => {
      originalCreate = URL.createObjectURL;
      originalRevoke = URL.revokeObjectURL;
      createSpy = vi.fn(() => 'blob:real');
      revokeSpy = vi.fn();
      // jsdom does not implement the object-URL API; provide it for this suite
      // so the default host's delegation can be exercised.
      Object.defineProperty(URL, 'createObjectURL', {
        value: createSpy,
        configurable: true,
        writable: true,
      });
      Object.defineProperty(URL, 'revokeObjectURL', {
        value: revokeSpy,
        configurable: true,
        writable: true,
      });
    });

    afterEach(() => {
      restoreStatic(URL, 'createObjectURL', originalCreate);
      restoreStatic(URL, 'revokeObjectURL', originalRevoke);
      vi.restoreAllMocks();
    });

    it('downloads through a temporary anchor that is removed afterwards', () => {
      const blob = new Blob(['frame'], { type: 'image/jpeg' });
      let clicked: { href: string; download: string; attached: boolean } | null = null;
      const clickSpy = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function (
        this: HTMLAnchorElement,
      ): void {
        clicked = {
          href: this.href,
          download: this.download,
          attached: document.body.contains(this),
        };
      });

      downloadBlob(blob, 'Camara-1_2026-09-15_10-20-30.jpg');

      expect(createSpy).toHaveBeenCalledWith(blob);
      expect(clickSpy).toHaveBeenCalledTimes(1);
      expect(clicked).toEqual({
        href: 'blob:real',
        download: 'Camara-1_2026-09-15_10-20-30.jpg',
        attached: true,
      });
      expect(revokeSpy).toHaveBeenCalledWith('blob:real');
      expect(document.querySelector('a')).toBeNull();
    });
  });
});
