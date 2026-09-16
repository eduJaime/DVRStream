# Visor de cámaras (DVR RTSP → go2rtc → Angular)

App web **sólo para red local** que muestra las 4 cámaras de un DVR (RTSP H.264)
en una grilla 2x2, con vista ampliada, nombres editables, reordenamiento por
drag & drop y snapshots JPG descargables. **Sin audio.**

- Puente RTSP → navegador: **go2rtc** (binario único, sin transcodificación)
- Protocolo: **WebRTC** con fallback a **MSE**
- Frontend: **Angular** (standalone + signals)
- Backend propio: **ninguno** (go2rtc sirve la API y los estáticos del front)
- Despliegue: **LXC Debian nativo, sin Docker**

El plan completo, fase por fase, está en [`PLAN-visor-camaras.md`](./PLAN-visor-camaras.md).

---

## Arquitectura

```
[DVR] --RTSP H.264--> [go2rtc en LXC]
                          ├── :1984  HTTP     -> API (/api/*) + front Angular
                          └── :8555  TCP/UDP  -> tráfico WebRTC
[Navegador en la LAN] --HTTP :1984--> front Angular
                      --WebRTC :8555--> video
```

El front y la API se sirven desde el **mismo origen**, así que no hay CORS.
Las credenciales RTSP viven **sólo** en `/etc/go2rtc/go2rtc.yaml` dentro del LXC.
**Nunca** se commitean al repo.

## Estructura del repo

```
DVRStream/
├── README.md
├── PLAN-visor-camaras.md
├── frontend/                  proyecto Angular
└── deploy/
    ├── go2rtc.example.yaml    muestra de referencia (el script genera el real)
    ├── go2rtc.service         unidad systemd
    ├── install-lxc.sh         provisioner interactivo (instala + configura)
    ├── tests/
    │   └── install-lxc.test.sh  tests sin dependencias del provisioner
    └── deploy-frontend.sh     build + publicación del front
```

---

## Requisitos

**Máquina de desarrollo**

- Node.js **LTS** (probado con v22) y npm
- `rsync` y acceso SSH al LXC
- Angular CLI no hace falta instalarlo global: se usa `npx ng ...`

**LXC**

- Debian 12, no privilegiado, 1 vCPU, 512 MB RAM, 4 GB disco
- IP **fija** en la LAN (en esta doc: `IP_LXC`)

---

## Puesta en marcha

### 1. Crear el LXC

Se crea a mano en Proxmox (Debian 12, no privilegiado, IP fija). Anotar la IP como `IP_LXC`.

### 2. Provisionar go2rtc (script interactivo)

```bash
scp -r deploy root@IP_LXC:/root/
ssh -t root@IP_LXC 'bash /root/deploy/install-lxc.sh'
```

El script es **idempotente** y el único dueño de la configuración: instala
dependencias y binario, crea el usuario `go2rtc` y los directorios, **pregunta**
los datos del DVR, valida, renderiza `/etc/go2rtc/go2rtc.yaml` (`0600`, dueño
`go2rtc`), instala la unidad systemd y **reinicia y verifica** el servicio.
No hay que editar ningún archivo a mano.

> `ssh` sin `-t` no asigna TTY y los prompts no pueden leer: usá `ssh -t`
> (o entrá al contenedor y corré el script ahí).

Datos que pide (cada default se acepta con `Enter`):

| Prompt | Default | Flag / entorno |
|---|---|---|
| Dirección publicada del LXC | IP de la ruta por defecto (`ip route get`) | `--address` / `LXC_ADDRESS` |
| IP o host del DVR | — (obligatorio) | `--dvr-host` / `DVR_HOST` |
| Usuario del DVR | — (obligatorio) | `--dvr-user` / `DVR_USER` |
| Contraseña del DVR | — (obligatorio, entrada oculta) | `--password-file` / `DVR_PASSWORD_FILE` |
| Ruta RTSP canal 1..4 | `/Streaming/Channels/101`, `201`, `301`, `401` | `--channels` / `DVR_CHANNELS` |

