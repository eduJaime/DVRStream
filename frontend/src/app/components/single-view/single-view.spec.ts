import { ComponentFixture, TestBed } from '@angular/core/testing';
import { By } from '@angular/platform-browser';
import {
  ActivatedRoute,
  ParamMap,
  Router,
  convertToParamMap,
  provideRouter,
} from '@angular/router';
import { BehaviorSubject } from 'rxjs';
import type { Mock, MockInstance } from 'vitest';

import { CameraConfigService } from '../../services/camera-config.service';
import { ToastService } from '../../services/toast.service';
import { FullscreenDocument } from '../../util/fullscreen';
import { CameraPlayerComponent } from '../camera-player/camera-player';
import { buildSnapshotFilename } from '../camera-player/snapshot-filename';
import {
  FULLSCREEN_DOCUMENT,
  FULLSCREEN_UNAVAILABLE_MESSAGE,
  SingleViewComponent,
} from './single-view';

interface FakeFullscreenDocument extends FullscreenDocument {
  fullscreenEnabled: boolean;
  fullscreenElement: Element | null;
  documentElement: HTMLElement;
  exitFullscreen: Mock;
  addEventListener: Mock;
  removeEventListener: Mock;
}

interface Harness {
  fixture: ComponentFixture<SingleViewComponent>;
  params: BehaviorSubject<ParamMap>;
  doc: FakeFullscreenDocument;
  router: Router;
  navigate: MockInstance;
  config: CameraConfigService;
  toast: ToastService;
  button: (text: string) => HTMLButtonElement;
  player: () => CameraPlayerComponent;
  cameraName: () => string;
}

interface CapturedDownload {
  href: string;
  filename: string;
}

function createFakeDocument(): FakeFullscreenDocument {
  return {
    fullscreenEnabled: false,
    fullscreenElement: null,
    documentElement: document.documentElement,
    exitFullscreen: vi.fn(() => Promise.resolve()),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  };
}

function restoreUrlStatic(key: 'createObjectURL' | 'revokeObjectURL', original: unknown): void {
  if (original === undefined) {
    delete (URL as unknown as Record<string, unknown>)[key];
  } else {
    Object.defineProperty(URL, key, { value: original, configurable: true, writable: true });
  }
}

