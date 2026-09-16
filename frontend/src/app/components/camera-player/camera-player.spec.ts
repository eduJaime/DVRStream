import { ComponentFixture, TestBed } from '@angular/core/testing';
import { CameraPlayerComponent } from './camera-player';

describe('CameraPlayerComponent', () => {
  let fixture: ComponentFixture<CameraPlayerComponent>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [CameraPlayerComponent],
    }).compileComponents();

    fixture = TestBed.createComponent(CameraPlayerComponent);
    fixture.componentRef.setInput('cameraId', 'cam1');
  });

  afterEach(() => {
    fixture.destroy();
  });

  it('creates the component with a connecting status', () => {
    expect(fixture.componentInstance).toBeTruthy();
    expect(fixture.componentInstance.status()).toBe('connecting');
  });

  it('rejects snapshot() with a Spanish message when no frame is ready', async () => {
    await expect(fixture.componentInstance.snapshot()).rejects.toThrow(
      'La cámara todavía no está lista',
    );
  });
});
