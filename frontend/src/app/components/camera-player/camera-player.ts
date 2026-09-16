import {
  ChangeDetectionStrategy,
  Component,
  CUSTOM_ELEMENTS_SCHEMA,
  ElementRef,
  EventEmitter,
  Input,
  OnDestroy,
  OnInit,
  Output,
  ViewChild,
  effect,
  inject,
  signal,
  untracked,
} from '@angular/core';
import { environment } from '../../../environments/environment';
import { VisibilityService } from '../../services/visibility.service';
import { nextRetryDelay } from '../../util/retry-backoff';
import { buildStreamUrl } from './stream-url';

export type CameraPlayerStatus = 'connecting' | 'playing' | 'error';

/**
 * Minimal typing for the go2rtc `<video-stream>` custom element.
 * The implementation lives in `public/go2rtc/video-stream.js`.
 */
interface VideoStreamElement extends HTMLElement {
  mode: string;
  media: string;
  src: string;
  background: boolean;
  visibilityCheck: boolean;
  video: HTMLVideoElement | null;
  ws: WebSocket | null;
  pc: RTCPeerConnection | null;
  wsState: number;
  pcState: number;
  reconnectTID: number;
  disconnectTID: number;
  onconnect(): boolean;
  onopen(): string[];
  onclose(): boolean;
  ondisconnect(): void;
  onmessage: Record<string, (msg: { type: string; value?: unknown }) => void> | null;
}

interface PlayerMessage {
  type: string;
  value?: unknown;
}

const PLAYER_CUSTOM_ELEMENT = 'video-stream';
const PLAYER_SCRIPT_ID = 'go2rtc-video-stream-script';
const PLAYER_SCRIPT_PATH = 'go2rtc/video-stream.js';
const PLAYER_SCRIPT_ERROR = 'No se pudo cargar el reproductor de go2rtc';
const CONNECT_TIMEOUT_MS = 8_000;

@Component({
  selector: 'app-camera-player',
  templateUrl: './camera-player.html',
  styleUrl: './camera-player.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
})
export class CameraPlayerComponent implements OnInit, OnDestroy {
  @ViewChild('stage', { static: true })
  private readonly stageRef!: ElementRef<HTMLDivElement>;

  @Output() readonly statusChange = new EventEmitter<CameraPlayerStatus>();

  /** Current stream status, exposed for the grid/single views. */
  readonly status = signal<CameraPlayerStatus>('connecting');

  private readonly visibility = inject(VisibilityService);

  private cameraIdValue = '';
  private activeRequested = true;
  private initialized = false;
  private destroyed = false;

  private playerEl: VideoStreamElement | null = null;
  private playerScriptPromise: Promise<void> | null = null;
  private allowNativeConnect = false;
  private retryAttempt = 0;
  private retryTID: number | null = null;
  private connectTimeoutTID: number | null = null;

  private readonly onVideoPlaying = (): void => this.onPlaying();
  private readonly onVideoError = (): void => this.onConnectionLost();

  constructor() {
    // One shared `visibilitychange` seam for every player (design D4).
    //
    // The effect's ONLY reactive input is `tabVisible`. Everything it triggers
    // (applyConnectionState → startConnection → setStatus, which READS the
    // `status` signal) must run untracked: otherwise `status` becomes a
    // dependency, every `setStatus('error')` re-runs the effect, and the effect
    // immediately reconnects — cancelling the scheduled backoff and turning a
    // failed stream into a hot reconnect loop (verification finding C1).
    effect(() => {
      const tabVisible = this.visibility.tabVisible();
      untracked(() => {
        if (!this.initialized) return;
        if (tabVisible) this.retryAttempt = 0;
        this.applyConnectionState();
      });
    });
  }

  @Input({ required: true })
  set cameraId(value: string) {
    if (value === this.cameraIdValue) return;
    this.cameraIdValue = value;
    if (this.playerEl) {
      this.stopConnection();
      this.applyConnectionState();
    }
  }
  get cameraId(): string {
    return this.cameraIdValue;
  }

  /** When false, the stream is torn down; when true again it is re-created. */
  @Input()
  set active(value: boolean) {
    const next = value !== false;
    if (next === this.activeRequested) return;
    this.activeRequested = next;
    this.applyConnectionState();
  }
  get active(): boolean {
    return this.activeRequested;
  }

