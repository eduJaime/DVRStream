import {
  ChangeDetectionStrategy,
  Component,
  ElementRef,
  EventEmitter,
  Input,
  Output,
  effect,
  inject,
  signal,
  viewChild,
} from '@angular/core';
import { CdkDragHandle } from '@angular/cdk/drag-drop';
import { CameraConfig, CameraId } from '../../models/camera-config';
import { CameraConfigService } from '../../services/camera-config.service';
import { ToastService } from '../../services/toast.service';
import { downloadBlob } from '../../util/download-blob';
import { CameraPlayerComponent } from '../camera-player/camera-player';
import { buildSnapshotFilename } from '../camera-player/snapshot-filename';

/** Inline rename rejection: the previous name is kept and the user is told why. */
export const RENAME_ERROR_MESSAGE = 'El nombre debe tener entre 1 y 30 caracteres';
/** Confirmation toast after a snapshot is downloaded. */
export const SNAPSHOT_SAVED_MESSAGE = 'Captura guardada';
/** Fallback when the player rejects with something that is not an Error. */
export const SNAPSHOT_ERROR_MESSAGE = 'No se pudo guardar la captura';

/**
 * Grid cell: the live player, the name overlay and the cell actions.
 *
 * Touch contract (spec domain `touch-mobile`):
 * - the video surface has NO click handler; `Ampliar` is the explicit tap
 *   affordance (TD-1/D23);
 * - reordering starts only from the `cdkDragHandle` grip, never the cell body
 *   (TD-2/D24-D25);
 * - hidden actions are `pointer-events: none`, never `aria-hidden` (TD-3/D22).
 */
@Component({
  selector: 'app-camera-tile',
  imports: [CameraPlayerComponent, CdkDragHandle],
  templateUrl: './camera-tile.html',
  styleUrl: './camera-tile.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class CameraTileComponent {
  @Input({ required: true }) camera!: CameraConfig;

  /** Emitted when the user asks to open this camera's single view. */
  @Output() readonly open = new EventEmitter<CameraId>();

  private readonly config = inject(CameraConfigService);
  private readonly toast = inject(ToastService);
  private readonly player = viewChild.required(CameraPlayerComponent);
  private readonly nameInput = viewChild<ElementRef<HTMLInputElement>>('nameInput');

  protected readonly editing = signal(false);
  protected readonly renameError = signal<string | null>(null);

  constructor() {
    // Focus the editor the moment it enters the DOM: touch keyboards have no
    // other way to start typing (D32).
    effect(() => {
      const input = this.nameInput();
      if (this.editing() && input) {
        input.nativeElement.focus();
        input.nativeElement.select();
      }
    });
  }

  /** Explicit affordance: the only tap route to the single view on touch. */
  protected openSingleView(): void {
    this.open.emit(this.camera.id);
  }

  /** Hover-capable devices keep double-click as a (non-exclusive) route. */
  protected onCellDblClick(): void {
    this.open.emit(this.camera.id);
  }

  protected onNameDblClick(event: MouseEvent): void {
    event.stopPropagation();
    this.startRename();
  }

  protected startRename(): void {
    this.renameError.set(null);
    this.editing.set(true);
  }

  protected cancelRename(): void {
    this.editing.set(false);
    this.renameError.set(null);
  }

  /** Saves through the service; a rejection keeps the previous name + shows why. */
  protected saveRename(value: string): void {
    if (this.config.rename(this.camera.id, value)) {
      this.renameError.set(null);
      this.editing.set(false);
      return;
    }
    this.renameError.set(RENAME_ERROR_MESSAGE);
  }

  protected async takeSnapshot(): Promise<void> {
    try {
      const blob = await this.player().snapshot();
      downloadBlob(blob, buildSnapshotFilename(this.camera.name, new Date()));
      this.toast.show(SNAPSHOT_SAVED_MESSAGE);
    } catch (error) {
      this.toast.show(error instanceof Error ? error.message : SNAPSHOT_ERROR_MESSAGE, 'error');
    }
  }
}
