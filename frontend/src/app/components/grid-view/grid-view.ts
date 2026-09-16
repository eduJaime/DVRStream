import { ChangeDetectionStrategy, Component, inject, signal } from '@angular/core';
import { Router } from '@angular/router';
import {
  CdkDrag,
  CdkDragDrop,
  CdkDragPlaceholder,
  CdkDragPreview,
  CdkDropList,
} from '@angular/cdk/drag-drop';

import { CameraId } from '../../models/camera-config';
import { CameraConfigService } from '../../services/camera-config.service';
import { cameraIdForKey, isTypingTarget } from '../../util/keyboard-shortcuts';
import { CameraTileComponent } from '../camera-tile/camera-tile';

/**
 * The routed camera grid: four live tiles over the configured order.
 *
 * - `cdkDropList` (mixed orientation) + `cdkDrag` on each tile host; the PR3
 *   grip is the only `cdkDragHandle`, so the cell body never starts a drag
 *   (TD-2/D24);
 * - `*cdkDragPreview` / `*cdkDragPlaceholder` keep CDK from deep-cloning a
 *   live `<video-stream>` into `document.body` (D5);
 * - `@for` is tracked by `camera.id`, so a reorder moves the existing tiles and
 *   the player instances (no teardown, no renegotiation — spec "Camera ordering").
 */
@Component({
  selector: 'app-grid-view',
  imports: [CameraTileComponent, CdkDropList, CdkDrag, CdkDragPreview, CdkDragPlaceholder],
  templateUrl: './grid-view.html',
  styleUrl: './grid-view.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
  host: {
    '(document:keydown)': 'onKeyDown($event)',
  },
})
export class GridViewComponent {
  protected readonly config = inject(CameraConfigService);
  private readonly router = inject(Router);

  /** "Restablecer" is destructive, so it asks before restoring defaults. */
  protected readonly confirmingReset = signal(false);

  /** Grid and keyboard routes to the single view (PR5 owns its component). */
  protected openCamera(id: CameraId): void {
    void this.router.navigate(['/cam', id]);
  }

  /** Both indices come from the same `ordered()` array the service renumbers. */
  protected onDrop(event: CdkDragDrop<unknown>): void {
    this.config.reorder(event.previousIndex, event.currentIndex);
  }

  /** Keys `1`-`4` open the camera at that position; inert while typing. */
  protected onKeyDown(event: KeyboardEvent): void {
    if (isTypingTarget(event.target)) return;

    const cameraId = cameraIdForKey(event.key, this.config.ordered());
    if (cameraId === null) return;

    event.preventDefault();
    this.openCamera(cameraId);
  }

  protected requestReset(): void {
    this.confirmingReset.set(true);
  }

  protected cancelReset(): void {
    this.confirmingReset.set(false);
  }

  protected confirmReset(): void {
    this.config.reset();
    this.confirmingReset.set(false);
  }
}
