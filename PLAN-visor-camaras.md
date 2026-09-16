# Plan de implementación: Visor web de cámaras (DVR RTSP → go2rtc → Angular)

> Documento para un agente de IA (Cursor / Copilot). Ejecutar por fases, en orden. No avanzar de fase sin cumplir los criterios de aceptación. Ante cualquier duda de diseño no cubierta acá, **preguntar al usuario antes de inventar**.

---

## 0. Contexto y objetivo

- Hay una DVR con **4 cámaras** que expone streams **RTSP en H.264** (solo stream principal, no hay substream). Las URLs ya funcionan en VLC.
- Objetivo: una app web accesible **solo en la red local** que:
  1. Muestre las 4 cámaras en una grilla 2x2.
  2. Permita agrandar una cámara a vista única (y volver a la grilla).
  3. Permita **editar el nombre** de cada cámara.
  4. Permita **reordenar** las cámaras en la grilla (drag & drop).
  5. Permita **sacar un snapshot** (captura JPG descargable) de cualquier cámara.
  6. **Sin audio** (los videos siempre `muted`, sin controles de audio).
- Infraestructura: servidor **Proxmox**, despliegue en un **LXC Debian nativo, sin Docker**.

### Decisiones cerradas (no cambiar)

| Tema | Decisión |
|---|---|
| Puente RTSP → navegador | **go2rtc** (binario único), sin transcodificación |
| Protocolo al navegador | **WebRTC** como principal, **MSE** como fallback |
| Frontend | **Angular** (última versión estable, standalone components, signals) |
| Backend | **Ninguno propio**. go2rtc sirve la API de streaming y los archivos estáticos del front |
| Persistencia de nombres/orden | `localStorage` del navegador (por dispositivo) |
| Snapshot | Captura **del lado cliente** desde el `<video>` usando `<canvas>` (no requiere ffmpeg) |
| Despliegue | LXC Debian + go2rtc como servicio `systemd` |
| Acceso | Solo LAN; sin puertos abiertos en el router; firewall de Proxmox restringido a la subred local |

---

## 1. Arquitectura

```
[DVR] --RTSP H.264--> [go2rtc en LXC]
                          ├── :1984  HTTP  → API (/api/*) + archivos estáticos del front Angular
                          └── :8555  TCP/UDP → tráfico WebRTC
[Navegador en la LAN] --HTTP :1984--> front Angular
                      --WebRTC :8555--> video
```

- El front y la API de go2rtc se sirven **desde el mismo origen** (`http://IP_LXC:1984`), así no hay problemas de CORS.
- Las credenciales RTSP viven **solo** en `go2rtc.yaml` dentro del LXC. **Nunca** en el repo ni en el código del front.

---

## 2. Estructura del repositorio

```
visor-camaras/
├── README.md
├── PLAN-visor-camaras.md          (este documento)
├── frontend/                      (proyecto Angular)
├── deploy/
│   ├── go2rtc.example.yaml        (plantilla SIN credenciales reales)
│   ├── go2rtc.service             (unidad systemd)
│   ├── install-lxc.sh             (instalación inicial en el LXC)
│   └── deploy-frontend.sh         (build + copia al LXC)
└── .gitignore                     (debe excluir go2rtc.yaml real, node_modules, dist)
```

---

## 3. Fase 1 — go2rtc en el LXC (infraestructura)

> El usuario crea el LXC manualmente en Proxmox. El agente prepara los scripts y archivos.

### 3.1 LXC sugerido (lo crea el usuario)
- Debian 12, **no privilegiado**, 1 vCPU, 512 MB RAM, 4 GB disco.
- IP **fija** en la LAN (anotarla como `IP_LXC`).

### 3.2 `deploy/install-lxc.sh`
El script debe:
1. Instalar `curl` y `ca-certificates`.
2. Descargar el binario más reciente de go2rtc para `linux_amd64` desde los releases oficiales de GitHub (`AlexxIT/go2rtc`) a `/usr/local/bin/go2rtc` y darle permiso de ejecución.
3. Crear el usuario de sistema `go2rtc` (sin shell de login).
4. Crear `/etc/go2rtc/` y `/opt/visor-camaras/www/`, con dueño `go2rtc`.
5. Copiar `go2rtc.example.yaml` a `/etc/go2rtc/go2rtc.yaml` **solo si no existe**, con permisos `600`.
6. Instalar y habilitar `go2rtc.service`.
7. Ser idempotente (poder correrlo dos veces sin romper nada).

