import { ComponentFixture, TestBed } from '@angular/core/testing';
import { CameraPlayerComponent } from './camera-player';

const SCRIPT_SELECTOR = 'script#go2rtc-video-stream-script';

describe('CameraPlayerComponent (module script loading)', () => {
  let fixture: ComponentFixture<CameraPlayerComponent>;

  async function flushMicrotasks(): Promise<void> {
    await Promise.resolve();
    await Promise.resolve();
  }

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [CameraPlayerComponent],
    }).compileComponents();

    // Force the "module not loaded yet" path regardless of the global registry.
    vi.spyOn(customElements, 'get').mockReturnValue(undefined);
    vi.spyOn(customElements, 'whenDefined').mockReturnValue(
      new Promise(() => {}) as Promise<CustomElementConstructor>,
    );

    fixture = TestBed.createComponent(CameraPlayerComponent);
    fixture.componentRef.setInput('cameraId', 'cam1');
  });

  afterEach(() => {
    fixture.destroy();
    vi.useRealTimers();
    vi.restoreAllMocks();
    document.querySelector(SCRIPT_SELECTOR)?.remove();
  });

  it('surfaces a load failure instead of staying on "Conectando…"', async () => {
    fixture.detectChanges();
    const script = document.querySelector(SCRIPT_SELECTOR) as HTMLScriptElement | null;
    expect(script).not.toBeNull();

    script!.dispatchEvent(new Event('error'));
    await flushMicrotasks();

    expect(fixture.componentInstance.status()).toBe('error');
  });

  it('re-injects the script only after the full 5s backoff', async () => {
    vi.useFakeTimers();
    fixture.detectChanges();

    const failed = document.querySelector(SCRIPT_SELECTOR) as HTMLScriptElement | null;
    expect(failed).not.toBeNull();

    failed!.dispatchEvent(new Event('error'));
    await flushMicrotasks();

    // The failed tag is dropped so the retry can inject a fresh one.
    expect(document.querySelector(SCRIPT_SELECTOR)).toBeNull();

    // A failed load must not be re-injected before the mandated 5s backoff.
    vi.advanceTimersByTime(4_999);
    await flushMicrotasks();
    expect(document.querySelector(SCRIPT_SELECTOR)).toBeNull();

    vi.advanceTimersByTime(1);
    await flushMicrotasks();

    const reInjected = document.querySelector(SCRIPT_SELECTOR) as HTMLScriptElement | null;
    expect(reInjected).not.toBeNull();
    expect(reInjected).not.toBe(failed);
    expect(document.querySelectorAll(SCRIPT_SELECTOR)).toHaveLength(1);
  });
});
