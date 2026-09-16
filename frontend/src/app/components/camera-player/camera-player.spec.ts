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
});
