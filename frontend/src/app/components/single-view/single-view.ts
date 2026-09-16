import {
  ChangeDetectionStrategy,
  Component,
  DOCUMENT,
  ElementRef,
  InjectionToken,
  OnDestroy,
  OnInit,
  computed,
  inject,
  signal,
  viewChild,
} from '@angular/core';
import { toSignal } from '@angular/core/rxjs-interop';
import { ActivatedRoute, Router } from '@angular/router';
import { map } from 'rxjs';

import { resolveCameraId } from '../../models/camera-config';
import { CameraConfigService } from '../../services/camera-config.service';
import { ToastService } from '../../services/toast.service';
import { downloadBlob } from '../../util/download-blob';
import {
  FullscreenDocument,
  detectFullscreenSupport,
  exitFullscreen,
  isFullscreenActive,
  requestFullscreen,
} from '../../util/fullscreen';
import { cameraIdForKey, isTypingTarget } from '../../util/keyboard-shortcuts';
import { CameraPlayerComponent } from '../camera-player/camera-player';
import { buildSnapshotFilename } from '../camera-player/snapshot-filename';

/**
 * The fullscreen document seam: production injects the real `DOCUMENT`; tests
 * inject a fake capability (jsdom implements no Fullscreen API at all).
 */
export interface FullscreenDocumentWithEvents extends FullscreenDocument {
  addEventListener(type: string, listener: EventListener): void;
  removeEventListener(type: string, listener: EventListener): void;
}

export const FULLSCREEN_DOCUMENT = new InjectionToken<FullscreenDocumentWithEvents>(
  'FULLSCREEN_DOCUMENT',
  { factory: () => inject(DOCUMENT) },
);

/** Fullscreen is optional; when unavailable the control explains itself (D30). */
export const FULLSCREEN_UNAVAILABLE_MESSAGE =
  'Pantalla completa no está disponible en este navegador';
/** Confirmation toast after a snapshot is downloaded. */
export const SNAPSHOT_SAVED_MESSAGE = 'Captura guardada';
/** Fallback when the player rejects with something that is not an Error. */
export const SNAPSHOT_ERROR_MESSAGE = 'No se pudo guardar la captura';

/**
 * Single camera view (`cam/:id`): one player filling the viewport plus the
 * Volver / Pantalla completa / Snapshot toolbar.
 *
 * - the route param is read as a signal (`toSignal`, not `snapshot`), so keys
 *   `1`-`4` switch cameras without remounting the player (design D2);
 * - `Esc`/`Backspace` return to the grid, `F` toggles fullscreen, `1`-`4` jump
 *   by position; all inert while the user is typing (`isTypingTarget`);
 * - fullscreen is detected up front and degrades to a disabled control with an
 *   explanation; a runtime rejection disables it and surfaces a toast; exiting
 *   happens before navigating away (D30).
 */
@Component({
  selector: 'app-single-view',
  imports: [CameraPlayerComponent],
  templateUrl: './single-view.html',
  styleUrl: './single-view.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
  host: {
    '(document:keydown)': 'onKeyDown($event)',
  },
})
export class SingleViewComponent implements OnInit, OnDestroy {
  private readonly route = inject(ActivatedRoute);
  private readonly router = inject(Router);
  private readonly config = inject(CameraConfigService);
  private readonly toast = inject(ToastService);
  private readonly document = inject(FULLSCREEN_DOCUMENT);
  private readonly host = inject<ElementRef<HTMLElement>>(ElementRef);
  private readonly player = viewChild.required(CameraPlayerComponent);

  /** Resolved route camera; the guard keeps unknown ids out of this view. */
  protected readonly cameraId = toSignal(
    this.route.paramMap.pipe(map((params) => resolveCameraId(params.get('id')))),
    { initialValue: null },
  );

  protected readonly camera = computed(() => {
    const id = this.cameraId();
    if (id === null) return null;
    return this.config.config().find((camera) => camera.id === id) ?? null;
  });

  protected readonly fullscreenMessage = FULLSCREEN_UNAVAILABLE_MESSAGE;

  /** D30: unsupported fullscreen disables the control, it never hides it. */
  protected readonly fullscreenAvailable = signal(
    detectFullscreenSupport(this.document, this.host.nativeElement),
  );
  protected readonly fullscreenActive = signal(isFullscreenActive(this.document));

  private readonly onFullscreenChange = (): void => {
    this.fullscreenActive.set(isFullscreenActive(this.document));
  };

  ngOnInit(): void {
    this.document.addEventListener('fullscreenchange', this.onFullscreenChange);
    this.document.addEventListener('webkitfullscreenchange', this.onFullscreenChange);
  }

  ngOnDestroy(): void {
    this.document.removeEventListener('fullscreenchange', this.onFullscreenChange);
    this.document.removeEventListener('webkitfullscreenchange', this.onFullscreenChange);
  }

  /** D30: fullscreen is exited before leaving, so navigation never traps. */
  protected backToGrid(): void {
    if (this.fullscreenActive()) exitFullscreen(this.document);
    void this.router.navigate(['/']);
  }

  protected toggleFullscreen(): void {
    if (!this.fullscreenAvailable()) return;

    if (this.fullscreenActive()) {
      exitFullscreen(this.document);
      return;
    }

    const request = requestFullscreen(this.host.nativeElement);
    request?.catch(() => this.onFullscreenUnavailable());
  }

  protected async takeSnapshot(): Promise<void> {
    const camera = this.camera();
    if (!camera) return;

    try {
      const blob = await this.player().snapshot();
      downloadBlob(blob, buildSnapshotFilename(camera.name, new Date()));
      this.toast.show(SNAPSHOT_SAVED_MESSAGE);
    } catch (error) {
      this.toast.show(error instanceof Error ? error.message : SNAPSHOT_ERROR_MESSAGE, 'error');
    }
  }

  protected onKeyDown(event: KeyboardEvent): void {
    if (isTypingTarget(event.target)) return;

    if (event.key === 'Escape' || event.key === 'Backspace') {
      if (event.key === 'Backspace') event.preventDefault();
      this.backToGrid();
      return;
    }

    if (event.key === 'f' || event.key === 'F') {
      this.toggleFullscreen();
      return;
    }

    const cameraId = cameraIdForKey(event.key, this.config.ordered());
    if (cameraId === null) return;

    event.preventDefault();
    void this.router.navigate(['/cam', cameraId]);
  }

  private onFullscreenUnavailable(): void {
    this.fullscreenAvailable.set(false);
    this.toast.show(FULLSCREEN_UNAVAILABLE_MESSAGE, 'error');
  }
}
