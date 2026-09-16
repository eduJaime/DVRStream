import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { App } from './app';
import { ToastService } from './services/toast.service';

describe('App', () => {
  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [App],
      providers: [provideRouter([])],
    }).compileComponents();
  });

  it('renders the router outlet that hosts the active route', () => {
    const fixture = TestBed.createComponent(App);
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('router-outlet')).not.toBeNull();
  });

  it('renders the current toast message from the shell', () => {
    const fixture = TestBed.createComponent(App);
    fixture.detectChanges();
    expect(fixture.nativeElement.textContent).not.toContain('Captura guardada');

    TestBed.inject(ToastService).show('Captura guardada');
    fixture.detectChanges();

    const toast = fixture.nativeElement.querySelector('.toast') as HTMLElement;
    expect(toast.textContent).toContain('Captura guardada');
    expect(toast.getAttribute('role')).toBe('status');

    TestBed.inject(ToastService).dismiss();
  });

  it('announces error toasts as alerts', () => {
    const fixture = TestBed.createComponent(App);
    fixture.detectChanges();

    TestBed.inject(ToastService).show('La cámara todavía no está lista', 'error');
    fixture.detectChanges();

    const toast = fixture.nativeElement.querySelector('.toast') as HTMLElement;
    expect(toast.textContent).toContain('La cámara todavía no está lista');
    expect(toast.getAttribute('role')).toBe('alert');

    TestBed.inject(ToastService).dismiss();
  });
});
