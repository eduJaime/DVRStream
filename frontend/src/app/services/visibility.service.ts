import { Injectable, OnDestroy, Signal, signal } from '@angular/core';

/**
 * Single source of truth for tab visibility (`document.visibilitychange`).
 *
 * The camera players read `tabVisible` from this signal instead of each
 * registering their own listener, so N players share exactly one seam
 * (design D4).
 */
@Injectable({ providedIn: 'root' })
export class VisibilityService implements OnDestroy {
  private readonly visibleSignal = signal(!document.hidden);

  /** True while the browser tab is visible. */
  readonly tabVisible: Signal<boolean> = this.visibleSignal.asReadonly();

  private readonly onChange = (): void => this.visibleSignal.set(!document.hidden);

  constructor() {
    document.addEventListener('visibilitychange', this.onChange);
  }

  ngOnDestroy(): void {
    document.removeEventListener('visibilitychange', this.onChange);
  }
}
