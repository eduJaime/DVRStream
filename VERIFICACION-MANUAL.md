# Verificación manual en hardware real (LXC + DVR)

> Este checklist cubre **todo lo que no se puede verificar automáticamente** en el
> entorno de desarrollo (jsdom no tiene Fullscreen API, motor de layout, touch ni
> red/DVR reales). Corrélo completo una vez sobre el LXC y el DVR reales antes de
> dar el visor por terminado, y de nuevo después de cualquier cambio de
> infraestructura. Si algo falla, la sección de troubleshooting está en
> [`README.md`](./README.md#solución-de-problemas).

**Precondiciones**

- [ ] LXC Debian 12 provisionado (`deploy/install-lxc.sh`) y front publicado
      (`deploy/deploy-frontend.sh IP_LXC`).
- [ ] `http://IP_LXC:1984/` sirve la app Angular (no la UI propia de go2rtc) con las 4 cámaras.
- [ ] Un segundo navegador/dispositivo en la LAN para las pruebas de múltiples clientes.
- [ ] Acceso al DVR para cortar y restablecer su conectividad.
- [ ] DevTools del navegador disponibles (pestañas Network/Elements y `chrome://webrtc-internals`).
- [ ] Un celular real (o emulación táctil de DevTools) para la sección Touch.

## Resumen

| # | Verificación | Requisito de la spec |
|---|---|---|
| 1 | 4 cámaras en la grilla, latencia < 1 s, WebRTC primero con MSE de fallback | Silent/Resilient playback |
| 2 | "Sin señal" + reintentos 5/10/20/30 s + recuperación al volver el DVR | Resilient playback |
| 3 | Una sola conexión upstream por cámara con varios navegadores | One upstream per camera |
| 4 | La vista individual cierra su stream; la pestaña oculta libera todos | Lifecycle teardown |
| 5 | Reordenar no reconecta (sin cuadro negro) y persiste | Camera ordering |
| 6 | Snapshot a resolución nativa, nombre correcto y JPG que abre | Native-resolution snapshot |
| 7 | Touch: sin hover, grip vs swipe, 44×44, 320 px, fullscreen degradado | touch-mobile |
| 8 | Provisioner: rotación + rollback, escritura interrumpida, fallo de servicio, secretos y run desatendido | lxc-provisioning |
| 9 | Despliegue y control de acceso (LAN sí, fuera de la subred no; reboot del LXC) | Fase 7 del plan |

## 1. Reproducción de las 4 cámaras, latencia y protocolo

1. Abrí `http://IP_LXC:1984/` en la PC de desarrollo.
2. Esperá a que las 4 celdas pasen de "Conectando…" a video.

- [ ] Las 4 cámaras se ven **simultáneamente** en la grilla 2x2 (sin scroll de página).
- [ ] Latencia < 1 s: apuntá una cámara a una pantalla con un cronómetro visible
      (p. ej. `time.is`) y compará el reloj real con el del video.
- [ ] **WebRTC primero**: en DevTools → Elements, el `<video>` interno de
      `video-stream` tiene `srcObject` (MediaStream), y en `chrome://webrtc-internals`
      hay **una RTCPeerConnection activa por cámara** (4 en total).
- [ ] **MSE de fallback**: bloqueá WebRTC en el equipo de pruebas (regla de firewall
      local que descarte TCP+UDP 8555), recargá y confirmá que las cámaras **igual
      se ven** (por MSE, con más latencia; en Elements el video usa `src` `blob:`).
      Revertir el bloqueo al terminar.
- [ ] Sin audio: ninguna celda tiene controles de audio ni reproduce sonido.

## 2. Corte del DVR: "Sin señal" y backoff 5/10/20/30

1. Con las 4 cámaras andando, cortá la conectividad del DVR (apagalo, desenchufá su
   red o bloqueá su IP en el firewall del LXC).
2. Mirá una celda y la pestaña Network de DevTools (filtro WS).

- [ ] Aparece **"Sin señal"** con el botón **Reintentar**.
- [ ] Los reintentos automáticos siguen la cadencia **5 s → 10 s → 20 s → 30 s**
      (después, cada 30 s). Se ven como conexiones WS nuevas en Network y como
      "Conectando…" intermitente en la celda.
- [ ] **Reintentar** fuerza un intento inmediato.
- [ ] Al restablecer el DVR, la cámara **se recupera sola** (dentro de la ventana de
      30 s) sin recargar la página.

## 3. Una sola conexión upstream por cámara

1. Abrí la grilla en dos o más navegadores/dispositivos a la vez.
2. Consultá `http://IP_LXC:1984/api/streams`.

- [ ] Cada cámara muestra **exactamente un `producer`** (la conexión RTSP al DVR),
      aunque haya varios `consumers` (uno por navegador).
- [ ] Al cerrar un navegador, su `consumer` desaparece y el `producer` **se mantiene**
      mientras quede otro espectador.

## 4. Teardown: vista individual y pestaña oculta

1. Con la grilla reproduciendo, abrí una cámara con **Ampliar** (o la tecla `1`).
2. Mirá `/api/streams`; después volvé a la grilla con **Esc**/**Volver a la grilla**.
3. Con la grilla abierta, cambiá de pestaña o minimizá el navegador ~5 s y volvé.

- [ ] Al abrir la vista individual, las **otras 3 cámaras quedan con 0 consumers**
      (su stream se cerró) y la ampliada conserva 1.
- [ ] Al volver a la grilla, la cámara ampliada cierra su stream y se abren los 4 de nuevo.
- [ ] Con la pestaña oculta, **los 4 streams se liberan** (0 consumers).
- [ ] Al volver a la pestaña, los 4 reconectan solos y siguen mudos.

## 5. Reordenar sin reconectar

1. Con las 4 cámaras reproduciendo, arrastrá una celda **desde el grip**
   (el botón de seis puntos, arriba a la derecha) a otra posición.

- [ ] Las celdas se mueven **sin cuadro negro** y sin "Conectando…": no hay
      reconexión visible ni caída de `consumers` en `/api/streams`.
- [ ] Al recargar, el nuevo orden persiste (es **por navegador**: `localStorage`).
- [ ] **Restablecer** pide confirmación y vuelve nombres y orden por defecto.

## 6. Snapshot a resolución nativa

1. Con una cámara reproduciendo, tocá **Snapshot** (grilla y vista individual).

- [ ] Se descarga `{nombre}_{AAAA-MM-DD_HH-mm-ss}.jpg`; los acentos y caracteres
      raros del nombre quedan normalizados (ej. `Porton_2026-09-15_21-30-00.jpg`).
- [ ] El toast muestra "Captura guardada".
- [ ] La **resolución del JPG es la nativa de la cámara** (igual a la que muestra
      VLC para ese stream, no el tamaño de la celda en pantalla).
- [ ] El archivo **abre correctamente** y la imagen es la del momento de la captura.
- [ ] Recargá y tocá Snapshot **antes** de que aparezcan frames: muestra
      "La cámara todavía no está lista" y **no** descarga nada.

## 7. Touch / celular

1. En un celular real (o emulación táctil de DevTools) abrí `http://IP_LXC:1984/`.

- [ ] **Sin hover**: los botones **Ampliar / Snapshot / Renombrar** están visibles
      desde el arranque, sin tocar la pantalla. En una PC con mouse siguen ocultos
      hasta hover/focus (regresión).
- [ ] **Ampliar** abre la vista individual con un solo toque (no hace falta doble toque).
- [ ] **Swipe vertical sobre la celda scrollea** la página y **no** inicia un reordenamiento.
- [ ] Un arrastre que empieza **exactamente en el grip** sí reordena.
- [ ] Medí con DevTools: **todo control interactivo mide ≥ 44×44 CSS px** y no se superpone,
      incluido el botón **Reintentar** del estado "Sin señal" (sección 2).
- [ ] A **320 px** de ancho (y 360/390/414) la grilla es de una columna, con scroll
      vertical y **sin scroll horizontal**.
- [ ] **Pantalla completa degradada**: en un navegador sin fullscreen para la vista
      (típicamente iOS Safari) el botón está deshabilitado con explicación, y
      **Volver a la grilla** y **Snapshot** siguen funcionando. En un navegador con
      soporte, alterna entrar/salir y `Esc` sale antes de navegar.
- [ ] El video arranca **mudo, sin gesto previo** y sin controles de audio.
- [ ] El editor de nombre es usable: Guardar/Cancelar alcanzables y el zoom no salta al enfocar.

## 8. Provisioner: rotación, atomicidad, secretos y run desatendido

### 8.1 Rotación de credenciales + rollback (spec: Idempotent and atomic re-runs)

1. Re-corré el provisioner en el LXC (con datos nuevos o una ruta de canal distinta):
   `ssh -t root@IP_LXC 'bash /root/deploy/install-lxc.sh'` (o con flags/`--password-file`).

- [ ] El script valida, escribe **atómicamente**, reinicia y reporta éxito (exit 0).
- [ ] `/etc/go2rtc/go2rtc.yaml` queda `0600` y dueño `go2rtc:go2rtc`.
- [ ] Existe `/etc/go2rtc/go2rtc.yaml.prev` con la config anterior (`0600`).
- [ ] Las cámaras vuelven a andar después del restart.
- [ ] **Rollback probado**: `cp /etc/go2rtc/go2rtc.yaml.prev /etc/go2rtc/go2rtc.yaml && systemctl restart go2rtc`
      deja funcionando las credenciales anteriores.

### 8.2 Escritura interrumpida: SIGKILL entre render y rename (spec: Interrupted write)

La ventana entre el render (fase 6) y el `mv` atómico (fase 7) es corta; se ensancha
matando el proceso repetidas veces en momentos distintos:

1. Anotá la config viva: `sha256sum /etc/go2rtc/go2rtc.yaml`.
2. Re-corré el provisioner con datos nuevos y matalo a lo bruto a mitad de camino
   (`kill -9 <pid>`), variando el momento entre corridas (p. ej. `timeout -s KILL 1.5 bash install-lxc.sh …`).
3. Repetilo 3–5 veces y después de **cada** kill verificá la config viva.

- [ ] `go2rtc.yaml` sigue existiendo, completo (`grep -cE '^  cam[1-4]:' /etc/go2rtc/go2rtc.yaml` = 4) y en `0600`.
- [ ] Su contenido es **la config vieja completa o la nueva completa**, nunca una mezcla ni un archivo truncado.
- [ ] `go2rtc` sigue sirviendo las cámaras (la config viva nunca desapareció).
- [ ] Tras `SIGKILL` puede quedar un temporal `.go2rtc.yaml.XXXXXX` (el trap no corre en `SIGKILL`):
      es esperable, se borra a mano y **no** afecta la config viva.

### 8.3 Reporte real de fallo del servicio (spec: Verification and reporting)

1. Forzá un arranque fallido y re-corré el provisioner con datos válidos:
   ```bash
   printf '#!/bin/sh\nexit 1\n' > /usr/local/bin/go2rtc && chmod 0755 /usr/local/bin/go2rtc
   ssh -t root@IP_LXC 'bash /root/deploy/install-lxc.sh'   # o --yes + flags + --password-file
   ```
2. Restaurá el binario real: `ssh -t root@IP_LXC 'bash /root/deploy/install-lxc.sh --upgrade'` (re-descarga vía `--upgrade`).

- [ ] La corrida termina con **exit 1** (no 0) y reporta el fallo explícitamente.
- [ ] Imprime los dos comandos exactos: `journalctl -u go2rtc -n 50 --no-pager` y el rollback con `.prev`.
- [ ] Con el binario restaurado, un nuevo re-run deja el servicio activo (exit 0).

### 8.4 Contraseña oculta: sin eco y sin historial (spec: Secret handling)

Se prueba sin root y sin tocar la config usando `--dry-run`:

1. `bash deploy/install-lxc.sh --dry-run` en una terminal real; en `Contraseña del DVR:`
   tipeá un **canario** (p. ej. `canario-sin-eco-123`) y respondé `n` en `¿Aplicar?`
   (aborta con exit 130 y no escribe nada).
2. Revisá el terminal y el historial.

- [ ] Mientras se tipea, la contraseña **no se ve** (sin eco).
- [ ] El canario no aparece en la salida (el resumen muestra `********`).
- [ ] `history | grep canario` y `grep canario ~/.bash_history` no lo encuentran.
- [ ] `DVR_PASSWORD=...` por entorno se avisa y se ignora (el valor no se usa).

### 8.5 Run realmente desatendido con `--password-file` (spec: Non-interactive escape hatch)

1. Prepará el archivo: `printf '%s\n' "$PASSWORD" > /root/dvr.pw && chmod 600 /root/dvr.pw`.
2. Corré **sin TTY** (sin `-t`) y con todos los valores por flags:
   ```bash
   ssh root@IP_LXC 'bash /root/deploy/install-lxc.sh --yes \
     --address IP_LXC --dvr-host IP_DVR --dvr-user USUARIO --password-file /root/dvr.pw'
   ```

- [ ] No aparece **ningún** prompt ni la corrida se bloquea esperando entrada.
- [ ] Termina con exit 0, `go2rtc` queda activo y la UI responde.
- [ ] La contraseña no aparece en la salida ni en `ps -ef` durante la corrida.

## 9. Despliegue y control de acceso

- [ ] Desde otra PC **y un celular de la LAN**, `http://IP_LXC:1984/` muestra la app
      completa (no la UI de go2rtc) con las 4 cámaras.
- [ ] Desde **fuera de la subred local** (datos móviles u otra VLAN), `1984/tcp` y
      `8555/tcp+udp` **no responden**.
- [ ] Reiniciá el LXC: al volver, `systemctl is-active go2rtc` da `active` y el visor
      funciona **sin intervención manual**.
- [ ] El repo no contiene credenciales ni IPs reales: sólo placeholders
      (`IP_LXC`, `IP_DVR`, `USUARIO`, `PASSWORD`).

## Registro

| Fecha | Versión instalada (LXC / front) | Resultado | Notas |
|---|---|---|---|
| | | | |

## Fuera de alcance de este gate

- Lo cubierto por `npx ng test --watch=false` y `npx ng build --configuration production`.
- `shellcheck` del provisioner: no está instalado en el entorno de desarrollo;
  corrélo en el LXC/CI si está disponible (`shellcheck -S warning deploy/install-lxc.sh`).