  ngOnInit(): void {
    this.initialized = true;
    this.applyConnectionState();
  }

  ngOnDestroy(): void {
    this.destroyed = true;
    this.stopConnection();
  }

  /** Captures the current frame from the internal `<video>` as a JPEG blob. */
  async snapshot(): Promise<Blob> {
    const video = this.playerEl?.video ?? null;

    if (!video || video.readyState < 2 || video.videoWidth === 0 || video.videoHeight === 0) {
      throw new Error('La cámara todavía no está lista');
    }

    const canvas = document.createElement('canvas');
    canvas.width = video.videoWidth;
    canvas.height = video.videoHeight;

    const context = canvas.getContext('2d');
    if (!context) throw new Error('No se pudo preparar la captura');

    context.drawImage(video, 0, 0, canvas.width, canvas.height);

    return new Promise<Blob>((resolve, reject) => {
      canvas.toBlob(
        (blob) => (blob ? resolve(blob) : reject(new Error('No se pudo generar la captura'))),
        'image/jpeg',
        0.92,
      );
    });
  }

  /** Manual retry: resets the backoff and reconnects immediately. */
  retry(): void {
    if (!this.canRun()) return;
    this.cancelRetry();
    this.retryAttempt = 0;
    this.stopConnection();
    this.applyConnectionState();
  }

  /** Run condition: mounted ∧ active ∧ tab visible (design D4). */
  private canRun(): boolean {
    return !this.destroyed && this.activeRequested && this.visibility.tabVisible();
  }

  /** Single place that decides whether the stream must be running. */
  private applyConnectionState(): void {
    if (this.canRun()) this.startConnection();
    else this.stopConnection();
  }

  private startConnection(): void {
    if (this.playerEl) return;

    this.cancelRetry();
    this.setStatus('connecting');

    this.ensurePlayerScriptLoaded()
      .then(() => {
        if (this.playerEl || !this.canRun()) return;
        this.createPlayerElement();
      })
      .catch(() => this.onConnectionLost());
  }

  private ensurePlayerScriptLoaded(): Promise<void> {
    if (customElements.get(PLAYER_CUSTOM_ELEMENT)) return Promise.resolve();

    if (!this.playerScriptPromise) {
      this.playerScriptPromise = new Promise<void>((resolve, reject) => {
        const existing = document.getElementById(PLAYER_SCRIPT_ID) as HTMLScriptElement | null;
        const script = existing ?? document.createElement('script');
        script.id = PLAYER_SCRIPT_ID;
        script.type = 'module';
        script.src = new URL(PLAYER_SCRIPT_PATH, document.baseURI).href;

        // A failed load must not leave the player stuck on "Conectando…":
        // drop the tag and the cached promise so the next retry injects again.
        script.addEventListener(
          'error',
          () => {
            script.remove();
            this.playerScriptPromise = null;
            reject(new Error(PLAYER_SCRIPT_ERROR));
          },
          { once: true },
        );

        if (!existing) document.head.appendChild(script);
        customElements.whenDefined(PLAYER_CUSTOM_ELEMENT).then(() => resolve());
      });
    }

    return this.playerScriptPromise;
  }