### 3.3 `deploy/go2rtc.example.yaml`

```yaml
api:
  listen: ":1984"
  static_dir: "/opt/visor-camaras/www"   # sirve el build de Angular

rtsp:
  listen: ""          # no re-exponer RTSP: no se necesita

webrtc:
  listen: ":8555"
  candidates:
    - IP_LXC:8555     # reemplazar por la IP fija del LXC

streams:
  cam1: rtsp://USUARIO:PASSWORD@IP_DVR:554/RUTA_CAM1
  cam2: rtsp://USUARIO:PASSWORD@IP_DVR:554/RUTA_CAM2
  cam3: rtsp://USUARIO:PASSWORD@IP_DVR:554/RUTA_CAM3
  cam4: rtsp://USUARIO:PASSWORD@IP_DVR:554/RUTA_CAM4

log:
  level: info
```

> Los IDs `cam1..cam4` son **fijos** y son lo que usa el front. Los nombres visibles se manejan en el front.

### 3.4 `deploy/go2rtc.service`
- `ExecStart=/usr/local/bin/go2rtc -config /etc/go2rtc/go2rtc.yaml`
- `User=go2rtc`, `Restart=always`, `RestartSec=5`
- `After=network-online.target`

### 3.5 Seguridad de red (documentar en README, lo hace el usuario)
- **No** abrir puertos en el router.
- En el firewall de Proxmox para el LXC: permitir entrada a `1984/tcp` y `8555/tcp+udp` **solo desde la subred local** (ej. `192.168.X.0/24`, confirmar con el usuario); denegar el resto.
- Advertencia a documentar: la API de go2rtc (`/api/streams`) puede exponer las URLs de origen con credenciales. Por eso el acceso debe quedar limitado a la LAN.

### ✅ Criterios de aceptación Fase 1
- `systemctl status go2rtc` activo y reinicia solo tras un `kill`.
- `http://IP_LXC:1984/` (UI propia de go2rtc, antes de copiar el front) muestra las 4 cámaras reproduciendo.
- Desde fuera de la subred local el puerto no responde.

---

## 4. Fase 2 — Proyecto Angular base

1. Crear el proyecto en `frontend/` con Angular CLI: standalone, **sin SSR**, estilos SCSS, routing habilitado.
2. Routing con **hash** (`withHashLocation()`), para que recargar la página no dé 404 al servirse como estático.
3. `environment.ts` con `go2rtcBaseUrl`:
   - En producción: cadena vacía (mismo origen).
   - En desarrollo: `http://IP_LXC:1984` (configurable).
4. Configurar `proxy.conf.json` para `ng serve` que redirija `/api` a `http://IP_LXC:1984` (incluyendo WebSocket, `ws: true`), así en desarrollo también se trabaja "mismo origen".
5. Sin librerías de UI pesadas. Permitido: `@angular/cdk` (para drag & drop). Nada más sin preguntar.

### Modelo de datos

```ts
export interface CameraConfig {
  id: 'cam1' | 'cam2' | 'cam3' | 'cam4'; // ID del stream en go2rtc, inmutable
  name: string;                           // nombre visible, editable
  order: number;                          // posición 0..3 en la grilla
}
```

### ✅ Criterios de aceptación Fase 2
- `ng serve` levanta sin errores ni warnings.
- `ng build` genera un `dist/` estático.

---

## 5. Fase 3 — Conexión de video (componente `CameraPlayer`)

### 5.1 Enfoque
Usar el reproductor oficial de go2rtc (`video-rtc.js` / `video-stream.js`, que go2rtc sirve y que también está en su repo en `www/`), envuelto en un componente Angular:

