# @nathanclaire/rum-cordova

Real User Monitoring for Cordova apps on Android and iOS.

## Router recipes

By default, screens are named from the URL: the hash route if there is one (`#/…`), else the path. The query is dropped and ids become `{id}`. If your app uses a router, report the router's own route template instead: turn URL capture off before `deviceready`, then call `trackScreen()` when each navigation ends.

```js
EdgeRum.init({ captureScreens: false });
```

Pass a template (`/orders/:id`), never the live URL (`/orders/1234`).

### Angular Router

```ts
import { Component, inject } from '@angular/core';
import { NavigationEnd, Router, type ActivatedRouteSnapshot } from '@angular/router';
import { filter } from 'rxjs';

@Component({ selector: 'app-root', templateUrl: './app.component.html' })
export class AppComponent {
  constructor() {
    const router = inject(Router);
    router.events.pipe(filter((e) => e instanceof NavigationEnd)).subscribe(() => {
      const parts: string[] = [];
      for (let r: ActivatedRouteSnapshot | null = router.routerState.snapshot.root; r; r = r.firstChild) {
        if (r.routeConfig?.path) parts.push(r.routeConfig.path);
      }
      window.EdgeRum.trackScreen('/' + parts.join('/'));
    });
  }
}
```

### Vue Router

```ts
router.afterEach((to, _from, failure) => {
  if (!failure) window.EdgeRum.trackScreen(to.matched.at(-1)?.path ?? 'not-found');
});
```

### React Router

Render this once inside your router. `routes` is the same route array you give the router.

```tsx
import { useEffect } from 'react';
import { matchRoutes, useLocation } from 'react-router';
import { routes } from './routes';

export function ScreenTracker() {
  const location = useLocation();
  useEffect(() => {
    const path = (matchRoutes(routes, location) ?? []).map((m) => m.route.path).filter(Boolean).join('/');
    window.EdgeRum.trackScreen(('/' + path).replace(/\/+/g, '/'));
  }, [location.pathname]);
  return null;
}
```

### AngularJS ui-router

```js
angular.module('app').run(['$transitions', function ($transitions) {
  $transitions.onSuccess({}, function (trans) {
    window.EdgeRum.trackScreen(trans.to().name);
  });
}]);
```
