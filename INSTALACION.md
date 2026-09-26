# Instalación paso a paso: de un LXC vacío al visor andando

Esta guía lleva un contenedor LXC **recién creado** hasta el visor de las 4 cámaras
funcionando en el navegador. Cada paso dice **dónde** se corre (tu PC, el contenedor o
la consola de Proxmox), el **comando exacto**, **qué deberías ver** si salió bien y
**qué hacer** si no. Los datos del DVR se escriben una sola vez y quedan sólo dentro
del LXC.

Al terminar queda: **go2rtc `v1.9.14`** activo y habilitado al boot (`:1984` HTTP/API,
`:8555` WebRTC), `/etc/go2rtc/go2rtc.yaml` en `0600` con los 4 streams RTSP, el
**updater del front** instalado con su timer de 30 minutos y la **app Angular** servida
en `http://IP_LXC:1984/`. Sin backend propio, sin Docker.

> Esta guía es el detalle operativo. El resumen y el troubleshooting general están en
> [`README.md`](./README.md); el checklist de hardware real (latencia, touch, rollback)
> está en [`VERIFICACION-MANUAL.md`](./VERIFICACION-MANUAL.md).

**Cómo leer los pasos**

| Marca | El comando corre en… |
|---|---|
| **[PC del operador]** | tu máquina, con el repo a mano |
| **[Dentro del LXC]** | el contenedor, como `root` (por SSH o por la consola de Proxmox) |
| **[Consola de Proxmox]** | la consola del LXC en la UI de Proxmox (todavía no hay red) |

Placeholders: `IP_LXC` (IP fija del contenedor), `IP_DVR` (IP o host del DVR),
`USUARIO` y `PASSWORD` (credenciales RTSP). Los ejemplos usan rangos de documentación
(`192.168.1.50`, `192.168.1.10`): **nunca** escribas valores reales en el repo.

---

## Camino rápido

Para quien ya conoce el flujo; cada paso está detallado más abajo.

```bash
# 1) [Consola de Proxmox] instalá tu clave pública en /root/.ssh/authorized_keys
#    (paso 3; en Debian 12 `ssh-copy-id` NO funciona)

# 2) [PC del operador] copiá TODO deploy/ y corré el provisioner
scp -r deploy root@IP_LXC:/root/
ssh -t root@IP_LXC 'bash /root/deploy/install-lxc.sh'

# 3) [Dentro del LXC] no esperes al timer: forzá el primer update del front
systemctl start visor-camaras-update.service
visor-camaras-update --status

# 4) [Otra máquina de la LAN] abrí la app
#    http://IP_LXC:1984/
```

---

## 1. Qué queda funcionando

Un run exitoso del provisioner deja todo esto, sin editar nada a mano:

| Qué | Dónde | Detalle |
|---|---|---|
| go2rtc `v1.9.14` | `/usr/local/bin/go2rtc` → unit `go2rtc.service` | API + front en `:1984`, WebRTC en `:8555`, `Restart=always` |
| Config RTSP | `/etc/go2rtc/go2rtc.yaml` (`0600`, dueño `go2rtc:go2rtc`) | 4 streams `cam1`..`cam4` apuntando al DVR por RTSP |
| Backup de config | `/etc/go2rtc/go2rtc.yaml.prev` (`0600`) | rollback de credenciales/roturas |
| Front Angular | `/opt/visor-camaras/www` → `releases/<UTC>-<sha7>` | servido por go2rtc; no hay servidor aparte |
| Auto-update | updater + timer `visor-camaras-update.timer` | corre cada 30 min; nunca descarga `latest` del front |
| Estado del updater | `/var/lib/visor-camaras-update/state` (`0600`) | qué commit se sirve y último resultado |

El instalador es **idempotente**: volver a correrlo es la forma soportada de rotar
credenciales o cambiar rutas (sección 13-A).

## 2. Prerequisitos (antes de tocar nada)

- [ ] **LXC creado en Proxmox**: Debian 12, **no privilegiado**, **1 vCPU**, **512 MB** de
      RAM, **4 GB** de disco.