**La contraseña nunca se pasa por línea de comandos** (argv es visible en `ps` y
queda en el historial). Sólo se acepta por prompt oculto, por archivo con modo
`0600` o por stdin:

```bash
# archivo 0600 (creado en el LXC, nunca un secreto literal en la línea de comandos)
install -m 600 /dev/null /root/dvr.pw
printf '%s\n' 'TU_PASSWORD' > /root/dvr.pw
bash /root/deploy/install-lxc.sh --password-file /root/dvr.pw

# o por stdin, sin dejar el archivo en disco
cat /root/dvr.pw | bash /root/deploy/install-lxc.sh --password-file -
```

#### Run desatendido

```bash
bash /root/deploy/install-lxc.sh --yes \
  --address 192.168.1.50 --dvr-host 192.168.1.10 --dvr-user admin \
  --password-file /root/dvr.pw
```

`--yes` acepta los defaults (incluidas las rutas Hikvision) y saltea la
confirmación. Las rutas también se pueden pisar con `--channels "/a,/b,/c,/d"`.

#### Previsualizar sin tocar nada

```bash
bash /root/deploy/install-lxc.sh --dry-run --yes \
  --address 192.168.1.50 --dvr-host 192.168.1.10 --dvr-user admin \
  --password-file /root/dvr.pw
```

`--dry-run` valida y muestra el YAML por stdout **con la contraseña enmascarada**:
no escribe nada y no requiere root, así se puede probar antes de aplicar.

#### Rotar credenciales o cambiar rutas

Volver a correr el script es la forma soportada: vuelve a pedir los datos,
reemplaza la config de forma **atómica** (un lector nunca ve un archivo a medio
escribir) y reinicia el servicio. Antes de reemplazar, la config anterior queda
copiada en `/etc/go2rtc/go2rtc.yaml.prev` (`0600`).

#### Si el servicio no arranca

El propio script reporta el fallo con el comando exacto de diagnóstico y el
rollback:

```bash
journalctl -u go2rtc -n 50 --no-pager
cp /etc/go2rtc/go2rtc.yaml.prev /etc/go2rtc/go2rtc.yaml && systemctl restart go2rtc
```

Las URLs RTSP son las mismas que ya funcionan en VLC. `go2rtc.example.yaml`
quedó sólo como **muestra de referencia**: el script ya no lo copia.

### 3. Verificar go2rtc

Abrir `http://IP_LXC:1984/` desde otra máquina de la LAN. El script deja el
servicio activo y verificado; **antes** de publicar el front se ve la UI propia
de go2rtc con las 4 cámaras. Si las 4 se ven ahí, el puente RTSP → WebRTC
funciona.

### 4. Desplegar el front

```bash
cd deploy
./deploy-frontend.sh IP_LXC root
```

Hace `npm ci`, `ng build --configuration production` y `rsync --delete` del build
a `/opt/visor-camaras/www/`. Los estáticos se leen de disco en cada request, así
que **no hace falta reiniciar go2rtc**.

A partir de ahí, `http://IP_LXC:1984/` sirve la app Angular en vez de la UI de go2rtc.

### 5. Desarrollo local del front

```bash
cd frontend
npm install
npm start
```

`ng serve` usa `proxy.conf.json` para redirigir `/api` (incluido WebSocket) a
`http://IP_LXC:1984`, así en desarrollo también se trabaja "mismo origen".
Ajustar la IP del LXC **sólo** en `proxy.conf.json`: es el único archivo que
contiene el placeholder `IP_LXC`.

> **Desviación del plan (§4.3): base URL de desarrollo.**
> `PLAN-visor-camaras.md` §4.3 pide `environment.development.ts` con
> `go2rtcBaseUrl = 'http://IP_LXC:1984'`. Acá se usa `''` (mismo origen) y todo
> pasa por el proxy. **Por qué:** una URL absoluta en desarrollo hace las
> requests cross-origin, y go2rtc **no envía cabeceras CORS por defecto**, así
> que el video no conectaría; además el proxy quedaría sin uso. Con `''`,
> desarrollo y producción comparten la misma topología (mismo origen) y el
> placeholder `IP_LXC` vive en un solo archivo.

