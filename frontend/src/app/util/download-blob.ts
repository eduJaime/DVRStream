/**
 * The browser surface a download needs, injected so the wiring
 * (create object URL -> click `<a download>` -> revoke) is testable without a
 * real browser download. The views own the download: they build the filename
 * with `buildSnapshotFilename` and hand the blob to `downloadBlob`.
 */
export interface DownloadHost {
  createObjectUrl(blob: Blob): string;
  revokeObjectUrl(url: string): void;
  clickDownload(url: string, filename: string): void;
}

/** Default host: real object URLs plus a temporary `<a download>` click. */
export const browserDownloadHost: DownloadHost = {
  createObjectUrl: (blob) => URL.createObjectURL(blob),
  revokeObjectUrl: (url) => URL.revokeObjectURL(url),
  clickDownload: (url, filename) => {
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = filename;
    anchor.rel = 'noopener';
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
  },
};

/**
 * Triggers a file download for `blob` under `filename`.
 *
 * The object URL is always revoked, even when the click itself fails, so a
 * failed download cannot leak a blob URL.
 */
export function downloadBlob(
  blob: Blob,
  filename: string,
  host: DownloadHost = browserDownloadHost,
): void {
  const url = host.createObjectUrl(blob);
  try {
    host.clickDownload(url, filename);
  } finally {
    host.revokeObjectUrl(url);
  }
}
