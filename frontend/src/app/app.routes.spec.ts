import { TestBed } from '@angular/core/testing';
import { By } from '@angular/platform-browser';
import {
  ActivatedRouteSnapshot,
  RouterStateSnapshot,
  UrlTree,
  convertToParamMap,
  provideRouter,
} from '@angular/router';
import { RouterTestingHarness } from '@angular/router/testing';
import type { MockInstance } from 'vitest';

import { cameraIdGuard, routes } from './app.routes';
import { CameraPlayerComponent } from './components/camera-player/camera-player';

/**
 * Minimal stand-in for the vendored `<video-stream>` element (same pattern as
 * `grid-view.spec.ts`). With a live element registered, teardown actually
 * removes a stream: without it `teardownPlayer()` returns before touching
 * anything and the assertions below prove nothing (finding W4).
 */
class FakeVideoStreamElement extends HTMLElement {
  mode = '';
  media = '';
  src = '';
  background = false;
  visibilityCheck = true;
  reconnectTID = 0;
  disconnectTID = 0;
  video: HTMLVideoElement | null = null;
  onmessage: Record<string, (msg: { type: string; value?: unknown }) => void> | null = null;

  disconnectCalls = 0;

  onconnect(): boolean {
    return true;
  }

  onopen(): string[] {
    this.onmessage = { stream: () => undefined };
    return ['webrtc'];
  }

  override onclose = (): boolean => true;

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

/** Runtime access to the player's teardown path (private at the type level). */
interface PlayerInternals {
  stopConnection(): void;
}

function routeSnapshot(id: string): ActivatedRouteSnapshot {
  return { paramMap: convertToParamMap({ id }) } as ActivatedRouteSnapshot;
}

function players(harness: RouterTestingHarness): CameraPlayerComponent[] {
  return harness
    .routeDebugElement!.queryAll(By.directive(CameraPlayerComponent))
    .map((debugEl) => debugEl.componentInstance as CameraPlayerComponent);
}

/**
 * Observes the exact stream-teardown path of a player: cancel retry, clear the
 * connect timeout and remove the element (closing its socket). Spied per
 * instance because Angular binds `ngOnDestroy` at compile time, so a prototype
 * spy would never intercept it.
 */
function spyOnTeardown(player: CameraPlayerComponent): MockInstance {
  return vi.spyOn(player as unknown as PlayerInternals, 'stopConnection');
}

describe('app routes', () => {
  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideRouter(routes)],
    });
  });

  it('renders the camera grid at the root route', async () => {
    const harness = await RouterTestingHarness.create('/');

    const host = harness.routeNativeElement as HTMLElement;
    expect(host.tagName.toLowerCase()).toBe('app-grid-view');
    expect(host.querySelectorAll('app-camera-tile')).toHaveLength(4);
  });

  it('redirects an unknown path back to the grid instead of a dead end', async () => {
    const harness = await RouterTestingHarness.create('/ruta-desconocida');

    expect((harness.routeNativeElement as HTMLElement).tagName.toLowerCase()).toBe('app-grid-view');
  });

  it('renders the single view for a configured camera deep link', async () => {
    const harness = await RouterTestingHarness.create('/cam/cam2');

    const host = harness.routeNativeElement as HTMLElement;
    expect(host.tagName.toLowerCase()).toBe('app-single-view');
    expect(players(harness)).toHaveLength(1);
    expect(players(harness)[0].cameraId).toBe('cam2');
    expect(host.querySelector('.single-view__name')?.textContent?.trim()).toBe('Cámara 2');
  });

  it('redirects an unknown camera id to the grid instead of rendering a broken view', async () => {
    const harness = await RouterTestingHarness.create('/cam/nope');

    expect((harness.routeNativeElement as HTMLElement).tagName.toLowerCase()).toBe('app-grid-view');
  });

  it('closes the grid streams when the single view opens, and its own when going back (D2)', async () => {
    const harness = await RouterTestingHarness.create('/');
    await harness.fixture.whenStable();
    const gridHost = harness.routeNativeElement as HTMLElement;
    const gridPlayers = players(harness);
    expect(gridPlayers).toHaveLength(4);

    // Precondition: every grid player holds a live element. Only then does the
    // teardown below prove a real stream was closed (finding W4).
    const gridElements = Array.from(
      gridHost.querySelectorAll('video-stream'),
    ) as FakeVideoStreamElement[];
    expect(gridElements).toHaveLength(4);

    const gridStops = gridPlayers.map(spyOnTeardown);

    await harness.navigateByUrl('/cam/cam2');

    // The route swap destroyed the grid, so its four streams are closed by
    // teardown — not left open behind the single view.
    gridStops.forEach((stop) => expect(stop).toHaveBeenCalledTimes(1));
    gridElements.forEach((element) => {
      expect(element.disconnectCalls).toBeGreaterThan(0);
      expect(element.isConnected).toBe(false);
    });
    expect(players(harness)).toHaveLength(1);

    const singleHost = harness.routeNativeElement as HTMLElement;
    const singleElement = singleHost.querySelector('video-stream') as FakeVideoStreamElement | null;
    expect(singleElement).not.toBeNull();
    const singleStop = spyOnTeardown(players(harness)[0]);

    await harness.navigateByUrl('/');

    // Leaving the single view closed its stream too; the grid was rebuilt
    // with fresh players (none of the original instances survived).
    expect(singleStop).toHaveBeenCalledTimes(1);
    expect(singleElement!.disconnectCalls).toBeGreaterThan(0);
    expect(singleElement!.isConnected).toBe(false);
    expect(players(harness)).toHaveLength(4);
    players(harness).forEach((player) => expect(gridPlayers).not.toContain(player));
  });

  it('switches cameras inside the single view without recreating the player', async () => {
    const harness = await RouterTestingHarness.create('/cam/cam2');
    await harness.fixture.whenStable();
    const player = players(harness)[0];
    const stop = spyOnTeardown(player);
    const firstElement = (harness.routeNativeElement as HTMLElement).querySelector(
      'video-stream',
    ) as FakeVideoStreamElement | null;
    expect(firstElement).not.toBeNull();

    await harness.navigateByUrl('/cam/cam4');

    // The component instance survives the param change...
    expect(players(harness)).toEqual([player]);
    expect(player.cameraId).toBe('cam4');
    // ...and its old stream is closed: that socket belonged to cam2.
    expect(stop).toHaveBeenCalledTimes(1);
    expect(firstElement!.isConnected).toBe(false);

    await harness.fixture.whenStable();
    expect(
      (harness.routeNativeElement as HTMLElement).querySelector('video-stream'),
    ).not.toBeNull();
  });

  it('allows a configured camera id and redirects an unknown one (guard)', () => {
    const state = {} as RouterStateSnapshot;

    const allowed = TestBed.runInInjectionContext(() =>
      cameraIdGuard(routeSnapshot('cam3'), state),
    );
    expect(allowed).toBe(true);

    const refused = TestBed.runInInjectionContext(() =>
      cameraIdGuard(routeSnapshot('nope'), state),
    );
    expect(refused).toBeInstanceOf(UrlTree);
    expect(String(refused)).toBe('/');
  });
});
