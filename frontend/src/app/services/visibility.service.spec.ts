import { TestBed } from '@angular/core/testing';
import { VisibilityService } from './visibility.service';

function spyHidden(initiallyHidden: boolean): ReturnType<typeof vi.spyOn> {
  return vi.spyOn(document, 'hidden', 'get').mockReturnValue(initiallyHidden);
}

describe('VisibilityService', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('reads the initial tab visibility from the document', () => {
    spyHidden(true);
    const service = new VisibilityService();
    expect(service.tabVisible()).toBe(false);
    service.ngOnDestroy();
  });

  it('registers exactly one visibilitychange listener', () => {
    const addSpy = vi.spyOn(document, 'addEventListener');
    const service = new VisibilityService();

    const registered = addSpy.mock.calls.filter(([type]) => type === 'visibilitychange');
    expect(registered).toHaveLength(1);

    service.ngOnDestroy();
  });

  it('updates tabVisible when visibilitychange fires', () => {
    const hidden = spyHidden(false);
    const service = new VisibilityService();
    expect(service.tabVisible()).toBe(true);

    hidden.mockReturnValue(true);
    document.dispatchEvent(new Event('visibilitychange'));
    expect(service.tabVisible()).toBe(false);

    hidden.mockReturnValue(false);
    document.dispatchEvent(new Event('visibilitychange'));
    expect(service.tabVisible()).toBe(true);

    service.ngOnDestroy();
  });

  it('removes its listener on destroy', () => {
    const addSpy = vi.spyOn(document, 'addEventListener');
    const removeSpy = vi.spyOn(document, 'removeEventListener');
    const service = new VisibilityService();

    const handler = addSpy.mock.calls.find(([type]) => type === 'visibilitychange')?.[1];
    expect(handler).toBeTypeOf('function');

    service.ngOnDestroy();
    expect(removeSpy).toHaveBeenCalledWith('visibilitychange', handler);
  });

  it('is a singleton: two consumers share one listener and one signal', () => {
    const addSpy = vi.spyOn(document, 'addEventListener');
    const first = TestBed.inject(VisibilityService);
    const second = TestBed.inject(VisibilityService);

    expect(first).toBe(second);

    const registered = addSpy.mock.calls.filter(([type]) => type === 'visibilitychange');
    expect(registered).toHaveLength(1);
  });
});