- [ ] **IP fija** en la LAN, con gateway y **DNS** cargados en la config de red del
      contenedor. Anotá esa IP: es `IP_LXC`.
- [ ] **Internet y DNS funcionando desde adentro** del contenedor (se verifica en el
      paso 4).
- [ ] **SSH como `root` desde tu máquina** (paso 3).
- [ ] **Credenciales del DVR a mano**: `IP_DVR`, `USUARIO`, `PASSWORD`. Las 4 rutas RTSP
      por defecto son las Hikvision (`/Streaming/Channels/101`, `201`, `301`, `401`); si
      tu DVR usa otras, tenelas a mano.
- [ ] *(Sólo fallback manual)* Node LTS + npm + `rsync` en tu máquina. El camino normal
      (CI → contenedor) no los necesita.

## 3. [Consola de Proxmox] SSH sin contraseña (una sola vez)

`install-lxc.sh` (y `deploy-frontend.sh`, si usás el fallback manual) abren conexiones
SSH/`rsync` al LXC. Sin clave, cada conexión pide contraseña.

> **Por qué no `ssh-copy-id`:** Debian 12 trae `PermitRootLogin prohibit-password` por
> defecto, así que `ssh-copy-id root@IP_LXC` con contraseña **falla**. No es un error
> tuyo: el contenedor rechaza el login por contraseña de `root`. La clave se instala
> desde la **consola de Proxmox**, no por SSH.

**En la consola del LXC, como `root`:**

```bash
mkdir -p /root/.ssh && chmod 700 /root/.ssh
cat >> /root/.ssh/authorized_keys <<'EOF'
<tu clave pública (una sola línea, p. ej. ssh-ed25519 AAAA...)>
EOF
chmod 600 /root/.ssh/authorized_keys
```