- **Opción preferida:** copiar `video-rtc.js` y `video-stream.js` de la **misma versión** de go2rtc instalada a `frontend/src/assets/go2rtc/` y cargarlos como módulo. Registran el custom element `<video-stream>`.
- Usar `CUSTOM_ELEMENTS_SCHEMA` **solo** en `CameraPlayerComponent`.
- Configurar el elemento con:
  - `mode = "webrtc,mse"` (WebRTC primero, MSE de fallback)
  - `media = "video"` (**sin audio**)
  - `src = new URL('api/ws?src=' + id, base)` convertido a `ws://`
- Documentar en el README qué versión de go2rtc corresponde a esos archivos.

> Si la integración con el custom element resulta problemática, **frenar y consultar** antes de reimplementar WebRTC a mano.

### 5.2 API del componente

```ts
@Input({ required: true }) cameraId: string;
@Input() active = true;          // si es false, desconecta el stream
@Output() statusChange = new EventEmitter<'connecting' | 'playing' | 'error'>();
snapshot(): Promise<Blob>        // ver Fase 6
```

### 5.3 Comportamiento requerido
- El `<video>` interno siempre `muted`, `playsinline`, `autoplay`, **sin controles** nativos.
- `object-fit: contain` (no recortar imagen).
- Mostrar overlay de estado: "Conectando…", y en error "Sin señal" + botón **Reintentar**.
- Reintento automático con backoff (5s, 10s, 20s, tope 30s) si se cae la conexión.
- Al destruir el componente o con `active = false`: **cerrar la conexión** (remover el elemento o limpiar su `src`) para no dejar streams abiertos.

### 5.4 Consumo de recursos (importante: solo hay stream principal)
Como no existe substream, cada cámara en la grilla consume su stream en resolución completa:
- En **vista ampliada**, las 3 cámaras no visibles deben quedar con `active = false` (desconectadas).
- Si la pestaña pasa a segundo plano (`document.visibilitychange`), desconectar todas; reconectar al volver.

### ✅ Criterios de aceptación Fase 3
- Una página de prueba muestra `cam1` reproduciendo con latencia menor a ~1 segundo.
- Al desconectar la red de la DVR aparece "Sin señal" y se recupera sola al volver.
- En la UI de go2rtc (`/api/streams`) se ve que los consumidores bajan al desactivar cámaras.

---

## 6. Fase 4 — Grilla y vista ampliada

### 6.1 Rutas
- `/` → `GridViewComponent` (2x2)
- `/cam/:id` → `SingleViewComponent` (una cámara a pantalla grande)

### 6.2 Grilla
- CSS Grid 2x2 que ocupa todo el viewport, sin scroll, celdas con relación de aspecto preservada.
- En pantallas angostas (< 700 px) pasar a 1 columna con scroll vertical.
- Cada celda muestra: video, nombre de la cámara (overlay inferior), y botones al hacer hover: **Ampliar**, **Snapshot**, **Renombrar**.
- **Doble click** en la celda → navega a `/cam/:id`.

### 6.3 Vista ampliada
- La cámara ocupa todo el espacio disponible.
- Botones: **Volver a la grilla**, **Pantalla completa** (Fullscreen API del navegador), **Snapshot**.
- Teclado: `Esc` o `Backspace` vuelve a la grilla; teclas `1`–`4` saltan a la cámara en esa posición; `F` alterna pantalla completa.
- En la grilla, teclas `1`–`4` también abren esa cámara ampliada.

### ✅ Criterios de aceptación Fase 4
- Las 4 cámaras se ven en la grilla simultáneamente.
- Ampliar/volver funciona con mouse y teclado, y recargar en `/#/cam/cam2` abre directo esa cámara.

---

## 7. Fase 5 — Nombres editables y reordenamiento

### 7.1 `CameraConfigService`
- Fuente de verdad: un `signal<CameraConfig[]>`.
- Valores por defecto: `Cámara 1..4`, orden `0..3`.
- Persistir en `localStorage` bajo la clave `visor-camaras.config.v1`.
- Al leer: validar la estructura; si está corrupta o incompleta, volver a los valores por defecto **sin romper la app**.
- Métodos: `rename(id, name)`, `reorder(fromIndex, toIndex)`, `reset()`.

