import { ToastService } from './toast.service';

describe('ToastService', () => {
  let service: ToastService;

  beforeEach(() => {
    vi.useFakeTimers();
    service = new ToastService();
  });

  afterEach(() => {
    service.ngOnDestroy();
    vi.useRealTimers();
  });

  it('shows the toast text with the default info tone', () => {
    service.show('Captura guardada');
    expect(service.message()).toEqual({ text: 'Captura guardada', tone: 'info' });
  });

  it('shows an error toast with the error tone', () => {
    service.show('La cámara todavía no está lista', 'error');
    expect(service.message()).toEqual({
      text: 'La cámara todavía no está lista',
      tone: 'error',
    });
  });

  it('auto-clears the toast after 2.5 seconds', () => {
    service.show('Captura guardada');

    vi.advanceTimersByTime(2_499);
    expect(service.message()).not.toBeNull();

    vi.advanceTimersByTime(1);
    expect(service.message()).toBeNull();
  });

  it('restarts the auto-clear timer when a new toast replaces the current one', () => {
    service.show('Primera');
    vi.advanceTimersByTime(2_000);

    service.show('Segunda');
    vi.advanceTimersByTime(600); // the first toast timer would have fired at 2.5s
    expect(service.message()).toEqual({ text: 'Segunda', tone: 'info' });

    vi.advanceTimersByTime(1_900);
    expect(service.message()).toBeNull();
  });

  it('clears immediately on dismiss and cancels the pending timer', () => {
    service.show('Captura guardada');
    service.dismiss();
    expect(service.message()).toBeNull();

    vi.advanceTimersByTime(2_500);
    expect(service.message()).toBeNull();
  });

  it('cancels the pending auto-clear on destroy', () => {
    service.show('Captura guardada');
    service.ngOnDestroy();

    vi.advanceTimersByTime(2_500);
    expect(service.message()).toEqual({ text: 'Captura guardada', tone: 'info' });
  });
});
