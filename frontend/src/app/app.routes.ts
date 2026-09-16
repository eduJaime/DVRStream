import { Routes } from '@angular/router';

import { GridViewComponent } from './components/grid-view/grid-view';

export const routes: Routes = [
  { path: '', component: GridViewComponent },
  // Unknown paths are not a dead end; PR5 adds `cam/:id` before this entry.
  { path: '**', redirectTo: '' },
];
