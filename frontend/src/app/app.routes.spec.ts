import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { RouterTestingHarness } from '@angular/router/testing';

import { routes } from './app.routes';

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
});
