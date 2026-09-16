import { Injectable, OnDestroy, Signal, signal } from '@angular/core';

/** Visual tone of a toast message. */
export type ToastTone = 'info' | 'error';

export interface Toast {
  readonly text: string;
  readonly tone: ToastTone;
}

/** How long a toast stays on screen before clearing itself. */
export const TOAST_DURATION_MS = 2_500;

/**
 * App-level feedback seam for snapshot confirmations and error surfacing.
 *
 * The state is a plain signal, so all decision logic is DOM-free and the shell
 * template is the only place that renders it (design: toast replaces the
 * snapshot "flash").
 */
@Injectable({ providedIn: 'root' })
export class ToastService implements OnDestroy {
  private readonly messageSignal = signal<Toast | null>(null);
  private clearTID: number | null = null;

  /** Current toast, or `null` when nothing is shown. */
  readonly message: Signal<Toast | null> = this.messageSignal.asReadonly();

  /** Shows `text` and (re)starts the auto-clear timer. */
  show(text: string, tone: ToastTone = 'info'): void {
    this.cancelTimer();
    this.messageSignal.set({ text, tone });
    this.clearTID = window.setTimeout(() => this.dismiss(), TOAST_DURATION_MS);
  }

  /** Clears the toast immediately and cancels the pending auto-clear. */
  dismiss(): void {
    this.cancelTimer();
    this.messageSignal.set(null);
  }

  ngOnDestroy(): void {
    this.cancelTimer();
  }

  private cancelTimer(): void {
    if (this.clearTID !== null) {
      clearTimeout(this.clearTID);
      this.clearTID = null;
    }
  }
}
