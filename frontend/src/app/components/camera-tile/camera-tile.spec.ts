import { ComponentFixture, TestBed } from '@angular/core/testing';
import { By } from '@angular/platform-browser';
import { CameraConfig } from '../../models/camera-config';
import { CameraConfigService } from '../../services/camera-config.service';
import { ToastService } from '../../services/toast.service';
import { CameraPlayerComponent } from '../camera-player/camera-player';
import { buildSnapshotFilename } from '../camera-player/snapshot-filename';
import { CameraTileComponent, RENAME_ERROR_MESSAGE } from './camera-tile';

const CAMERA: CameraConfig = { id: 'cam1', name: 'Cámara 1', order: 0 };

interface CapturedDownload {
  href: string;
  filename: string;
}

function restoreUrlStatic(key: 'createObjectURL' | 'revokeObjectURL', original: unknown): void {
  if (original === undefined) {
    delete (URL as unknown as Record<string, unknown>)[key];
  } else {
    Object.defineProperty(URL, key, { value: original, configurable: true, writable: true });
  }
}

describe('CameraTileComponent', () => {
  let fixture: ComponentFixture<CameraTileComponent>;
  let config: CameraConfigService;
  let toast: ToastService;
  let opened: string[];
  let downloaded: CapturedDownload | null;
  let revoked: string[];
  let originalCreateUrl: unknown;
  let originalRevokeUrl: unknown;

  function tile(): HTMLElement {
    return fixture.nativeElement.querySelector('.tile') as HTMLElement;
  }

  function playerHost(): HTMLElement {
    return fixture.nativeElement.querySelector('app-camera-player') as HTMLElement;
  }

  function button(labelPrefix: string): HTMLButtonElement {
    const buttons = Array.from(
      fixture.nativeElement.querySelectorAll('button'),
    ) as HTMLButtonElement[];
    const match = buttons.find((b) => (b.getAttribute('aria-label') ?? '').startsWith(labelPrefix));
    expect(match, `button labelled "${labelPrefix}"`).toBeDefined();
    return match!;
  }

  function nameInput(): HTMLInputElement | null {
    return fixture.nativeElement.querySelector('.tile__input');
  }

  function errorText(): string | null {
    const alert = fixture.nativeElement.querySelector('.tile__error') as HTMLElement | null;
    return alert?.textContent?.trim() ?? null;
  }

  async function openRenameEditor(): Promise<HTMLInputElement> {
    fixture.detectChanges();
    button('Renombrar').click();
    fixture.detectChanges();
    await fixture.whenStable();
    fixture.detectChanges();
    const input = nameInput();
    expect(input).not.toBeNull();
    return input!;
  }

  async function pressEnter(input: HTMLInputElement): Promise<void> {
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    fixture.detectChanges();
    await fixture.whenStable();
    fixture.detectChanges();
  }

  beforeEach(async () => {
    localStorage.clear();

    // jsdom has no object-URL API and no download: stub the object URL and
    // capture the anchor the helper clicks, so the download contract is real.
    originalCreateUrl = URL.createObjectURL;
    originalRevokeUrl = URL.revokeObjectURL;
    downloaded = null;
    revoked = [];
    Object.defineProperty(URL, 'createObjectURL', {
      value: () => 'blob:snapshot',
      configurable: true,
      writable: true,
    });
    Object.defineProperty(URL, 'revokeObjectURL', {
      value: (url: string) => void revoked.push(url),
      configurable: true,
      writable: true,
    });
    vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function (
      this: HTMLAnchorElement,
    ): void {
      downloaded = { href: this.href, filename: this.download };
    });

    await TestBed.configureTestingModule({
      imports: [CameraTileComponent],
    }).compileComponents();

    fixture = TestBed.createComponent(CameraTileComponent);
    fixture.componentRef.setInput('camera', CAMERA);
    config = TestBed.inject(CameraConfigService);
    toast = TestBed.inject(ToastService);
    opened = [];
    fixture.componentInstance.open.subscribe((id) => opened.push(id));
  });

  afterEach(() => {
    fixture.destroy();
    restoreUrlStatic('createObjectURL', originalCreateUrl);
    restoreUrlStatic('revokeObjectURL', originalRevokeUrl);
    vi.restoreAllMocks();
    vi.useRealTimers();
  });

  it('renders the camera name and the video player for the camera', () => {
    fixture.detectChanges();

    const name = fixture.nativeElement.querySelector('.tile__name') as HTMLElement;
    expect(name.textContent?.trim()).toBe('Cámara 1');

    const player = fixture.debugElement.query(By.directive(CameraPlayerComponent))
      .componentInstance as CameraPlayerComponent;
    expect(player.cameraId).toBe('cam1');
  });

  it('renders Ampliar, Snapshot, Renombrar and a reorder grip in the DOM', () => {
    fixture.detectChanges();

    expect(button('Ampliar')).toBeTruthy();
    expect(button('Snapshot')).toBeTruthy();
    expect(button('Renombrar')).toBeTruthy();
    expect(button('Reordenar').hasAttribute('cdkDragHandle')).toBe(true);
  });

  it('opens the single view through the explicit Ampliar control', () => {
    fixture.detectChanges();

    button('Ampliar').click();
    fixture.detectChanges();

    expect(opened).toEqual(['cam1']);
  });

  it('does not open the single view on a single tap of the video surface (TD-1)', () => {
    fixture.detectChanges();

    playerHost().dispatchEvent(new MouseEvent('click', { bubbles: true }));
    tile().dispatchEvent(new MouseEvent('click', { bubbles: true }));

    expect(opened).toEqual([]);
  });

  it('opens the single view on a double-click on the cell body', () => {
    fixture.detectChanges();

    playerHost().dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));

    expect(opened).toEqual(['cam1']);
  });

  it('does not open the single view when the name is double-clicked to rename', async () => {
    fixture.detectChanges();
    const name = fixture.nativeElement.querySelector('.tile__name') as HTMLElement;

    name.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
    fixture.detectChanges();
    await fixture.whenStable();
    fixture.detectChanges();

    expect(opened).toEqual([]);
    expect(nameInput()).not.toBeNull();
  });

  it('does not open the single view when the name editor is double-clicked', async () => {
    const input = await openRenameEditor();

    input.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
    fixture.detectChanges();

    expect(opened).toEqual([]);
  });

  it('focuses and selects the current name when the editor opens', async () => {
    const input = await openRenameEditor();

    expect(document.activeElement).toBe(input);
    expect(input.selectionStart).toBe(0);
    expect(input.selectionEnd).toBe(CAMERA.name.length);
  });

  it('saves the trimmed name on Enter and keeps the editor closed', async () => {
    const input = await openRenameEditor();
    input.value = '  Patio  ';

    await pressEnter(input);

    expect(nameInput()).toBeNull();
    expect(config.config().find((c) => c.id === 'cam1')?.name).toBe('Patio');
    // The editor closes and the name overlay is rendered again; the grid owns
    // re-rendering the new name from its `ordered()` source.
    expect(fixture.nativeElement.querySelector('.tile__name')).not.toBeNull();
  });

  it('discards the edit on Escape', async () => {
    const input = await openRenameEditor();
    input.value = 'Otro nombre';

    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    fixture.detectChanges();
    await fixture.whenStable();

    expect(nameInput()).toBeNull();
    expect(config.config().find((c) => c.id === 'cam1')?.name).toBe('Cámara 1');
  });

  it('rejects an all-whitespace name with an inline error and keeps the previous name', async () => {
    const input = await openRenameEditor();
    input.value = '   ';

    await pressEnter(input);

    expect(errorText()).toBe(RENAME_ERROR_MESSAGE);
    expect(nameInput()).not.toBeNull();
    expect(config.config().find((c) => c.id === 'cam1')?.name).toBe('Cámara 1');
  });

  it('rejects an over-length name with an inline error and never truncates it', async () => {
    const input = await openRenameEditor();
    input.value = 'x'.repeat(45);

    await pressEnter(input);

    expect(errorText()).toBe(RENAME_ERROR_MESSAGE);
    expect(nameInput()?.value).toBe('x'.repeat(45));
    expect(config.config().find((c) => c.id === 'cam1')?.name).toBe('Cámara 1');
  });

  it('clears the inline error once a valid name is saved', async () => {
    const input = await openRenameEditor();
    input.value = '   ';
    await pressEnter(input);
    expect(errorText()).toBe(RENAME_ERROR_MESSAGE);

    const reopened = nameInput()!;
    reopened.value = 'Patio';
    await pressEnter(reopened);

    expect(nameInput()).toBeNull();
    expect(errorText()).toBeNull();
    expect(config.config().find((c) => c.id === 'cam1')?.name).toBe('Patio');
  });

  it('saves and discards through the explicit editor buttons', async () => {
    const input = await openRenameEditor();
    input.value = 'Patio';
    button('Guardar').click();
    fixture.detectChanges();
    await fixture.whenStable();
    expect(config.config().find((c) => c.id === 'cam1')?.name).toBe('Patio');

    const reopened = await openRenameEditor();
    reopened.value = 'Descartado';
    button('Cancelar').click();
    fixture.detectChanges();

    expect(nameInput()).toBeNull();
    expect(config.config().find((c) => c.id === 'cam1')?.name).toBe('Patio');
  });

  it('downloads the snapshot with the timestamped filename and confirms it', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-09-15T10:20:30'));
    const blob = new Blob(['frame'], { type: 'image/jpeg' });
    vi.spyOn(CameraPlayerComponent.prototype, 'snapshot').mockResolvedValue(blob);
    fixture.detectChanges();

    button('Snapshot').click();
    await fixture.whenStable();

    expect(downloaded).toEqual({
      href: 'blob:snapshot',
      filename: buildSnapshotFilename(CAMERA.name, new Date('2026-09-15T10:20:30')),
    });
    expect(revoked).toEqual(['blob:snapshot']);
    expect(toast.message()).toEqual({ text: 'Captura guardada', tone: 'info' });
  });

  it('surfaces the not-ready message and downloads nothing when there is no frame', async () => {
    fixture.detectChanges();

    button('Snapshot').click();
    await fixture.whenStable();

    expect(downloaded).toBeNull();
    expect(toast.message()).toEqual({
      text: 'La cámara todavía no está lista',
      tone: 'error',
    });
  });

  it('renders the grip as a non-tabbable control while the cell body is not draggable', () => {
    fixture.detectChanges();

    const grip = button('Reordenar');

    expect(grip.tagName).toBe('BUTTON');
    expect(grip.getAttribute('tabindex')).toBe('-1');
    expect(grip.getAttribute('aria-label')).toContain('Cámara 1');
    expect(tile().hasAttribute('cdkDrag')).toBe(false);
  });
});