El bloque completo con la clave de ejemplo y la tabla de errores (`Permission denied`,
`Connection refused`, host key cambiada) están en
[README → Acceso SSH sin contraseña](./README.md#acceso-ssh-sin-contraseña-una-sola-vez).
Seguilo ahí; no lo dupliques.

**Verificá [PC del operador]**:

```bash
ssh root@IP_LXC 'echo listo'
```

- **Si salió bien**: imprime `listo` **sin pedir contraseña**. La primera conexión
  pregunta si aceptar la host key: respondé `yes`.
- **Si falla**: revisá la tabla del README enlazada arriba. Sin este paso, nada de lo
  que viene funciona.

## 4. [Dentro del LXC] Verificar que el contenedor está listo

Antes de copiar nada, comprobá que el contenedor resuelve DNS y sale a internet.

**DNS** (comando disponible siempre: `getent` viene en `libc-bin`):

```bash
getent hosts codeload.github.com
```

- **Si salió bien**: una o más líneas con la IPv4 del host.
- **Si no imprime nada**: DNS roto. Corregí el DNS del contenedor en Proxmox (o
  `/etc/resolv.conf`) antes de seguir: sin DNS no funciona ni `apt-get` ni la descarga
  del binario ni el updater.

**Internet + repos** (es lo primero que hace el instalador, `deploy/install-lxc.sh`):

```bash
apt-get update -qq && echo "apt OK"
```

- **Si salió bien**: termina con `apt OK` sin errores.
- **Si falla resolviendo hosts**: es DNS (mismo arreglo que arriba).
- **Si falla conectando**: no hay salida a internet; revisá gateway y firewall del LXC
  en Proxmox.

**HTTPS a GitHub** (sólo si `curl` ya está instalado; en un LXC nuevo suele **no**
estarlo y el instalador lo instala):

```bash
curl -fsS -o /dev/null -w 'HTTP %{http_code}\n' https://github.com
```

- Esperado: `HTTP 200`. El updater y el instalador bajan artefactos por HTTPS de
  `github.com`/`raw.githubusercontent.com`/`codeload.github.com`, así que esta salida
  tiene que existir.

> `ip` (iproute2) tampoco está garantizado en un LXC mínimo: el instalador lo instala si
> falta. No te alarmes si `ip a` no existe todavía.

## 5. [PC del operador] Copiar el tooling al LXC

Desde la raíz del repo:

```bash
scp -r deploy root@IP_LXC:/root/
```

**Verificá [PC del operador]**:

```bash
ssh root@IP_LXC 'ls /root/deploy'
```

- **Si salió bien**: aparece `install-lxc.sh`, `go2rtc.service`,
  `visor-camaras-update.sh`, `manifest.sh`, `visor-camaras-update.service`,
  `visor-camaras-update.timer`, `deploy-frontend.sh`, `check-artifact.sh`,
  `go2rtc.example.yaml` y `tests/`.

> **Importante: copiá el directorio `deploy/` completo.** El instalador **lee archivos hermanos**
> en su propio directorio (`SCRIPT_DIR`): si copiás sólo `install-lxc.sh`, aborta con
> `[x] Falta /root/deploy/go2rtc.service` o `[x] falta /root/deploy/visor-camaras-update.sh`.

| Archivo en `deploy/` | Para qué lo usa el instalador | Dónde termina en el LXC |
|---|---|---|
| `go2rtc.service` | unidad systemd de go2rtc | `/etc/systemd/system/go2rtc.service` |
| `visor-camaras-update.sh` | programa del updater | `/usr/local/sbin/visor-camaras-update` |
| `manifest.sh` | helper de `MANIFEST.json` / `tree_sha256` | `/usr/local/lib/visor-camaras/manifest.sh` |
| `visor-camaras-update.service` | unidad del updater (oneshot) | `/etc/systemd/system/visor-camaras-update.service` |
| `visor-camaras-update.timer` | timer de 30 min | `/etc/systemd/system/visor-camaras-update.timer` |

## 6. [Dentro del LXC] Previsualizar sin cambiar nada (`--dry-run`)

```bash
ssh -t root@IP_LXC 'bash /root/deploy/install-lxc.sh --dry-run'
```

`--dry-run` **valida y renderiza**, pero no escribe nada y **no requiere root**. Pide los
mismos datos que la instalación (tabla del paso 7) y muestra el YAML final por stdout con
la **contraseña enmascarada**.

- **Si salió bien**: después de responder los prompts ves el resumen con
  `Contraseña: ********`, el YAML completo y el aviso `[!] dry-run: no se escribió nada.`
  En el YAML deberían verse:
  - `listen: ":1984"` y `static_dir: "/opt/visor-camaras/www"` en `api`;
  - `webrtc.listen: ":8555"` y `- IP_LXC:8555` en `candidates`;
  - `cam1`..`cam4` con `rtsp://USUARIO:****@IP_DVR:554/Streaming/Channels/...`.
- **Si dice `[x] falta --address (sin TTY no hay prompt)`**: te faltó la `-t` en el `ssh`
  (ver paso 7).
- Nota: `--dry-run` **no** instala dependencias, binario, usuario ni directorios; esas
  fases sólo corren en la instalación real.

Si preferís un preview desatendido (sin prompts), con los valores por flags y
`--password-file`, el ejemplo está en el
[README → Previsualizar sin tocar nada](./README.md#previsualizar-sin-tocar-nada).
Tampoco requiere root.

## 7. [Dentro del LXC] Instalar

```bash
ssh -t root@IP_LXC 'bash /root/deploy/install-lxc.sh'
```

**Por qué la `-t`:** el script pregunta con `read` y aborta si `stdin` no es una terminal.
Sin `-t` no hay prompts y termina con `[x] falta --address (sin TTY no hay prompt)` (o
`[x] falta --password-file (sin TTY no hay prompt de contraseña)`): no instala nada.
`ssh -t` asigna una terminal remota y los prompts funcionan. El propio script lo avisa en
su ayuda.

**Ojo con el orden:** primero instala lo que falte (`curl`, `iproute2`, `ca-certificates`)
y descarga el binario **fijado** `v1.9.14` (`Descargando go2rtc v1.9.14 (go2rtc_linux_amd64)...`);
**recién después** pregunta los datos. En re-runs, el binario ya instalado se saltea
(`Binario ya instalado: ... (usá --upgrade para forzar)`).

### Prompts, en el orden real en que aparecen

| # | Prompt en pantalla | Default | Qué hacer | Flag / entorno |
|---|---|---|---|---|
| 1 | `Dirección publicada del LXC` | IP detectada sola (`ip route get` o `hostname -I`) | Enter si coincide con `IP_LXC`; si no, escribila | `--address` / `LXC_ADDRESS` |
| 2 | `IP o host del DVR` | — (obligatorio) | `IP_DVR`, sin `rtsp://`, sin puerto y sin ruta | `--dvr-host` / `DVR_HOST` |
| 3 | `Usuario del DVR` | — (obligatorio) | `USUARIO` | `--dvr-user` / `DVR_USER` |
| 4 | `Contraseña del DVR: ` | — (obligatorio, **sin eco**) | `PASSWORD` (no se ve al tipear) | `--password-file` / `DVR_PASSWORD_FILE` |
| 5–8 | `Ruta RTSP canal 1` … `canal 4` | `/Streaming/Channels/101`, `201`, `301`, `401` | Enter si tu DVR es Hikvision; si no, la ruta de cada canal | `--channels "p1,p2,p3,p4"` / `DVR_CHANNELS` |
| 9 | `¿Aplicar? [S/n]: ` | `s` | `s` o Enter para aplicar; `n` cancela sin escribir nada (exit 130) | `--yes` saltea esta confirmación |

- Un valor ya provisto por flag/entorno se valida y **no se vuelve a preguntar**. Un
  valor inválido re-pregunta con el motivo (p. ej. `[!] dirección inválida: se espera IPv4`,
  `[!] host del DVR inválido (sin rtsp://, puerto ni ruta)`).
- Antes de aplicar vas a ver el resumen con la contraseña enmascarada:

  ```text
  --- Resumen ---
    LXC:        IP_LXC
    DVR:        IP_DVR
    Usuario:    USUARIO
    Contraseña: ********
    Layout:     se creará releases/ y el symlink www -> releases/initial
    Canal 1:    rtsp://USUARIO:****@IP_DVR:554/Streaming/Channels/101
    ...
  ---------------
  ```

### La contraseña nunca va por la línea de comandos

Queda visible en `ps` y en el historial. El script **sólo** la acepta por prompt oculto,
por archivo modo `0600` o por stdin:

```bash
# archivo 0600, creado DENTRO del LXC
install -m 600 /dev/null /root/dvr.pw
printf '%s\n' 'PASSWORD' > /root/dvr.pw
bash /root/deploy/install-lxc.sh --password-file /root/dvr.pw
```

El archivo se rechaza si no existe, si es un symlink, si no es un archivo regular o si no
tiene modo `0600` exacto. Con `--password-file -` la contraseña se lee de stdin (pensado
para runs desatendidos). La contraseña se percent-encodea sola al armar la URL RTSP; no
hace falta codificarla a mano.

**Run desatendido** (sin prompts; no necesita `ssh -t`):

```bash
ssh root@IP_LXC 'bash /root/deploy/install-lxc.sh --yes \
  --address 192.168.1.50 --dvr-host 192.168.1.10 --dvr-user USUARIO \
  --password-file /root/dvr.pw'
```

`--yes` sólo saltea la confirmación final; los valores obligatorios siguen saliendo de
los flags (o del prompt).

### Resultado

**Si salió bien** (exit 0) ves:

```text
==> Provisioning completo.
    Config:   /etc/go2rtc/go2rtc.yaml (go2rtc:go2rtc, 0600)
    Servicio: go2rtc activo
    Updater:  /usr/local/sbin/visor-camaras-update (timer visor-camaras-update.timer, cada 30 min)
    UI:       http://IP_LXC:1984/
    Siguiente paso (desde la PC de desarrollo): ./deploy/deploy-frontend.sh IP_LXC
```

(Si había un `www` legacy como directorio real, aparece además una línea `Migración:` con
el comando para revertirla.)

**Si falla** (exit 1):

```text
[x] La configuración se aplicó pero go2rtc no quedó activo.
    Logs:     journalctl -u go2rtc -n 50 --no-pager
    Rollback: cp /etc/go2rtc/go2rtc.yaml.prev /etc/go2rtc/go2rtc.yaml && systemctl restart go2rtc
```

Corré esos dos comandos (paso 12). Un aviso `[!] La API local todavía no responde` es
**warning**, no error: el servicio quedó activo igual.

## 8. Verificar go2rtc antes de seguir (paso bisagra)

**Servicio [Dentro del LXC]**:

```bash
systemctl is-active go2rtc
systemctl status go2rtc
```

- **Si salió bien**: `active` / `active (running)`.

**Navegador [otra máquina de la LAN]**:

| URL | Qué prueba |
|---|---|
| `http://IP_LXC:1984/api/streams` | que la config cargó: devuelve un JSON con `cam1`..`cam4` |
| `http://IP_LXC:1984/api/frame.jpeg?src=cam1` (y `cam2`..`cam4`) | que el puente RTSP **funciona de verdad**: aparece un frame JPG de esa cámara |

> `/api/streams` solo muestra que los streams están configurados (los producers arrancan
> recién cuando alguien los pide). La prueba real de que el DVR responde es el frame de
> cada cámara.

**Este paso es la bisagra:** si los frames de las 4 cámaras **no** aparecen acá, el
problema son las **credenciales del DVR o la red entre el LXC y el DVR**, no el visor.
No sigas tocando el front: diagnosticá el puente con estos dos comandos.

1. **[Dentro del LXC]** — log del servicio; buscá errores de dial/autenticación RTSP:

   ```bash
   journalctl -u go2rtc -n 50 --no-pager
   ```

2. **[PC del operador o cualquier máquina de la LAN]** — abrí en VLC la misma URL RTSP
   que quedó en `/etc/go2rtc/go2rtc.yaml` (p. ej.
   `rtsp://USUARIO:PASSWORD@IP_DVR:554/Streaming/Channels/101`). Si VLC tampoco la
   reproduce, el problema está del lado del DVR/red, no de go2rtc.

> **Nota de verificación (diferencia con el README):** el
> [paso 3 del README](./README.md#3-verificar-go2rtc) menciona la UI propia de go2rtc en
> `http://IP_LXC:1984/`. Con la config que genera el instalador
> (`api.static_dir: /opt/visor-camaras/www`), go2rtc **no sirve su UI embebida**: `GET /`
> sale del directorio y, hasta el primer deploy del front, devuelve un **listado vacío**
> (HTTP 200). Por eso la verificación funcional de acá usa la API. Queda reportado para
> corregir la doc.

## 9. Conseguir el front

**Camino normal [PC del operador]**: un push a `main` hace que CI verifique y publique el
front en la rama `frontend-dist`. El contenedor lo baja solo. Está documentado en
[README → Publicación automática del front](./README.md#publicación-automática-del-front).

**El contenedor lo hace solo [Dentro del LXC]**: el instalador habilita
`visor-camaras-update.timer` recién cuando go2rtc quedó activo. El timer corre cada
**30 minutos** (primera corrida 5 min después del boot, con hasta 3 min de jitter y
persistencia entre reinicios).

Para **no esperar al timer**, forzá una corrida:

```bash
systemctl start visor-camaras-update.service
```

**Inspeccioná lo que se está sirviendo**:

```bash
visor-camaras-update --status
systemctl list-timers visor-camaras-update.timer
journalctl -u visor-camaras-update.service -n 50 --no-pager
curl -s http://IP_LXC:1984/MANIFEST.json       # desde otra máquina
```

`--status` imprime `SERVED_COMMIT`, `ACTIVATED_COMMIT`, `QUARANTINED_COMMIT`
(`none` si no hay), `LAST_OUTCOME`, el estado completo, `SERVED_PATH` (release al que
apunta `www`) y `STAGED_RELEASES`.

| `LAST_OUTCOME` | Significa |
|---|---|
| `success` | release validado, activado y verificado |
| `skipped` | no hay cambios respecto de lo servido |
| `quarantined` | el commit falló y no se re-aplica solo (rollback automático o manual) |
| `failed` | falló la corrida; el sitio quedó sirviendo la versión anterior |

- **Si salió bien**: el journal muestra el release activado y verificado; `SERVED_COMMIT`
  coincide con el campo `commit` de `http://IP_LXC:1984/MANIFEST.json`.
- **Si falla con `no se pudo descargar el tarball publicado`**: la rama `frontend-dist`
  todavía no existe (el pipeline nunca publicó) o el LXC no tiene salida HTTPS. Para no
  esperar, usá el fallback manual (sección 13-D).
- Mientras no haya una activación exitosa, `/opt/visor-camaras/www` apunta a
  `releases/initial` (vacío) y `http://IP_LXC:1984/` sigue siendo un listado vacío.

## 10. [Otra máquina / celular] Abrir la app

Abrí `http://IP_LXC:1984/` desde otra máquina de la LAN **y desde un celular**.

- **Si salió bien**: se ve la app Angular (no la UI de go2rtc ni un listado), la grilla
  2x2 con las 4 cámaras, cada celda pasa de "Conectando…" a video. En el celular los
  controles táctiles están siempre visibles. El video arranca **mudo** y sin audio.
- **Si no aparece**: paso 12. Si cambiaste algo y seguís viendo lo viejo, recarga forzada
  (`Ctrl+Shift+R`).
- **Latencia esperada**: < 1 s con WebRTC (si WebRTC no puede, cae a MSE con más
  latencia). El checklist completo de reproducción, touch y teardown es
  [`VERIFICACION-MANUAL.md`](./VERIFICACION-MANUAL.md).

## 11. Firewall (Proxmox)

En el firewall de Proxmox, para este LXC:

| Puerto | Acción | Origen |
|---|---|---|
| `1984/tcp` | Permitir | sólo la subred local (ej. `192.168.X.0/24`) |
| `8555/tcp` y `8555/udp` | Permitir | sólo la subred local |
| todo lo demás | Denegar | — |

- **No** abras puertos en el router.
- go2rtc **no tiene autenticación** por defecto y su API puede exponer las URLs de origen
  **con credenciales del DVR**: el acceso debe quedar limitado a la LAN. Detalle en
  [README → Firewall (Proxmox)](./README.md#firewall-proxmox).

## 12. Troubleshooting

Todos los comandos se corren **[Dentro del LXC]**, salvo los que dicen "desde otra
máquina". Los que empiezan con `visor-camaras-update` también aceptan la ruta completa
`/usr/local/sbin/visor-camaras-update` si tu `PATH` no incluye `/usr/local/sbin`.

| Síntoma | Comando que lo diagnostica | Qué mirar |
|---|---|---|
| **Nada en `http://IP_LXC:1984/`** | `systemctl is-active go2rtc` · `systemctl status go2rtc` · `journalctl -u go2rtc -n 50 --no-pager` · local: `curl -fsS --max-time 3 http://127.0.0.1:1984/` | que el servicio esté `active` y que la API responda local. Si responde local pero no desde la LAN: firewall (sección 11) |
| **Video negro (WebRTC)** | Revisá la IP publicada: re-corré el instalador con `--address <IP real del LXC>`; verificá `8555/tcp+udp` abiertos desde la subred local | si MSE funciona y WebRTC no, es casi siempre el puerto/la address |
| **"Sin señal" en una cámara** | VLC con la URL RTSP de `/etc/go2rtc/go2rtc.yaml` desde otra máquina · `journalctl -u go2rtc -n 50 --no-pager` · `curl -s http://IP_LXC:1984/api/streams` | credenciales del DVR o red; no es el visor |
| **La app nunca aparece (sigue el listado vacío)** | `ls -la /opt/visor-camaras/` · `visor-camaras-update --status` · `systemctl list-timers visor-camaras-update.timer` · `journalctl -u visor-camaras-update.service -n 50 --no-pager` · `curl -s http://IP_LXC:1984/MANIFEST.json` | si el timer no corrió, forzalo con `systemctl start visor-camaras-update.service`. Si `LAST_OUTCOME=failed`, mirá el error del journal |
| **El servicio no arranca al boot** | Reiniciá el LXC y corré `systemctl is-active go2rtc` · `journalctl -u go2rtc -n 50 --no-pager` · `systemctl is-enabled go2rtc` | config rota: `cp /etc/go2rtc/go2rtc.yaml.prev /etc/go2rtc/go2rtc.yaml && systemctl restart go2rtc`. Binario roto: re-corré el instalador con `--upgrade` |
| **El contenedor no se actualiza solo** | `systemctl list-timers visor-camaras-update.timer` · `visor-camaras-update --status` · `journalctl -u visor-camaras-update.service -n 50 --no-pager` | si `LAST_OUTCOME=quarantined`, ese commit no se re-aplica sin `visor-camaras-update --force` (después de entender la falla) |
| **Cambié el front y sigo viendo el viejo** | Recarga forzada (`Ctrl+Shift+R`) · `visor-camaras-update --status` | confirmá qué commit sirve el contenedor |
| **El prompt de contraseña no aparece / el comando muere sin TTY** | Usá `ssh -t` (o corré el script en la consola del LXC); para runs sin TTY, pasá todo por flags + `--password-file` | mensajes `falta --address (sin TTY no hay prompt)` / `falta --password-file (sin TTY no hay prompt de contraseña)` |
| **El instalador rechaza el archivo de contraseña** | `chmod 600 /root/dvr.pw` | debe ser un archivo regular (no symlink) con modo `0600` exacto |
| **SSH: `Permission denied` / `Connection refused` / host key** | Ver la tabla de errores en [README → Acceso SSH](./README.md#acceso-ssh-sin-contraseña-una-sola-vez) | clave mal instalada/permisos, `sshd` ausente, o contenedor recreado |
| **El DVR limita conexiones simultáneas** | `curl -s http://IP_LXC:1984/api/streams` | go2rtc reutiliza **una sola** conexión RTSP por cámara aunque haya varios navegadores: no hay nada que hacer |

## 13. Apéndice: día 2

### A. Rotar credenciales del DVR (o cambiar rutas)

Volver a correr el instalador es la forma soportada:

```bash
ssh -t root@IP_LXC 'bash /root/deploy/install-lxc.sh'
```

- Re-pide los datos y reemplaza la config de forma **atómica** (un lector nunca ve un
  archivo a medio escribir); la anterior queda en `/etc/go2rtc/go2rtc.yaml.prev` (`0600`).
- Reinicia y verifica `go2rtc`: exit 0 y el bloque `Provisioning completo.`
- Rollback puntual: `cp /etc/go2rtc/go2rtc.yaml.prev /etc/go2rtc/go2rtc.yaml && systemctl restart go2rtc`.
- Para no re-tipear: run desatendido del paso 7 (flags + `--password-file`).
- La contraseña se percent-encodea sola; `bash /root/deploy/install-lxc.sh --print-encoded`
  muestra el encoding de una línea de stdin sin instalar nada.

### B. Timer del auto-update: desactivar, reactivar, cambiar la cadencia

```bash
# desactivar (el sitio sigue sirviendo lo último activado)
systemctl disable --now visor-camaras-update.timer

# reactivar
systemctl enable --now visor-camaras-update.timer

# forzar una corrida ahora
systemctl start visor-camaras-update.service

# ver la próxima corrida
systemctl list-timers visor-camaras-update.timer
```

Para cambiar la cadencia, editá `OnUnitActiveSec=30min` en
`/etc/systemd/system/visor-camaras-update.timer` y recargá:

```bash
systemctl daemon-reload
systemctl restart visor-camaras-update.timer
```

### C. Rollback manual y cuarentena

```bash
visor-camaras-update --status      # qué se sirve y último resultado
visor-camaras-update --dry-run     # qué haría, sin escribir
visor-camaras-update --rollback    # www -> www.prev + cuarentena del commit servido
visor-camaras-update --force       # reintenta un commit en cuarentena
```

- `--rollback` **no necesita red**; si no existe `www.prev`, falla avisando que no hay a
  qué volver.
- Un commit que hizo rollback queda en `QUARANTINED_COMMIT` y no se re-aplica solo; se
  sale publicando un commit nuevo o con `--force` a conciencia.

### D. Fallback manual del front (`deploy-frontend.sh`)

Si el pipeline no está disponible o necesitás publicar un build local **ya**:

```bash
cd deploy
./deploy-frontend.sh IP_LXC root
```

- **En tu máquina** requiere Node LTS + npm + `rsync` + SSH (el puerto se pisa con
  `SSH_PORT=2222 ./deploy-frontend.sh IP_LXC`).
- Hace `npm ci`, `ng build --configuration production` y publica con `rsync` **a través**
  del symlink `www` (no lo reemplaza), ajustando el dueño atravesándolo (`chown -RH`).
- **No hace falta reiniciar go2rtc**: los estáticos se leen de disco en cada request.
- **Ojo con el timer**: el deploy manual **no escribe `MANIFEST.json`** (y su `--delete`
  borra el que hubiera), así que el próximo tick re-aplica lo publicado. Si el build
  manual tiene que persistir, desactivá antes el timer (sección B).

### E. Logs y archivos

| Qué | Dónde / comando |
|---|---|
| Log de go2rtc | `journalctl -u go2rtc -n 50 --no-pager` |
| Log del updater | `journalctl -u visor-camaras-update.service -n 50 --no-pager` |
| Estado del updater | `cat /var/lib/visor-camaras-update/state` (`0600`) · `visor-camaras-update --status` |
| Config viva / anterior | `/etc/go2rtc/go2rtc.yaml` · `/etc/go2rtc/go2rtc.yaml.prev` |
| Releases del front | `ls -la /opt/visor-camaras/` (se conservan el servido + los 4 más nuevos) |
| Próximo tick del timer | `systemctl list-timers visor-camaras-update.timer` |

### F. Actualizar go2rtc (sólo si hace falta)

```bash
ssh -t root@IP_LXC 'bash /root/deploy/install-lxc.sh --upgrade --go2rtc-version v1.9.15'
```

Al pedir un tag distinto del fijado, el script **avisa** que hay que re-copiar
`video-rtc.js` y `video-stream.js` desde ese tag y actualizar
`frontend/public/go2rtc/VERSION.txt`, porque el front vendoriza la versión fijada.
Detalle en [README → Reproductor go2rtc](./README.md#reproductor-go2rtc-versión-de-los-archivos).

### G. Herramientas que el operador normalmente no toca

`deploy/manifest.sh` y `deploy/check-artifact.sh` los usa CI (`bash deploy/check-artifact.sh
frontend/dist/frontend/browser`, `bash deploy/manifest.sh write ...`). En el contenedor,
`manifest.sh` se instala como helper del updater y es el que valida el `tree_sha256` del
artefacto. No hacen falta para instalar ni para operar el visor.

---

## Checklist final

- [ ] `systemctl is-active go2rtc` → `active` (también después de reiniciar el LXC).
- [ ] Las 4 cámaras responden (frames) en `http://IP_LXC:1984/api/frame.jpeg?src=cam1` … `cam4`.
- [ ] `visor-camaras-update --status` con `LAST_OUTCOME=success` o `skipped` y un `SERVED_COMMIT` real.
- [ ] `http://IP_LXC:1984/` sirve la app Angular desde otra máquina **y** desde un celular.
- [ ] `1984/tcp` y `8555/tcp+udp` abiertos **sólo** desde la LAN; ningún puerto en el router.
- [ ] (Recomendado) rotación de credenciales probada y rollback de config verificado (apéndice A).

## Siguiente paso

Corré el checklist completo de [`VERIFICACION-MANUAL.md`](./VERIFICACION-MANUAL.md) sobre
el LXC y el DVR reales antes de dar la instalación por terminada.