describe('SingleViewComponent', () => {
  let harness: Harness;
  let originalRequestFullscreen: unknown;
  let originalCreateUrl: unknown;
  let originalRevokeUrl: unknown;
  let downloaded: CapturedDownload | null;
  let revoked: string[];

  function installRequestFullscreen(result: () => Promise<void>): Mock {
    const request = vi.fn(result);
    Object.defineProperty(Element.prototype, 'requestFullscreen', {
      value: request,
      configurable: true,
      writable: true,
    });
    return request;
  }

  function restoreRequestFullscreen(): void {
    const proto = Element.prototype as unknown as Record<string, unknown>;
    if (originalRequestFullscreen === undefined) delete proto['requestFullscreen'];
    else {
      Object.defineProperty(Element.prototype, 'requestFullscreen', {
        value: originalRequestFullscreen,
        configurable: true,
        writable: true,
      });
    }
  }

  function listenerFor(type: string): () => void {
    const call = (harness.doc.addEventListener as Mock).mock.calls.find(
      ([eventType]) => eventType === type,
    );
    expect(call, `listener registered for ${type}`).toBeDefined();
    return call![1] as () => void;
  }

  async function setup(options: {
    id?: string;
    fullscreenSupported?: boolean;
    request?: () => Promise<void>;
  }): Promise<void> {
    const params = new BehaviorSubject(convertToParamMap({ id: options.id ?? 'cam2' }));
    const doc = createFakeDocument();

    if (options.fullscreenSupported) {
      doc.fullscreenEnabled = true;
      installRequestFullscreen(options.request ?? (() => Promise.resolve()));
    }

    await TestBed.configureTestingModule({
      imports: [SingleViewComponent],
      providers: [
        provideRouter([]),
        { provide: ActivatedRoute, useValue: { paramMap: params } },
        { provide: FULLSCREEN_DOCUMENT, useValue: doc },
      ],
    }).compileComponents();

    const fixture = TestBed.createComponent(SingleViewComponent);
    fixture.detectChanges();

    const router = TestBed.inject(Router);
    const navigate = vi.spyOn(router, 'navigate').mockResolvedValue(true);
    const toast = TestBed.inject(ToastService);

    harness = {
      fixture,
      params,
      doc,
      router,
      navigate,
      config: TestBed.inject(CameraConfigService),
      toast,
      button: (text: string) => {
        const buttons = Array.from(
          fixture.nativeElement.querySelectorAll('button'),
        ) as HTMLButtonElement[];
        const match = buttons.find((button) => (button.textContent ?? '').trim() === text);
        expect(match, `button with text "${text}"`).toBeDefined();
        return match!;
      },
      player: () =>
        fixture.debugElement.query(By.directive(CameraPlayerComponent))
          .componentInstance as CameraPlayerComponent,
      cameraName: () =>
        (
          fixture.nativeElement.querySelector('.single-view__name') as HTMLElement | null
        )?.textContent?.trim() ?? '',
    };
  }

  beforeEach(() => {
    localStorage.clear();
    originalRequestFullscreen = Element.prototype.requestFullscreen;

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
  });

  afterEach(() => {
    restoreRequestFullscreen();
    restoreUrlStatic('createObjectURL', originalCreateUrl);
    restoreUrlStatic('revokeObjectURL', originalRevokeUrl);
    vi.restoreAllMocks();
    vi.useRealTimers();
  });

  it('renders exactly one player bound to the route camera', async () => {
    await setup({ id: 'cam2' });

    const players = harness.fixture.debugElement.queryAll(By.directive(CameraPlayerComponent));
    expect(players).toHaveLength(1);
    expect(harness.player().cameraId).toBe('cam2');
    expect(harness.cameraName()).toBe('Cámara 2');
  });

  it('renders Volver a la grilla, Pantalla completa and Snapshot as 44px toolbar controls', async () => {
    await setup({});

    ['Volver a la grilla', 'Pantalla completa', 'Snapshot'].forEach((label) => {
      const button = harness.button(label);
      expect(button.classList.contains('toolbar-btn')).toBe(true);
    });
  });

  it('returns to the grid with Esc and Backspace', async () => {
    await setup({ id: 'cam2' });

    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Backspace' }));

    expect(harness.navigate).toHaveBeenNthCalledWith(1, ['/']);
    expect(harness.navigate).toHaveBeenNthCalledWith(2, ['/']);
  });

  it('jumps to the camera at the pressed position with keys 1-4', async () => {
    await setup({ id: 'cam1' });
    harness.config.reorder(3, 0); // display order: cam4, cam1, cam2, cam3

    document.dispatchEvent(new KeyboardEvent('keydown', { key: '1' }));
    document.dispatchEvent(new KeyboardEvent('keydown', { key: '2' }));
    document.dispatchEvent(new KeyboardEvent('keydown', { key: '4' }));

    expect(harness.navigate).toHaveBeenNthCalledWith(1, ['/cam', 'cam4']);
    expect(harness.navigate).toHaveBeenNthCalledWith(2, ['/cam', 'cam1']);
    expect(harness.navigate).toHaveBeenNthCalledWith(3, ['/cam', 'cam3']);
  });

  it('ignores keys that are not a camera position', async () => {
    await setup({});

    ['0', '5', 'a', 'Enter', 'ArrowLeft'].forEach((key) =>
      document.dispatchEvent(new KeyboardEvent('keydown', { key })),
    );

    expect(harness.navigate).not.toHaveBeenCalled();
  });

  it('stays inert while the user is typing', async () => {
    await setup({});
    const input = document.createElement('input');
    const textarea = document.createElement('textarea');
    harness.fixture.nativeElement.append(input, textarea);

    ['Escape', 'Backspace', '1', 'f'].forEach((key) => {
      input.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true }));
      textarea.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true }));
    });

    expect(harness.navigate).not.toHaveBeenCalled();
  });

  it('updates the existing player when the route param changes (no remount)', async () => {
    await setup({ id: 'cam2' });
    const player = harness.player();

    harness.params.next(convertToParamMap({ id: 'cam3' }));
    harness.fixture.detectChanges();

    expect(harness.player()).toBe(player);
    expect(player.cameraId).toBe('cam3');
    expect(harness.cameraName()).toBe('Cámara 3');
  });

  it('renders no player when the route id is not a configured camera', async () => {
    await setup({ id: 'nope' });

    expect(harness.fixture.debugElement.queryAll(By.directive(CameraPlayerComponent))).toHaveLength(
      0,
    );
    expect((harness.fixture.nativeElement as HTMLElement).querySelector('.single-view')).toBeNull();
  });

  it('disables Pantalla completa with an explanation when fullscreen is unsupported (D30)', async () => {
    await setup({ fullscreenSupported: false });

    const fullscreen = harness.button('Pantalla completa');
    expect(fullscreen.disabled).toBe(true);
    expect(fullscreen.getAttribute('title')).toBe(FULLSCREEN_UNAVAILABLE_MESSAGE);
    expect(fullscreen.getAttribute('aria-label')).toBe(FULLSCREEN_UNAVAILABLE_MESSAGE);

    fullscreen.click();

    // The view stays fully usable: Volver still works (spec scenario).
    harness.button('Volver a la grilla').click();
    expect(harness.navigate).toHaveBeenCalledWith(['/']);
  });

  it('requests fullscreen, tracks fullscreenchange and exits on the second toggle', async () => {
    await setup({ fullscreenSupported: true });
    const fullscreen = harness.button('Pantalla completa');

    fullscreen.click();

    expect(Element.prototype.requestFullscreen).toHaveBeenCalledTimes(1);
    expect(fullscreen.getAttribute('aria-pressed')).toBe('false');

    harness.doc.fullscreenElement = document.createElement('div');
    listenerFor('fullscreenchange')();
    harness.fixture.detectChanges();
    expect(harness.button('Pantalla completa').getAttribute('aria-pressed')).toBe('true');

    harness.button('Pantalla completa').click();
    expect(harness.doc.exitFullscreen).toHaveBeenCalledTimes(1);

    harness.doc.fullscreenElement = null;
    listenerFor('fullscreenchange')();
    harness.fixture.detectChanges();
    expect(harness.button('Pantalla completa').getAttribute('aria-pressed')).toBe('false');
  });

  it('disables Pantalla completa and toasts when the request is rejected at runtime (D30)', async () => {
    await setup({
      fullscreenSupported: true,
      request: () => Promise.reject(new Error('denied')),
    });

    harness.button('Pantalla completa').click();
    await Promise.resolve();
    await Promise.resolve();
    harness.fixture.detectChanges();

    expect(harness.button('Pantalla completa').disabled).toBe(true);
    expect(harness.toast.message()).toEqual({
      text: FULLSCREEN_UNAVAILABLE_MESSAGE,
      tone: 'error',
    });
  });

  it('leaves fullscreen before navigating back to the grid (D30)', async () => {
    await setup({ fullscreenSupported: true });
    harness.doc.fullscreenElement = document.createElement('div');
    listenerFor('fullscreenchange')();
    harness.fixture.detectChanges();

    harness.button('Volver a la grilla').click();

    expect(harness.doc.exitFullscreen).toHaveBeenCalledTimes(1);
    expect(harness.navigate).toHaveBeenCalledWith(['/']);
    const exitOrder = (harness.doc.exitFullscreen as Mock).mock.invocationCallOrder[0];
    const navigateOrder = harness.navigate.mock.invocationCallOrder[0];
    expect(exitOrder).toBeLessThan(navigateOrder);
  });

  it('toggles fullscreen with F and registers/removes the change listeners', async () => {
    await setup({ fullscreenSupported: true });

    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'f' }));
    expect(Element.prototype.requestFullscreen).toHaveBeenCalledTimes(1);

    const fullscreenChange = listenerFor('fullscreenchange');
    const webkitChange = listenerFor('webkitfullscreenchange');

    harness.fixture.destroy();

    expect(harness.doc.removeEventListener).toHaveBeenCalledWith(
      'fullscreenchange',
      fullscreenChange,
    );
    expect(harness.doc.removeEventListener).toHaveBeenCalledWith(
      'webkitfullscreenchange',
      webkitChange,
    );
  });

  it('downloads the snapshot with the camera name and confirms it', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-09-15T10:20:30'));
    await setup({ id: 'cam2' });
    const blob = new Blob(['frame'], { type: 'image/jpeg' });
    vi.spyOn(CameraPlayerComponent.prototype, 'snapshot').mockResolvedValue(blob);

    harness.button('Snapshot').click();
    await harness.fixture.whenStable();

    expect(downloaded).toEqual({
      href: 'blob:snapshot',
      filename: buildSnapshotFilename('Cámara 2', new Date('2026-09-15T10:20:30')),
    });
    expect(revoked).toEqual(['blob:snapshot']);
    expect(harness.toast.message()).toEqual({ text: 'Captura guardada', tone: 'info' });
  });

  it('surfaces the not-ready message and downloads nothing when there is no frame', async () => {
    await setup({ id: 'cam2' });

    harness.button('Snapshot').click();
    await harness.fixture.whenStable();

    expect(downloaded).toBeNull();
    expect(harness.toast.message()).toEqual({
      text: 'La cámara todavía no está lista',
      tone: 'error',
    });
  });
});
