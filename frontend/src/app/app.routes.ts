import { inject } from '@angular/core';
import { CanActivateFn, Router, Routes, UrlTree } from '@angular/router';

import { GridViewComponent } from './components/grid-view/grid-view';
import { SingleViewComponent } from './components/single-view/single-view';
import { resolveCameraId } from './models/camera-config';

/**
 * Keeps `cam/:id` for the four configured cameras only: an unknown id is a
 * redirect to the grid, never a broken view (design D2).
 */
export const cameraIdGuard: CanActivateFn = (route): boolean | UrlTree => {
  const router = inject(Router);
  return resolveCameraId(route.paramMap.get('id')) !== null ? true : router.createUrlTree(['/']);
};

export const routes: Routes = [
  { path: '', component: GridViewComponent },
  { path: 'cam/:id', component: SingleViewComponent, canActivate: [cameraIdGuard] },
  // Unknown paths are not a dead end.
  { path: '**', redirectTo: '' },
];