---

## Reproductor go2rtc (versión de los archivos)

El front reproduce el video con el reproductor oficial de go2rtc
(`video-rtc.js` + `video-stream.js`), copiado tal cual dentro de
`frontend/public/go2rtc/` y servido como módulo ES (`<script type="module">`).
El componente `CameraPlayerComponent` espera a `customElements.whenDefined('video-stream')`
antes de crear el elemento.

Los archivos corresponden **exactamente** a la versión:

| Archivo | Versión go2rtc | Origen |
|---|---|---|
| `frontend/public/go2rtc/video-rtc.js` | **v1.9.14** | `AlexxIT/go2rtc` tag `v1.9.14`, `www/video-rtc.js` |
| `frontend/public/go2rtc/video-stream.js` | **v1.9.14** | `AlexxIT/go2rtc` tag `v1.9.14`, `www/video-stream.js` |

`frontend/public/go2rtc/VERSION.txt` guarda el tag y los hashes `sha256`.
**Mantener estos archivos en sincronía** con la versión de go2rtc instalada en el LXC.

Prueba manual: crear `frontend/src/app/app.routes.ts` con una ruta que renderice
`<app-camera-player [cameraId]="'cam1'" />` (la Fase 4 agrega las rutas definitivas)
y abrir `http://localhost:4200/` con `npm start`.

---

## Firewall (Proxmox)

En el firewall de Proxmox, para este LXC:

- **Permitir** entrada a `1984/tcp` y `8555/tcp+udp` **sólo desde la subred local**
  (ej. `192.168.X.0/24`).
- **Denegar** el resto.
- **No** abrir puertos en el router.

### Advertencia de seguridad

go2rtc **no tiene autenticación** por defecto. Además, la API (`/api/streams`)
puede exponer las URLs de origen **con credenciales del DVR**. Por eso el acceso
debe quedar limitado a la LAN. Si en el futuro hace falta exponerlo, va detrás de
un reverse proxy con autenticación (fuera del alcance de este proyecto).

---

## Solución de problemas

**Video negro con WebRTC**

- Revisar que la IP publicada del LXC sea la real (no `IP_LXC`): volvé a correr
  el provisioner con `--address <IP>` si no coincide con la detectada.
- Verificar que `8555/tcp` y `8555/udp` estén abiertos en el firewall **desde la subred local**.
- Probar el fallback: si MSE funciona y WebRTC no, es casi siempre el punto anterior.

**"Sin señal" en una cámara**

- Probar la URL RTSP de esa cámara en VLC desde otra máquina.
- `journalctl -u go2rtc -n 50 --no-pager` en el LXC.

**La DVR limita conexiones simultáneas**

- go2rtc reutiliza **una sola** conexión RTSP por cámara aunque haya varios
  navegadores mirando el mismo stream. No hace falta hacer nada.

**`http://IP_LXC:1984/` sigue mostrando la UI de go2rtc**

- El front todavía no se publicó, o `api.static_dir` no apunta a `/opt/visor-camaras/www`.
- Verificar con `ls -la /opt/visor-camaras/www/`.

**La app no carga al recargar una ruta**

- El front usa **hash routing** (`/#/cam/cam2`), justamente para que el servidor
  estático no necesite reescribir rutas.

**Cambié el front pero sigo viendo el viejo**

- Recarga forzada (`Ctrl+Shift+R`). El navegador cachea los assets.

---

## Reglas del proyecto

- **No** commitear credenciales, IPs reales ni `go2rtc.yaml` real.
- **No** agregar backend, base de datos, Docker, autenticación ni audio.
- **No** agregar dependencias fuera de Angular y `@angular/cdk`.
- TypeScript estricto. Textos de UI en **español**; código e identificadores en inglés.
