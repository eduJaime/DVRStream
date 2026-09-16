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
├── VERIFICACION-MANUAL.md     checklist de hardware real (LXC + DVR)
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
Para cerrar el despliegue, corré el checklist de hardware real:
[`VERIFICACION-MANUAL.md`](./VERIFICACION-MANUAL.md).

### 5. Desarrollo local del front

```bash
cd frontend
npm install
npm start
```

`ng serve` usa `proxy.conf.json` para redirigir `/api` (incluido WebSocket) a
`http://IP_LXC:1984`, así en desarrollo también se trabaja "mismo origen".
**Reemplazá el placeholder `IP_LXC` por la IP real del LXC en `proxy.conf.json`**:
es el **único** archivo del proyecto que lo contiene.

Tests automáticos (vitest, sin navegador) y gate de build:

```bash
npx ng test --watch=false        # suite completa
npx ng build --configuration production
```

> **Desviación del plan (§4.3): base URL de desarrollo.**
> `PLAN-visor-camaras.md` §4.3 pide `environment.development.ts` con
> `go2rtcBaseUrl = 'http://IP_LXC:1984'`. Acá se usa `''` (mismo origen) y todo
> pasa por el proxy. **Por qué:** una URL absoluta en desarrollo hace las
> requests cross-origin, y go2rtc **no envía cabeceras CORS por defecto**, así
> que el video no conectaría; además el proxy quedaría sin uso. Con `''`,
> desarrollo y producción comparten la misma topología (mismo origen) y el
> placeholder `IP_LXC` vive en un solo archivo.

---

## Uso del visor

### Grilla y vista individual

- La grilla (`/`) muestra las 4 cámaras en 2x2; cada celda tiene el nombre abajo y,
  al pasar el mouse (o **siempre**, en dispositivos táctiles), **Ampliar**,
  **Snapshot** y **Renombrar**.
- **Ampliar** abre la vista individual; también se llega con doble click en la celda
  (en equipos con mouse), con las teclas `1`–`4`, o directo a `/#/cam/cam2`.
- **Reordenar**: sólo se arrastra **desde el grip** (el botón de seis puntos, arriba a
  la derecha de cada celda). Un swipe/arrastre sobre el cuerpo de la celda no reordena.
- **Restablecer** (arriba de la grilla) vuelve a los nombres y el orden por defecto, y
  pide confirmación antes.

### Atajos de teclado

| Vista | Tecla | Acción |
|---|---|---|
| Grilla | `1`–`4` | abre la cámara que está en esa posición |
| Vista individual | `Esc` o `Backspace` | vuelve a la grilla |
| Vista individual | `1`–`4` | salta a la cámara que está en esa posición |
| Vista individual | `F` | entra/sale de pantalla completa |

Los atajos se ignoran mientras estás escribiendo en el editor de nombre.

### Touch / celular

- En dispositivos **sin hover** los botones están siempre visibles: no hay que
  "tocar para revelar". **Ampliar** es el camino táctil explícito (no hace falta
  doble toque).
- El reordenamiento empieza **sólo** desde el grip; un swipe vertical normal scrollea.
- Todos los controles miden **≥ 44×44 CSS px** y no se superponen. Abajo de 700 px la
  grilla pasa a una columna con scroll vertical, sin scroll horizontal ni a 320 px.
- Si el navegador no soporta pantalla completa para la vista (p. ej. iOS Safari), el
  botón queda **deshabilitado con una explicación**; **Volver a la grilla** y
  **Snapshot** siguen funcionando.
- La reproducción arranca **muda y sin gesto previo** (sin audio en ningún caso).

### Snapshot

- Captura a la **resolución nativa** del video, JPEG calidad 0.92.
- Nombre del archivo: `{nombre}_{AAAA-MM-DD_HH-mm-ss}.jpg`, con acentos y caracteres
  inseguros normalizados (ej. `Porton_2026-09-15_21-30-00.jpg`).
- Funciona desde la grilla y desde la vista individual; el toast confirma
  "Captura guardada". Si la cámara todavía no tiene frames: "La cámara todavía no está
  lista" y no descarga nada.

### Dónde vive cada cosa

- **Nombres y orden**: `localStorage` del navegador, clave `visor-camaras.config.v1`.
  Es **por dispositivo**: cada navegador guarda su propio orden y sus nombres.
- **Credenciales RTSP**: sólo en `/etc/go2rtc/go2rtc.yaml` dentro del LXC (`0600`,
  dueño `go2rtc`); nunca en el repo ni en el navegador. Rotarlas = volver a correr
  el provisioner (paso 2).

### Verificación manual en hardware real

Latencia, WebRTC/MSE, backoff al cortar el DVR, touch, fullscreen real, snapshot
nativo, rotación de credenciales y control de acceso **no se pueden automatizar**:
tienen su propio checklist en [`VERIFICACION-MANUAL.md`](./VERIFICACION-MANUAL.md).

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
**Mantener estos archivos en sincronía** con la versión de go2rtc instalada en el LXC:
el provisioner instala la última release, así que si el LXC no es `v1.9.14`, re-copiá
`video-rtc.js` y `video-stream.js` desde el tag instalado y actualizá `VERSION.txt`.
La versión instalada aparece en los primeros renglones del log del servicio
(`journalctl -u go2rtc -n 20 --no-pager`).

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

**"Pantalla completa" aparece deshabilitada**

- Ese navegador no expone fullscreen para la vista (típicamente iOS Safari). No es un
  error: **Volver a la grilla** y **Snapshot** siguen funcionando.

---

## Reglas del proyecto

- **No** commitear credenciales, IPs reales ni `go2rtc.yaml` real.
- **No** agregar backend, base de datos, Docker, autenticación ni audio.
- **No** agregar dependencias fuera de Angular y `@angular/cdk`.
- TypeScript estricto. Textos de UI en **español**; código e identificadores en inglés.