### 7.2 Renombrar
- Edición inline al tocar "Renombrar" (o doble click sobre el nombre): input con el nombre actual, `Enter` guarda, `Esc` cancela.
- Validación: 1 a 30 caracteres, sin espacios al inicio/fin.

### 7.3 Reordenar
- Drag & drop entre celdas con `@angular/cdk/drag-drop`.
- Al reordenar **no** se deben reconectar los streams innecesariamente (usar `track` por `id` en el `@for`).
- Botón discreto "Restablecer" (nombres y orden por defecto) con confirmación.

### ✅ Criterios de aceptación Fase 5
- Renombrar y reordenar persisten tras recargar la página.
- Reordenar no provoca pantallazo negro/reconexión visible.
- Borrar la clave de `localStorage` o dejar JSON inválido no rompe la app.

---

## 8. Fase 6 — Snapshot

- Implementar `snapshot()` en `CameraPlayerComponent`:
  1. Tomar el `<video>` interno del custom element.
  2. Crear un `<canvas>` con `videoWidth` × `videoHeight` (resolución real, no la del contenedor).
  3. `drawImage` y exportar con `canvas.toBlob(..., 'image/jpeg', 0.92)`.
- Descargar el archivo con nombre: `{nombre-camara}_{AAAA-MM-DD_HH-mm-ss}.jpg` (nombre normalizado: sin tildes ni espacios).
- Si el video aún no tiene frames (`readyState < 2`), mostrar aviso "La cámara todavía no está lista".
- Feedback visual breve (flash o toast) al capturar.

### ✅ Criterios de aceptación Fase 6
- El JPG descargado tiene la resolución nativa de la cámara y la imagen correcta.
- Funciona tanto desde la grilla como desde la vista ampliada.

---

## 9. Fase 7 — Despliegue

### `deploy/deploy-frontend.sh`
Parámetro: `IP_LXC` (y usuario SSH).
1. `npm ci` y `ng build --configuration production` en `frontend/`.
2. Copiar el contenido de `dist/.../browser/` a `/opt/visor-camaras/www/` del LXC (usar `rsync --delete` o `scp`).
3. Ajustar dueño a `go2rtc`.
4. No hace falta reiniciar go2rtc para archivos estáticos (verificar; si hiciera falta, reiniciar el servicio).

### README debe incluir
- Requisitos (Node LTS en la PC de desarrollo).
- Pasos de instalación del LXC, cómo editar `go2rtc.yaml` y cómo desplegar el front.
- Reglas de firewall de Proxmox recomendadas.
- Solución de problemas comunes:
  - Video negro con WebRTC → revisar `candidates` con la IP correcta del LXC y el puerto 8555 abierto en el firewall.
  - "Sin señal" → probar la URL RTSP en VLC y revisar `journalctl -u go2rtc`.
  - La DVR limita conexiones simultáneas → go2rtc reutiliza **una** conexión por cámara aunque haya varios navegadores mirando.

### ✅ Criterios de aceptación Fase 7
- Entrando a `http://IP_LXC:1984/` desde otra PC o celular de la LAN se ve la app completa (no la UI propia de go2rtc).
- Tras reiniciar el LXC todo vuelve a funcionar sin intervención.

---

## 10. Reglas generales para el agente

- **No** commitear credenciales, IPs reales ni `go2rtc.yaml` real.
- **No** agregar backend, base de datos, Docker, autenticación ni audio: están fuera de alcance.
- **No** agregar dependencias fuera de Angular y `@angular/cdk` sin preguntar.
- Código en TypeScript estricto; textos de la UI en español.
- Tests unitarios mínimos para `CameraConfigService` (persistencia, validación, reorder) y para el normalizador de nombres de archivo de snapshot.
- Al terminar cada fase: resumir qué se hizo, cómo probarlo y qué quedó pendiente.

## 11. Datos que el usuario debe completar

- `IP_LXC` (IP fija del contenedor)
- `IP_DVR`, usuario, contraseña y ruta RTSP de cada cámara (solo en el LXC)
- Subred local para el firewall (ej. `192.168.X.0/24`)