  private createPlayerElement(): void {
    const stage = this.stageRef.nativeElement;
    const el = document.createElement(PLAYER_CUSTOM_ELEMENT) as VideoStreamElement;

    el.mode = 'webrtc,mse';
    el.media = 'video'; // audio disabled
    el.visibilityCheck = false; // this component owns visibility handling
    el.background = true; // disable the built-in 5s disconnect timer

    const nativeConnect = el.onconnect.bind(el);
    const nativeOpen = el.onopen.bind(el);
    const nativeClose = el.onclose.bind(el);

    // The component owns reconnection. Any connect attempt not explicitly
    // requested below is treated as a connection loss and drives our backoff.
    // Every wrapped hook bails when its element is no longer the live player,
    // so a late socket event cannot resurrect a torn-down stream (design §5.4).
    el.onconnect = () => {
      if (this.playerEl !== el) return false;
      if (!this.allowNativeConnect) {
        this.onConnectionLost();
        return false;
      }
      this.allowNativeConnect = false;
      const started = nativeConnect();
      if (started) this.armConnectTimeout();
      return started;
    };

    el.onopen = () => {
      if (this.playerEl !== el) return [];
      const modes = nativeOpen();
      this.wrapStreamMessage(el);
      this.setStatus('connecting');
      this.armConnectTimeout();
      return modes;
    };

    el.onclose = () => {
      if (this.playerEl !== el) return false;
      const reconnecting = nativeClose();
      if (el.reconnectTID) {
        clearTimeout(el.reconnectTID);
        el.reconnectTID = 0;
      }
      if (reconnecting) this.onConnectionLost();
      return reconnecting;
    };

    this.playerEl = el;
    // `connectedCallback` builds the internal <video> synchronously on append.
    this.allowNativeConnect = true;
    stage.replaceChildren(el);
    this.configureVideoElement(el);

    this.allowNativeConnect = true;
    el.src = buildStreamUrl(this.cameraIdValue, environment.go2rtcBaseUrl, window.location.origin);
  }

  private configureVideoElement(el: VideoStreamElement): void {
    const video = el.video;
    if (!video) return;

    video.muted = true;
    video.defaultMuted = true;
    video.playsInline = true;
    video.autoplay = true;
    video.controls = false;
    video.style.objectFit = 'contain';
    video.style.width = '100%';
    video.style.height = '100%';

    video.addEventListener('playing', this.onVideoPlaying);
    video.addEventListener('error', this.onVideoError);
  }

  private wrapStreamMessage(el: VideoStreamElement): void {
    if (!el.onmessage) return;

    const original = el.onmessage['stream'];
    el.onmessage['stream'] = (msg: PlayerMessage) => {
      if (this.playerEl !== el) return;
      original?.(msg);
      if (msg.type === 'error') this.onConnectionLost();
    };
  }

  private onPlaying(): void {
    if (!this.canRun()) return;
    this.retryAttempt = 0;
    this.clearConnectTimeout();
    this.setStatus('playing');
  }

  private onConnectionLost(): void {
    if (!this.canRun()) return;

    this.clearConnectTimeout();
    this.teardownPlayer();
    this.setStatus('error');
    this.scheduleRetry();
  }

  private scheduleRetry(): void {
    if (!this.canRun() || this.retryTID !== null) return;

    const delayMs = nextRetryDelay(this.retryAttempt) * 1_000;
    this.retryAttempt += 1;

    this.retryTID = window.setTimeout(() => {
      this.retryTID = null;
      this.startConnection();
    }, delayMs);
  }

  private armConnectTimeout(): void {
    this.clearConnectTimeout();
    this.connectTimeoutTID = window.setTimeout(() => {
      this.connectTimeoutTID = null;
      if (this.status() !== 'playing') this.onConnectionLost();
    }, CONNECT_TIMEOUT_MS);
  }

  private clearConnectTimeout(): void {
    if (this.connectTimeoutTID !== null) {
      clearTimeout(this.connectTimeoutTID);
      this.connectTimeoutTID = null;
    }
  }

  private cancelRetry(): void {
    if (this.retryTID !== null) {
      clearTimeout(this.retryTID);
      this.retryTID = null;
    }
  }

  private stopConnection(): void {
    this.cancelRetry();
    this.clearConnectTimeout();
    this.teardownPlayer();
  }

  /** Closes the WebSocket/PeerConnection and removes the element from the DOM. */
  private teardownPlayer(): void {
    const el = this.playerEl;
    this.playerEl = null;
    if (!el) return;

    if (el.reconnectTID) {
      clearTimeout(el.reconnectTID);
      el.reconnectTID = 0;
    }
    if (el.disconnectTID) {
      clearTimeout(el.disconnectTID);
      el.disconnectTID = 0;
    }

    try {
      if (el.video) el.ondisconnect();
    } catch {
      // Element may be partially initialized; removal below is enough.
    }

    el.remove();
  }

  private setStatus(status: CameraPlayerStatus): void {
    if (this.status() === status) return;
    this.status.set(status);
    this.statusChange.emit(status);
  }
}
