import { ComponentFixture, TestBed } from '@angular/core/testing';
import { CameraPlayerComponent } from './camera-player';

interface FakeMessage {
  type: string;
  value?: unknown;
}

/**
 * Stand-in for the vendored `<video-stream>` element so the component's
 * lifecycle can be exercised without loading the go2rtc module.
 */
class FakeVideoStreamElement extends HTMLElement {
  mode = '';
  media = '';
  src = '';
  background = false;
  visibilityCheck = true;
  ws: WebSocket | null = null;
  pc: RTCPeerConnection | null = null;
  wsState = 0;
  pcState = 0;
  reconnectTID = 0;
  disconnectTID = 0;
  video: HTMLVideoElement | null = null;
  onmessage: Record<string, (msg: FakeMessage) => void> | null = null;

  readonly streamMessages: FakeMessage[] = [];
  connectCalls = 0;
  openCalls = 0;
  closeCalls = 0;
  disconnectCalls = 0;

  onconnect(): boolean {
    this.connectCalls += 1;
    return true;
  }

  onopen(): string[] {
    this.openCalls += 1;
    this.onmessage = { stream: (msg: FakeMessage) => this.streamMessages.push(msg) };
    return ['webrtc'];
  }

  override onclose = (): boolean => {
    this.closeCalls += 1;
    return true;
  };

  ondisconnect(): void {
    this.disconnectCalls += 1;
  }

  connectedCallback(): void {
    if (!this.video) {
      this.video = document.createElement('video');
      this.appendChild(this.video);
    }
  }
}

if (!customElements.get('video-stream')) {
  customElements.define('video-stream', FakeVideoStreamElement);
}

