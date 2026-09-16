#!/usr/bin/env bash
#
# deploy-frontend.sh -- Compila el front Angular y lo publica en el LXC.
#
# Uso:
#   ./deploy-frontend.sh <IP_LXC> [usuario_ssh]
#
# Ejemplos:
#   ./deploy-frontend.sh 192.168.1.50
#   ./deploy-frontend.sh 192.168.1.50 root
#
# Requisitos en ESTA máquina: Node LTS + npm, rsync y acceso SSH al LXC.
# El usuario SSH debe poder escribir en /opt/visor-camaras/www
# (si no es root, necesita sudo sin password para el chown).

set -euo pipefail

IP_LXC="${1:-}"
SSH_USER="${2:-root}"
SSH_PORT="${SSH_PORT:-22}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
FRONT_DIR="${REPO_ROOT}/frontend"
DEST_DIR="/opt/visor-camaras/www"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -n "${IP_LXC}" ]] || die "Uso: $0 <IP_LXC> [usuario_ssh]"
[[ -d "${FRONT_DIR}" ]] || die "No existe ${FRONT_DIR}"

REMOTE_SUDO=""
[[ "${SSH_USER}" != "root" ]] && REMOTE_SUDO="sudo "

log "Instalando dependencias (npm ci)..."
(cd "${FRONT_DIR}" && npm ci)

log "Compilando en modo producción..."
(cd "${FRONT_DIR}" && npx ng build --configuration production)

# Angular 17+ (application builder) genera dist/<proyecto>/browser.
# Builders viejos dejan el index.html directamente en dist/<proyecto>/.
BROWSER_DIR="$(find "${FRONT_DIR}/dist" -maxdepth 2 -type d -name browser 2>/dev/null | head -n1)"
if [[ -z "${BROWSER_DIR}" ]]; then
  BROWSER_DIR="$(find "${FRONT_DIR}/dist" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n1)"
fi
[[ -n "${BROWSER_DIR}" && -f "${BROWSER_DIR}/index.html" ]] \
  || die "No se encontró un build válido (index.html) dentro de ${FRONT_DIR}/dist"

log "Publicando en ${SSH_USER}@${IP_LXC}:${DEST_DIR} ..."
rsync -az --delete -e "ssh -p ${SSH_PORT}" \
      "${BROWSER_DIR}/" "${SSH_USER}@${IP_LXC}:${DEST_DIR}/"

log "Ajustando dueño y permisos..."
ssh -p "${SSH_PORT}" "${SSH_USER}@${IP_LXC}" \
    "${REMOTE_SUDO}chown -R go2rtc:go2rtc '${DEST_DIR}' && ${REMOTE_SUDO}chmod -R a+rX '${DEST_DIR}'"

# Los archivos estáticos se leen desde disco en cada request:
# no hace falta reiniciar go2rtc para publicar un front nuevo.
log "Listo. Los archivos estáticos no requieren reinicio del servicio."

if command -v curl >/dev/null 2>&1; then
  log "Verificando http://${IP_LXC}:1984/ ..."
  curl -fsS -o /dev/null -w "HTTP %{http_code}\n" "http://${IP_LXC}:1984/" \
    || warn_http=1
  [[ "${warn_http:-0}" -eq 0 ]] || printf '\033[1;33m[!]\033[0m No se pudo verificar por HTTP (¿go2rtc corriendo? ¿firewall?)\n' >&2
fi
