import { ComponentFixture, TestBed } from '@angular/core/testing';
import { ElementRef, TemplateRef, ViewContainerRef } from '@angular/core';
import { By } from '@angular/platform-browser';
import { Router, provideRouter } from '@angular/router';
import { CdkDrag, CdkDragDrop, CdkDropList } from '@angular/cdk/drag-drop';
import type { MockInstance } from 'vitest';

import { CameraConfigService } from '../../services/camera-config.service';
import { CameraPlayerComponent } from '../camera-player/camera-player';
import { GridViewComponent } from './grid-view';

/**
 * CDK keeps the preview/placeholder templates and the drag handle list private
 * in its typings; the grid tests read them at runtime to lock design D5 (no
 * deep clone of the live tile) and the grip-only drag surface (D24).
 */
interface DragInternals {
  _previewTemplate: { templateRef: TemplateRef<unknown>; data: unknown } | null;
  _placeholderTemplate: { templateRef: TemplateRef<unknown>; data: unknown } | null;
  _viewContainerRef: ViewContainerRef;
  _handles: { getValue(): { element: ElementRef<HTMLElement> }[] };
}

describe('GridViewComponent', () => {
  let fixture: ComponentFixture<GridViewComponent>;
  let config: CameraConfigService;
  let router: Router;
  let navigate: MockInstance;

  function gridHost(): HTMLElement {
    return fixture.nativeElement as HTMLElement;
  }

  function tileHosts(): HTMLElement[] {
    return Array.from(gridHost().querySelectorAll('app-camera-tile')) as HTMLElement[];
  }

  function players(): CameraPlayerComponent[] {
    return fixture.debugElement
      .queryAll(By.directive(CameraPlayerComponent))
      .map((debugEl) => debugEl.componentInstance as CameraPlayerComponent);
  }

  function cameraNames(): string[] {
    return tileHosts().map((host) =>
      ((host.querySelector('.tile__name') as HTMLElement).textContent ?? '').trim(),
    );
  }

  function dragInternals(): DragInternals[] {
    return fixture.debugElement
      .queryAll(By.directive(CdkDrag))
      .map((debugEl) => debugEl.injector.get(CdkDrag) as unknown as DragInternals);
  }

  function dropList(): CdkDropList {
    return fixture.debugElement.query(By.directive(CdkDropList)).injector.get(CdkDropList);
  }

  function buttons(): HTMLButtonElement[] {
    return Array.from(gridHost().querySelectorAll('button')) as HTMLButtonElement[];
  }

  function buttonByLabel(prefix: string): HTMLButtonElement {
    const match = buttons().find((button) =>
      (button.getAttribute('aria-label') ?? '').startsWith(prefix),
    );
    expect(match, `button labelled "${prefix}"`).toBeDefined();
    return match!;
  }

  function buttonByText(text: string): HTMLButtonElement {
    const match = buttons().find((button) => (button.textContent ?? '').trim() === text);
    expect(match, `button with text "${text}"`).toBeDefined();
    return match!;
  }

  function dropEvent(previousIndex: number, currentIndex: number): CdkDragDrop<unknown> {
    return { previousIndex, currentIndex } as CdkDragDrop<unknown>;
  }

  beforeEach(async () => {
    localStorage.clear();

    await TestBed.configureTestingModule({
      imports: [GridViewComponent],
      providers: [provideRouter([])],
    }).compileComponents();

    fixture = TestBed.createComponent(GridViewComponent);
    config = TestBed.inject(CameraConfigService);
    router = TestBed.inject(Router);
    navigate = vi.spyOn(router, 'navigate').mockResolvedValue(true);
  });

  afterEach(() => {
    fixture.destroy();
    vi.restoreAllMocks();
  });

  it('renders the four configured cameras in order', () => {
    fixture.detectChanges();

    expect(tileHosts()).toHaveLength(4);
    expect(cameraNames()).toEqual(['Cámara 1', 'Cámara 2', 'Cámara 3', 'Cámara 4']);
  });

  it('renders the cameras in the persisted order', () => {
    config.reorder(2, 0);

    fixture.detectChanges();

    expect(cameraNames()).toEqual(['Cámara 3', 'Cámara 1', 'Cámara 2', 'Cámara 4']);
  });

  it('wires a mixed-orientation drop list over four drag items identified by camera id', () => {
    fixture.detectChanges();

    const list = fixture.debugElement.query(By.directive(CdkDropList));
    expect(list).not.toBeNull();
    expect(dropList().orientation).toBe('mixed');

    const drags = fixture.debugElement.queryAll(By.directive(CdkDrag));
    expect(drags).toHaveLength(4);
    expect(drags.map((debugEl) => debugEl.injector.get(CdkDrag).data)).toEqual([
      'cam1',
      'cam2',
      'cam3',
      'cam4',
    ]);
    tileHosts().forEach((host) => expect(host.hasAttribute('cdkDrag')).toBe(true));
  });

  it('registers the grip as the only drag handle, so the cell body cannot start a drag (D24)', () => {
    fixture.detectChanges();

    const drags = dragInternals();
    expect(drags).toHaveLength(4);

    const grips = Array.from(gridHost().querySelectorAll('.tile__grip')) as HTMLElement[];
    expect(grips).toHaveLength(4);

    drags.forEach((drag, index) => {
      const handles = drag._handles.getValue();
      expect(handles).toHaveLength(1);
      expect(handles[0].element.nativeElement).toBe(grips[index]);
    });
  });

  it('registers preview and placeholder templates and renders the name chip without cloning the tile (D5)', () => {
    fixture.detectChanges();

    const drags = dragInternals();
    drags.forEach((drag) => {
      expect(drag._previewTemplate).not.toBeNull();
      expect(drag._placeholderTemplate).not.toBeNull();
    });

    // Same creation path CDK uses at drag start: template + its `data` context.
    const preview = drags[1]._previewTemplate!;
    const previewView = drags[1]._viewContainerRef.createEmbeddedView(
      preview.templateRef,
      preview.data,
    );
    previewView.detectChanges();
    const chip = previewView.rootNodes[0] as HTMLElement;
    expect(chip.textContent).toContain('Cámara 2');
    previewView.destroy();

    const placeholder = drags[1]._placeholderTemplate!;
    const placeholderView = drags[1]._viewContainerRef.createEmbeddedView(
      placeholder.templateRef,
      placeholder.data,
    );
    placeholderView.detectChanges();
    expect(placeholderView.rootNodes).toHaveLength(1);
    placeholderView.destroy();
  });

  it('reorders the service through the drop event using the drop indices', () => {
    fixture.detectChanges();
    const spy = vi.spyOn(config, 'reorder');

    dropList().dropped.emit(dropEvent(3, 0));
    fixture.detectChanges();

    expect(spy).toHaveBeenCalledWith(3, 0);
    expect(config.ordered().map((camera) => camera.id)).toEqual(['cam4', 'cam1', 'cam2', 'cam3']);
    expect(cameraNames()).toEqual(['Cámara 4', 'Cámara 1', 'Cámara 2', 'Cámara 3']);
  });

  it('keeps every tile and player instance alive across a reorder (no stream reconnect)', () => {
    fixture.detectChanges();
    const tilesBefore = tileHosts();
    const playersBefore = players();
    const destroyPlayer = vi.spyOn(CameraPlayerComponent.prototype, 'ngOnDestroy');

    dropList().dropped.emit(dropEvent(3, 0));
    fixture.detectChanges();

    const tilesAfter = tileHosts();
    const playersAfter = players();

    // Same DOM nodes, moved: Angular's @for is tracked by camera id.
    expect(tilesAfter).toHaveLength(4);
    expect(new Set(tilesAfter)).toEqual(new Set(tilesBefore));
    expect(tilesAfter[0]).toBe(tilesBefore[3]);
    expect(tilesAfter[3]).toBe(tilesBefore[2]);

    // Same component instances, each still bound to its own camera id.
    expect(new Set(playersAfter)).toEqual(new Set(playersBefore));
    expect(playersAfter[0]).toBe(playersBefore[3]);
    expect(playersAfter.map((player) => player.cameraId)).toEqual(['cam4', 'cam1', 'cam2', 'cam3']);

    // Nothing was torn down: no reconnect can happen (the player only
    // re-creates its element from ngOnDestroy/stopConnection).
    expect(destroyPlayer).not.toHaveBeenCalled();
  });

  it('opens the camera at the pressed position with keys 1-4', () => {
    config.reorder(3, 0); // order: cam4, cam1, cam2, cam3
    fixture.detectChanges();

    document.dispatchEvent(new KeyboardEvent('keydown', { key: '1' }));
    document.dispatchEvent(new KeyboardEvent('keydown', { key: '2' }));
    document.dispatchEvent(new KeyboardEvent('keydown', { key: '4' }));

    expect(navigate).toHaveBeenNthCalledWith(1, ['/cam', 'cam4']);
    expect(navigate).toHaveBeenNthCalledWith(2, ['/cam', 'cam1']);
    expect(navigate).toHaveBeenNthCalledWith(3, ['/cam', 'cam3']);
  });

  it('ignores keys that are not a camera position', () => {
    fixture.detectChanges();

    ['0', '5', 'a', 'Enter', 'ArrowLeft'].forEach((key) =>
      document.dispatchEvent(new KeyboardEvent('keydown', { key })),
    );

    expect(navigate).not.toHaveBeenCalled();
  });

  it('stays inert while the user types in an input or a textarea', () => {
    fixture.detectChanges();
    const input = document.createElement('input');
    const textarea = document.createElement('textarea');
    gridHost().append(input, textarea);

    input.dispatchEvent(new KeyboardEvent('keydown', { key: '1', bubbles: true }));
    textarea.dispatchEvent(new KeyboardEvent('keydown', { key: '2', bubbles: true }));

    expect(navigate).not.toHaveBeenCalled();
  });

  it('stays inert while a tile name is being edited', async () => {
    fixture.detectChanges();
    buttonByLabel('Renombrar').click();
    fixture.detectChanges();
    await fixture.whenStable();
    fixture.detectChanges();

    const editor = gridHost().querySelector('.tile__input') as HTMLInputElement;
    expect(editor).not.toBeNull();

    editor.dispatchEvent(new KeyboardEvent('keydown', { key: '1', bubbles: true }));

    expect(navigate).not.toHaveBeenCalled();
  });

  it('opens the single view through a tile open affordance', () => {
    fixture.detectChanges();

    buttonByLabel('Ampliar').click();

    expect(navigate).toHaveBeenCalledWith(['/cam', 'cam1']);
  });

  it('restores default names and order only after the reset is confirmed', () => {
    config.rename('cam1', 'Portón');
    config.reorder(1, 0); // order: cam2, cam1, cam3, cam4
    fixture.detectChanges();
    expect(cameraNames()).toEqual(['Cámara 2', 'Portón', 'Cámara 3', 'Cámara 4']);

    buttonByText('Restablecer').click();
    fixture.detectChanges();

    // First click only asks for confirmation.
    expect(cameraNames()).toEqual(['Cámara 2', 'Portón', 'Cámara 3', 'Cámara 4']);
    expect(gridHost().textContent).toContain('¿Restablecer');

    buttonByText('Cancelar').click();
    fixture.detectChanges();
    expect(cameraNames()).toEqual(['Cámara 2', 'Portón', 'Cámara 3', 'Cámara 4']);

    buttonByText('Restablecer').click();
    fixture.detectChanges();
    buttonByText('Sí, restablecer').click();
    fixture.detectChanges();

    expect(cameraNames()).toEqual(['Cámara 1', 'Cámara 2', 'Cámara 3', 'Cámara 4']);
    expect(config.config().find((camera) => camera.id === 'cam1')?.name).toBe('Cámara 1');
  });
});