describe('CameraPlayerComponent', () => {
  let fixture: ComponentFixture<CameraPlayerComponent>;
  let extraFixtures: ComponentFixture<CameraPlayerComponent>[];
  let addEventListenerSpy: ReturnType<typeof vi.spyOn>;

  function stage(): HTMLElement {
    return fixture.nativeElement.querySelector('.stage') as HTMLElement;
  }

  function player(): FakeVideoStreamElement {
    const el = stage().querySelector('video-stream');
    expect(el).not.toBeNull();
    return el as FakeVideoStreamElement;
  }

  /** The live player element, or null while the stream is torn down. */
  function liveElement(): FakeVideoStreamElement | null {
    return stage().querySelector('video-stream');
  }

  /** Drops the live stream the way the browser does: an error on its `<video>`. */
  function loseSignal(): void {
    const el = liveElement();
    expect(el, 'live player element before the connection loss').not.toBeNull();
    el!.video!.dispatchEvent(new Event('error'));
  }

  async function mountPlayer(): Promise<FakeVideoStreamElement> {
    fixture.detectChanges();
    await fixture.whenStable();
    return player();
  }

  async function replaceCamera(cameraId: string): Promise<FakeVideoStreamElement> {
    fixture.componentRef.setInput('cameraId', cameraId);
    fixture.detectChanges();
    await fixture.whenStable();
    return player();
  }

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [CameraPlayerComponent],
    }).compileComponents();

    // Installed before the first component instantiates the root VisibilityService.
    addEventListenerSpy = vi.spyOn(document, 'addEventListener');
    fixture = TestBed.createComponent(CameraPlayerComponent);
    fixture.componentRef.setInput('cameraId', 'cam1');
    extraFixtures = [];
  });

  afterEach(() => {
    vi.useRealTimers();
    for (const extra of extraFixtures) extra.destroy();
    fixture.destroy();
    vi.restoreAllMocks();
  });

  it('creates the component with a connecting status', () => {
    expect(fixture.componentInstance).toBeTruthy();
    expect(fixture.componentInstance.status()).toBe('connecting');
  });

  it('rejects snapshot() with a Spanish message when no frame is ready', async () => {
    await expect(fixture.componentInstance.snapshot()).rejects.toThrow(
      'La cámara todavía no está lista',
    );
  });

  it('shares a single visibilitychange listener between players', async () => {
    const second = TestBed.createComponent(CameraPlayerComponent);
    second.componentRef.setInput('cameraId', 'cam2');
    extraFixtures.push(second);

    fixture.detectChanges();
    second.detectChanges();
    await fixture.whenStable();

    const registered = addEventListenerSpy.mock.calls.filter(
      ([type]: [string, ...unknown[]]) => type === 'visibilitychange',
    );
    expect(registered).toHaveLength(1);
  });

  it('tears the player down while the tab is hidden and reconnects on return', async () => {
    const hidden = vi.spyOn(document, 'hidden', 'get').mockReturnValue(false);
    const first = await mountPlayer();

    hidden.mockReturnValue(true);
    document.dispatchEvent(new Event('visibilitychange'));
    await fixture.whenStable();

    expect(stage().querySelector('video-stream')).toBeNull();
    expect(first.disconnectCalls).toBeGreaterThan(0);

    hidden.mockReturnValue(false);
    document.dispatchEvent(new Event('visibilitychange'));
    await fixture.whenStable();

    expect(stage().querySelector('video-stream')).not.toBeNull();
  });

  it('ignores a late close event from a torn-down player', async () => {
    const first = await mountPlayer();
    const second = await replaceCamera('cam2');
    expect(second).not.toBe(first);

    expect(first.onclose!()).toBe(false);

    expect(fixture.componentInstance.status()).toBe('connecting');
    expect(player()).toBe(second);
  });

  it('ignores a late stream error from a torn-down player', async () => {
    const first = await mountPlayer();
    first.onopen!(); // installs the wrapped stream message handler while the player is alive
    const second = await replaceCamera('cam2');
    expect(first.onmessage).not.toBeNull();

    first.onmessage!['stream']({ type: 'error', value: 'stream failed' });

    expect(fixture.componentInstance.status()).toBe('connecting');
    expect(player()).toBe(second);
  });

  it('ignores a late open event from a torn-down player', async () => {
    const first = await mountPlayer();
    const second = await replaceCamera('cam2');
    second.video!.dispatchEvent(new Event('playing'));
    expect(fixture.componentInstance.status()).toBe('playing');

    expect(first.onopen!()).toEqual([]);

    expect(fixture.componentInstance.status()).toBe('playing');
    expect(player()).toBe(second);
  });

  it('ignores a late connect from a torn-down player', async () => {
    const first = await mountPlayer();
    const callsWhileAlive = first.connectCalls;
    const second = await replaceCamera('cam2');

    expect(first.onconnect!()).toBe(false);

    expect(first.connectCalls).toBe(callsWhileAlive);
    expect(fixture.componentInstance.status()).toBe('connecting');
    expect(player()).toBe(second);
  });

  it('ignores a late playing event from a player torn down by a signal loss', async () => {
    const lost = await mountPlayer();

    // The signal drops: the element is detached and the 5s retry is pending.
    lost.video!.dispatchEvent(new Event('error'));
    fixture.detectChanges();
    expect(fixture.componentInstance.status()).toBe('error');

    // The detached <video> can still fire `playing` after teardown; it must not
    // fake a live status while "Sin señal" is showing.
    lost.video!.dispatchEvent(new Event('playing'));
    fixture.detectChanges();

    expect(fixture.componentInstance.status()).toBe('error');
    expect(liveElement()).toBeNull();
    const overlay = fixture.nativeElement.querySelector('.overlay--error') as HTMLElement | null;
    expect(overlay).not.toBeNull();
    expect(overlay!.textContent).toContain('Sin señal');
  });

  it('ignores a late playing event from a replaced player', async () => {
    const first = await mountPlayer();
    const second = await replaceCamera('cam2');
    expect(second).not.toBe(first);

    first.video!.dispatchEvent(new Event('playing'));
    fixture.detectChanges();

    expect(fixture.componentInstance.status()).toBe('connecting');
    expect(player()).toBe(second);
  });

  describe('silent playback (R: Silent playback)', () => {
    it('configures the stream element and its <video> for silent autoplay', async () => {
      const el = await mountPlayer();

      expect(el.mode).toBe('webrtc,mse');
      expect(el.media).toBe('video');

      const video = el.video!;
      expect(video.muted).toBe(true);
      expect(video.defaultMuted).toBe(true);
      expect(video.playsInline).toBe(true);
      expect(video.autoplay).toBe(true);
      expect(video.controls).toBe(false);
    });
  });

  describe('resilient playback (R: Resilient playback)', () => {
    it('keeps "Sin señal" and Reintentar visible instead of reconnecting on the next flush', async () => {
      const lost = await mountPlayer();

      lost.video!.dispatchEvent(new Event('error'));

      // Angular flushes the constructor effect here. On the buggy code that
      // flush re-entered startConnection() through the `status` read inside
      // setStatus(), flipping the status back and recreating the element.
      fixture.detectChanges();

      expect(fixture.componentInstance.status()).toBe('error');
      const overlay = fixture.nativeElement.querySelector('.overlay--error') as HTMLElement | null;
      expect(overlay).not.toBeNull();
      expect(overlay!.textContent).toContain('Sin señal');
      expect(overlay!.querySelector('.overlay__retry')?.textContent).toContain('Reintentar');
      expect(liveElement()).toBeNull();

      // The 5s retry timer is pending: nothing may reconnect inside this window.
      await fixture.whenStable();
      fixture.detectChanges();

      expect(fixture.componentInstance.status()).toBe('error');
      expect(liveElement()).toBeNull();
    });

    it('waits the 5s backoff before the first automatic retry', async () => {
      const lost = await mountPlayer();
      vi.useFakeTimers();

      lost.video!.dispatchEvent(new Event('error'));
      fixture.detectChanges();

      expect(fixture.componentInstance.status()).toBe('error');

      await vi.advanceTimersByTimeAsync(4_999);
      fixture.detectChanges();

      // Still inside the backoff window: no element has been recreated.
      expect(fixture.componentInstance.status()).toBe('error');
      expect(liveElement()).toBeNull();

      await vi.advanceTimersByTimeAsync(1);
      fixture.detectChanges();

      expect(fixture.componentInstance.status()).toBe('connecting');
      expect(liveElement()).not.toBeNull();
    });

    it('retries on the 5s → 10s → 20s → 30s cadence and keeps the 30s cap', async () => {
      const lost = await mountPlayer();
      vi.useFakeTimers();

      lost.video!.dispatchEvent(new Event('error'));
      fixture.detectChanges();

      const attemptTimes: number[] = [];
      let elapsed = 0;

      // Step in small slices so each retry is observed right when it starts and
      // can be failed immediately, forcing the next backoff step.
      while (attemptTimes.length < 5 && elapsed < 120_000) {
        elapsed += 100;
        await vi.advanceTimersByTimeAsync(100);
        fixture.detectChanges();

        const attempt = liveElement();
        if (!attempt) continue;

        attemptTimes.push(elapsed);
        loseSignal();
        fixture.detectChanges();
      }

      expect(attemptTimes).toEqual([5_000, 15_000, 35_000, 65_000, 95_000]);
    });

    it('restarts the 5s backoff after a successful recovery', async () => {
      const lost = await mountPlayer();
      vi.useFakeTimers();

      lost.video!.dispatchEvent(new Event('error'));
      fixture.detectChanges();

      await vi.advanceTimersByTimeAsync(5_000);
      fixture.detectChanges();
      expect(liveElement()).not.toBeNull();

      // The stream comes back on that retry...
      player().video!.dispatchEvent(new Event('playing'));
      fixture.detectChanges();
      expect(fixture.componentInstance.status()).toBe('playing');

      // ...and the next drop waits 5s again: the counter reset on `playing`.
      player().video!.dispatchEvent(new Event('error'));
      fixture.detectChanges();

      await vi.advanceTimersByTimeAsync(4_999);
      fixture.detectChanges();
      expect(fixture.componentInstance.status()).toBe('error');
      expect(liveElement()).toBeNull();

      await vi.advanceTimersByTimeAsync(1);
      fixture.detectChanges();
      expect(liveElement()).not.toBeNull();
    });

    it('Reintentar reconnects immediately and the overlay clears once the stream recovers', async () => {
      const lost = await mountPlayer();

      lost.video!.dispatchEvent(new Event('error'));
      fixture.detectChanges();

      const overlay = fixture.nativeElement.querySelector('.overlay--error') as HTMLElement;
      expect(overlay).not.toBeNull();
      const retry = overlay.querySelector('.overlay__retry') as HTMLButtonElement;
      expect(retry).not.toBeNull();

      retry.click();
      fixture.detectChanges();
      await fixture.whenStable();

      // Manual retry bypasses the backoff and starts a fresh attempt.
      expect(fixture.componentInstance.status()).toBe('connecting');
      expect(fixture.nativeElement.querySelector('.overlay--error')).toBeNull();
      expect(liveElement()).not.toBeNull();

      player().video!.dispatchEvent(new Event('playing'));
      fixture.detectChanges();

      // Recovery clears the overlay entirely.
      expect(fixture.componentInstance.status()).toBe('playing');
      expect(fixture.nativeElement.querySelector('.overlay--connecting')).toBeNull();
      expect(fixture.nativeElement.querySelector('.overlay--error')).toBeNull();
    });
  });
});
