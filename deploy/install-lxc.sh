#!/usr/bin/env bash
#
# install-lxc.sh -- Provisioner interactivo de go2rtc para el visor de cámaras.
#
# Un solo script (D7): instala dependencias, binario, usuario de sistema,
# directorios, unidad systemd, renderiza /etc/go2rtc/go2rtc.yaml a partir de
# prompts (o flags/env para runs desatendidos), instala el updater del frontend
# con su helper y sus units, deja el layout releases/ + symlink www (migrando
# atendido el www legacy) y habilita el timer de auto-update. Supersede el
# comportamiento no-interactivo anterior: no queda nada por editar a mano.
#
# Pensado para un LXC Debian 12 nativo (sin Docker). IDEMPOTENTE: volver a
# correrlo es la forma soportada de rotar credenciales o cambiar rutas.
#
# El binario queda FIJADO al tag GO2RTC_VERSION_PINNED (v1.9.14): el mismo del
# reproductor vendorizado en frontend/public/go2rtc/VERSION.txt. Se puede pedir
# otro tag con --go2rtc-version (o GO2RTC_VERSION), pero el script avisa que hay
# que re-copiar los JS del front desde ese tag.
#
# Uso interactivo (necesita TTY: ojo con `ssh` sin -t):
#   scp -r deploy root@IP_LXC:/root/
#   ssh -t root@IP_LXC 'bash /root/deploy/install-lxc.sh'
#
# Uso desatendido (sin prompts):
#   bash install-lxc.sh --yes --address 192.168.1.50 --dvr-host 192.168.1.10 \
#     --dvr-user admin --password-file /root/dvr.pw
#   cat /root/dvr.pw | bash install-lxc.sh --yes ... --password-file -
#
# Previsualizar sin tocar nada (no requiere root):
#   bash install-lxc.sh --dry-run --yes --address 192.168.1.50 \
#     --dvr-host 192.168.1.10 --dvr-user admin --password-file /root/dvr.pw
#
# Seguridad:
#   * La contraseña NUNCA se acepta por línea de comandos (argv = visible en ps
#     y en el historial). Sólo prompt oculto, --password-file <0600> o stdin.
#   * La contraseña nunca se imprime: el resumen y --dry-run la enmascaran.
#   * El YAML se escribe atómicamente (mktemp + chown + chmod 0600 + mv).
#   * El valor anterior se conserva en go2rtc.yaml.prev (copia, 0600).
#
# Estructura: este archivo define SÓLO constantes y funciones (D20). `main` se
# ejecuta únicamente cuando el script se corre directamente, nunca al sourcearlo;
# así deploy/tests/install-lxc.test.sh puede ejercitar los helpers puros.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

BIN_PATH="/usr/local/bin/go2rtc"
CONFIG_DIR="/etc/go2rtc"
CONFIG_PATH="${CONFIG_DIR}/go2rtc.yaml"
PREV_PATH="${CONFIG_PATH}.prev"
WWW_BASE_DIR="/opt/visor-camaras"
WWW_DIR="${WWW_BASE_DIR}/www"
RELEASES_DIR="${WWW_BASE_DIR}/releases"
SERVICE_NAME="go2rtc"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
RUN_USER="go2rtc"
# Updater del frontend publicado (PR3–PR5): el provisioner es el único que lo
# instala y el único que migra el layout legacy (P-D17), nunca el timer.
UPDATE_UNIT="visor-camaras-update"
UPDATE_BIN_PATH="/usr/local/sbin/visor-camaras-update"
MANIFEST_LIB_DIR="/usr/local/lib/visor-camaras"
MANIFEST_HELPER_PATH="${MANIFEST_LIB_DIR}/manifest.sh"
UPDATE_SERVICE_PATH="/etc/systemd/system/${UPDATE_UNIT}.service"
UPDATE_TIMER_PATH="/etc/systemd/system/${UPDATE_UNIT}.timer"
# Se completa si esta corrida migró un www real (el resumen lo reporta).
MIGRATED_LEGACY_DEST=""
# Versión fijada: la misma del reproductor vendorizado en el front
# (frontend/public/go2rtc/VERSION.txt). Nunca se descarga `latest`.
GO2RTC_VERSION_PINNED="v1.9.14"
GO2RTC_RELEASES_URL="https://github.com/AlexxIT/go2rtc/releases"
DEFAULT_CHANNELS=(
  "/Streaming/Channels/101"
  "/Streaming/Channels/201"
  "/Streaming/Channels/301"
  "/Streaming/Channels/401"
)

# Estado: los valores de entorno son la base; los flags los pisan en parse_args.
LXC_ADDRESS="${LXC_ADDRESS:-}"
DVR_HOST="${DVR_HOST:-}"
DVR_USER="${DVR_USER:-}"
# DVR_PASSWORD nunca se acepta por entorno: se conserva sólo el indicio de que
# estaba seteada, para avisar y descartarla (el valor no se usa jamás).
ENV_DVR_PASSWORD="${DVR_PASSWORD:-}"
DVR_PASSWORD=""
PASSWORD_FILE="${DVR_PASSWORD_FILE:-}"
CHANNELS_CSV="${DVR_CHANNELS:-}"
CHANNEL_PATHS=()
GO2RTC_VERSION="${GO2RTC_VERSION:-${GO2RTC_VERSION_PINNED}}"

DRY_RUN=0
ASSUME_YES=0
FORCE_UPGRADE=0
PRINT_ENCODED=0

TMP_CONFIG=""
TMP_PREV=""
TMP_BIN=""

# --- Salida -------------------------------------------------------------------
log()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()   { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()   { err "$*"; exit 2; }   # negativa de uso / validación (exit 2)
fatal() { err "$*"; exit 1; }   # fallo de ejecución (exit 1)

abort_cancel() {
  warn 'Cancelado: no se escribió nada.'
  exit 130
}

cleanup() {
  local f
  for f in "${TMP_CONFIG}" "${TMP_PREV}" "${TMP_BIN}"; do
    if [[ -n "${f}" && -e "${f}" ]]; then
      rm -f -- "${f}"
    fi
  done
  return 0
}

on_signal() {
  abort_cancel
}

# --- Helpers puros ------------------------------------------------------------

# urlencode: percent-encoding byte a byte (LC_ALL=C). Sólo quedan intactos los
# caracteres unreserved de RFC 3986 (A-Z a-z 0-9 - . _ ~); el resto -> %XX.
urlencode() {
  local LC_ALL=C s="${1:-}" out="" c hex i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    if [[ "${c}" == [A-Za-z0-9._~-] ]]; then
      out+="${c}"
    else
      printf -v hex '%%%02X' "'${c}"
      out+="${hex}"
    fi
  done
  printf '%s' "${out}"
}

# parse_route_src: extrae el campo `src` de una línea de `ip route get`.
parse_route_src() {
  local text="${1:-}"
  local -a toks=()
  local i
  read -r -a toks <<< "${text}" || true
  for (( i=0; i<${#toks[@]}; i++ )); do
    if [[ "${toks[i]}" == "src" ]] && (( i + 1 < ${#toks[@]} )); then
      printf '%s' "${toks[i+1]}"
      return 0
    fi
  done
  return 0
}

# detect_address (D8): src de la ruta por defecto; fallback: primer `hostname -I`.
detect_address() {
  local addr="" route_line=""
  if command -v ip >/dev/null 2>&1; then
    route_line="$(ip -4 route get 1.1.1.1 2>/dev/null || true)"
    addr="$(parse_route_src "${route_line}")"
    if [[ -n "${addr}" ]]; then
      printf '%s' "${addr}"
      return 0
    fi
  fi
  if command -v hostname >/dev/null 2>&1; then
    local -a toks=()
    read -r -a toks <<< "$(hostname -I 2>/dev/null || true)" || true
    addr="${toks[0]:-}"
  fi
  printf '%s' "${addr}"
  return 0
}

is_ipv4() {
  local ip="${1:-}" octet
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS='.'
  for octet in ${ip}; do
    (( 10#${octet} <= 255 )) || return 1
  done
  return 0
}

is_valid_dvr_host() {
  local host="${1:-}"
  [[ -n "${host}" ]] || return 1
  [[ "${host}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
  [[ "${host}" != *".."* ]] || return 1
  return 0
}

is_valid_user() {
  local user="${1:-}"
  [[ -n "${user}" && ${#user} -le 64 ]] || return 1
  [[ "${user}" != *[[:cntrl:]]* ]] || return 1
  return 0
}

is_valid_channel_path() {
  local path="${1:-}"
  [[ "${path}" == /* ]] || return 1
  (( ${#path} <= 128 )) || return 1
  [[ "${path}" =~ ^/[A-Za-z0-9._~%/+:@=-]*$ ]] || return 1
  return 0
}

# is_valid_go2rtc_version: tag de release tipo v1.9.14. Nada de `latest` ni de
# caracteres que puedan ensuciar la URL de descarga.
is_valid_go2rtc_version() {
  local version="${1:-}"
  [[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

validation_reason() {
  case "${1:-}" in
    is_ipv4)                printf 'dirección inválida: se espera IPv4' ;;
    is_valid_dvr_host)      printf 'host del DVR inválido (sin rtsp://, puerto ni ruta)' ;;
    is_valid_user)          printf 'usuario inválido' ;;
    is_valid_channel_path)  printf 'ruta de canal inválida' ;;
    is_valid_go2rtc_version) printf 'versión inválida: se espera un tag de release (p. ej. v1.9.14)' ;;
    *)                      printf 'valor inválido' ;;
  esac
}

# go2rtc_download_url <version> <asset>: URL del binario para un tag exacto.
go2rtc_download_url() {
  printf '%s/download/%s/%s' "${GO2RTC_RELEASES_URL}" "${1:-}" "${2:-}"
}

# go2rtc_version_warning <version>: aviso si el tag pedido no es el fijado, o
# vacío si coinciden (el front sólo vendoriza los JS de GO2RTC_VERSION_PINNED).
go2rtc_version_warning() {
  local version="${1:-}"
  if [[ "${version}" != "${GO2RTC_VERSION_PINNED}" ]]; then
    printf 'se instalará go2rtc %s y el front vendoriza %s: re-copiá video-rtc.js y video-stream.js del tag %s y actualizá frontend/public/go2rtc/VERSION.txt' \
      "${version}" "${GO2RTC_VERSION_PINNED}" "${version}"
  fi
  return 0
}

# password_file_error: imprime la razón por la que el archivo no sirve, o nada.
password_file_error() {
  local file="${1:-}"
  if [[ ! -e "${file}" ]]; then
    printf 'el archivo de contraseña no existe: %s' "${file}"
    return 0
  fi
  if [[ -L "${file}" ]]; then
    printf 'el archivo de contraseña no puede ser un enlace simbólico'
    return 0
  fi
  if [[ ! -f "${file}" ]]; then
    printf 'el archivo de contraseña debe ser un archivo regular'
    return 0
  fi
  local mode
  mode="$(stat -c '%a' -- "${file}")"
  if [[ "${mode}" != "600" ]]; then
    printf 'el archivo de contraseña debe tener modo 0600 (tiene %s)' "${mode}"
    return 0
  fi
  return 0
}

build_rtsp_url() { # <path> -- usa DVR_USER/DVR_PASSWORD/DVR_HOST
  printf 'rtsp://%s:%s@%s:554%s' \
    "$(urlencode "${DVR_USER:-}")" \
    "$(urlencode "${DVR_PASSWORD:-}")" \
    "${DVR_HOST:-}" \
    "${1:-}"
}

build_rtsp_url_masked() { # <path> -- para resumen y --dry-run (nunca la real)
  printf 'rtsp://%s:****@%s:554%s' \
    "$(urlencode "${DVR_USER:-}")" \
    "${DVR_HOST:-}" \
    "${1:-}"
}

# Plantilla del YAML: heredoc citado (D14) -> ni $ ni backticks se expanden.
# `render_config` la rellena con printf; sólo contiene placeholders %s.
CONFIG_TEMPLATE="$(
  cat <<'EOF'
# go2rtc.yaml -- generado por deploy/install-lxc.sh.
#
# NO editar a mano: volvé a correr el provisioner para rotar credenciales
# o cambiar las rutas de los canales.
#
# SEGURIDAD: la API de go2rtc puede exponer las URLs de origen (con las
# credenciales del DVR). El puerto 1984 sólo debe verse desde la LAN.

api:
  listen: ":1984"
  static_dir: "/opt/visor-camaras/www"

rtsp:
  listen: ""

webrtc:
  listen: ":8555"
  candidates:
    - %s:8555

streams:
  cam1: "%s"
  cam2: "%s"
  cam3: "%s"
  cam4: "%s"

log:
  level: info
EOF
)"

render_config() { # <address> <url1> <url2> <url3> <url4>
  local address="${1:-}" u1="${2:-}" u2="${3:-}" u3="${4:-}" u4="${5:-}"
  # Sólo %s en la plantilla: los valores van como argumentos, nunca como formato.
  printf "${CONFIG_TEMPLATE}" "${address}" "${u1}" "${u2}" "${u3}" "${u4}"
  printf '\n'
}

# config_error: imprime el primer problema del YAML generado, o nada si está OK.
config_error() {
  local file="${1:-}" count structure
  if [[ ! -f "${file}" ]]; then
    printf 'no se generó el archivo de configuración'
    return 0
  fi
  # Un placeholder de la plantilla sólo puede quedar en un sitio de sustitución
  # conocido (el candidate o una URL de stream sin reemplazar). Las líneas de
  # streams llevan usuario/contraseña/ruta ya renderizados, que pueden contener
  # por casualidad cadenas como USUARIO o PASSWORD: se revisan aparte con
  # patrones exactos y el resto del YAML (estructura fija) se escanea completo.
  if grep -qE '^[[:space:]]*cam[1-4]:[[:space:]]*"%s"[[:space:]]*$' -- "${file}" \
    || grep -qE '^[[:space:]]*-[[:space:]]*%s:8555[[:space:]]*$' -- "${file}"; then
    printf 'quedaron placeholders sin reemplazar en la configuración'
    return 0
  fi
  structure="$(grep -vE '^[[:space:]]*cam[1-4]:' -- "${file}" || true)"
  if grep -qE '(IP_LXC|IP_DVR|USUARIO|PASSWORD|RUTA_CAM|%s)' <<< "${structure}"; then
    printf 'quedaron placeholders sin reemplazar en la configuración'
    return 0
  fi
  count="$(grep -cE '^  cam[1-4]: ' -- "${file}" || true)"
  if [[ "${count}" != "4" ]]; then
    printf 'se esperaban 4 streams cam1..cam4 y hay %s' "${count}"
    return 0
  fi
  if grep -qE '^  cam[1-4]: ""' -- "${file}"; then
    printf 'hay streams sin URL'
    return 0
  fi
  if grep -qE '^    - :8555' -- "${file}"; then
    printf 'la dirección WebRTC quedó vacía'
    return 0
  fi
  return 0
}

assert_config_sane() {
  local reason
  reason="$(config_error "${1:-}")"
  [[ -z "${reason}" ]] || die "${reason}"
}

# validate_inputs: barrera antes de cualquier escritura (D18).
validate_inputs() {
  is_ipv4 "${LXC_ADDRESS:-}" || die "$(validation_reason is_ipv4)"
  is_valid_dvr_host "${DVR_HOST:-}" || die "$(validation_reason is_valid_dvr_host)"
  is_valid_user "${DVR_USER:-}" || die "$(validation_reason is_valid_user)"
  [[ -n "${DVR_PASSWORD:-}" ]] || die 'la contraseña no puede estar vacía'
  [[ ${#CHANNEL_PATHS[@]} -eq 4 ]] || die 'se esperan exactamente 4 rutas de canal'
  local i reason
  for i in 0 1 2 3; do
    is_valid_channel_path "${CHANNEL_PATHS[i]}" \
      || die "$(validation_reason is_valid_channel_path)"
  done
  if [[ -n "${PASSWORD_FILE:-}" && "${PASSWORD_FILE}" != "-" ]]; then
    reason="$(password_file_error "${PASSWORD_FILE}")"
    [[ -z "${reason}" ]] || die "${reason}"
  fi
  return 0
}

# --- CLI ----------------------------------------------------------------------

usage() {
  cat <<EOF
Uso: $0 [opciones]

Provisiona go2rtc dentro del LXC: instala el binario, crea usuario y
directorios, renderiza /etc/go2rtc/go2rtc.yaml, instala el updater del
frontend (releases/ + symlink www, timer cada 30 min) y deja el servicio activo.

Opciones:
  --address IP              dirección publicada del LXC (default: detectada)
  --dvr-host HOST           IP o host del DVR (requerido)
  --dvr-user USER           usuario del DVR (requerido)
  --password-file PATH      archivo modo 0600 con la contraseña; '-' = stdin
  --channels "p1,p2,p3,p4"  rutas RTSP de los 4 canales
  --go2rtc-version TAG      tag de go2rtc a instalar (default: v1.9.14, el del front)
  --yes                     no pedir confirmación (runs desatendidos)
  --dry-run                 validar y renderizar a stdout, sin escribir ni root
  --upgrade                 forzar la re-descarga del binario
  --print-encoded           leer una línea de stdin y mostrar su percent-encoding
  -h, --help                esta ayuda

Entorno equivalente: LXC_ADDRESS, DVR_HOST, DVR_USER, DVR_PASSWORD_FILE,
DVR_CHANNELS, GO2RTC_VERSION. La contraseña NUNCA se acepta por línea de comandos.
EOF
}

flag_hint() {
  case "${1:-}" in
    LXC_ADDRESS) printf '%s' '--address' ;;
    DVR_HOST)    printf '%s' '--dvr-host' ;;
    DVR_USER)    printf '%s' '--dvr-user' ;;
    *)           printf '%s' "--${1:-}" ;;
  esac
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --address)       (( $# >= 2 )) || die 'falta el valor de --address';       LXC_ADDRESS="$2"; shift 2 ;;
      --dvr-host)      (( $# >= 2 )) || die 'falta el valor de --dvr-host';      DVR_HOST="$2"; shift 2 ;;
      --dvr-user)      (( $# >= 2 )) || die 'falta el valor de --dvr-user';      DVR_USER="$2"; shift 2 ;;
      --password-file) (( $# >= 2 )) || die 'falta el valor de --password-file'; PASSWORD_FILE="$2"; shift 2 ;;
      # Misma bandera en forma `--password-file=PATH` (no lleva la contraseña
      # en argv, sólo la ruta): se acepta antes del rechazo genérico --password*.
      --password-file=*)
        PASSWORD_FILE="${1#--password-file=}"
        [[ -n "${PASSWORD_FILE}" ]] || die 'falta el valor de --password-file'
        shift ;;
      --channels)      (( $# >= 2 )) || die 'falta el valor de --channels';      CHANNELS_CSV="$2"; shift 2 ;;
      --go2rtc-version) (( $# >= 2 )) || die 'falta el valor de --go2rtc-version'; GO2RTC_VERSION="$2"; shift 2 ;;
      --yes)           ASSUME_YES=1; shift ;;
      --dry-run)       DRY_RUN=1; shift ;;
      --upgrade)       FORCE_UPGRADE=1; shift ;;
      --print-encoded) PRINT_ENCODED=1; shift ;;
      -h|--help)       usage; exit 0 ;;
      --password|--password=*|-p)
        die 'la contraseña no se acepta por línea de comandos; usá --password-file o el prompt' ;;
      --password*)
        die 'la contraseña no se acepta por línea de comandos; usá --password-file o el prompt' ;;
      -*) die "opción desconocida: $1" ;;
      *)  die "argumento inesperado: $1" ;;
    esac
  done
  # Flag y entorno pasan por el mismo validador (GO2RTC_VERSION ya resuelto).
  is_valid_go2rtc_version "${GO2RTC_VERSION}" \
    || die "$(validation_reason is_valid_go2rtc_version)"
}

print_encoded_stdin() {
  local line=""
  IFS= read -r line || true
  printf '%s\n' "$(urlencode "${line}")"
}

# --- Fases --------------------------------------------------------------------

phase_dependencies() {
  local -a missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v ip   >/dev/null 2>&1 || missing+=(iproute2)
  if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null \
      | grep -q 'install ok installed' || missing+=(ca-certificates)
  fi
  if (( ${#missing[@]} > 0 )); then
    log "Instalando dependencias: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq "${missing[@]}" >/dev/null
  else
    log 'Dependencias ya presentes.'
  fi
}

phase_binary() {
  if [[ -x "${BIN_PATH}" && "${FORCE_UPGRADE}" -eq 0 ]]; then
    log "Binario ya instalado: ${BIN_PATH} (usá --upgrade para forzar)"
    return 0
  fi
  local asset url warning
  case "$(uname -m)" in
    x86_64|amd64)  asset="go2rtc_linux_amd64" ;;
    aarch64|arm64) asset="go2rtc_linux_arm64" ;;
    armv7l)        asset="go2rtc_linux_arm"   ;;
    *)             fatal "Arquitectura no soportada: $(uname -m)" ;;
  esac
  warning="$(go2rtc_version_warning "${GO2RTC_VERSION}")"
  [[ -z "${warning}" ]] || warn "${warning}"
  log "Descargando go2rtc ${GO2RTC_VERSION} (${asset})..."
  url="$(go2rtc_download_url "${GO2RTC_VERSION}" "${asset}")"
  TMP_BIN="$(mktemp)"
  curl -fsSL "${url}" -o "${TMP_BIN}"
  [[ -s "${TMP_BIN}" ]] || fatal 'La descarga del binario quedó vacía'
  install -m 0755 -o root -g root -- "${TMP_BIN}" "${BIN_PATH}"
  rm -f -- "${TMP_BIN}"
  TMP_BIN=""
  log "Binario instalado en ${BIN_PATH}"
}

phase_user_dirs() {
  if id -u "${RUN_USER}" >/dev/null 2>&1; then
    log "El usuario '${RUN_USER}' ya existe."
  else
    log "Creando usuario de sistema '${RUN_USER}'..."
    adduser --system --group --no-create-home --home /nonexistent \
            --gecos "go2rtc service" "${RUN_USER}"
  fi
  install -d -m 0755 "${CONFIG_DIR}"
  # www ya no se crea acá: el layout lo define ensure_www_layout() (symlink a
  # releases/ o migración atendida del directorio real legacy).
  install -d -m 0755 "${WWW_BASE_DIR}"
  install -d -m 0755 "${RELEASES_DIR}"
  chown "${RUN_USER}:${RUN_USER}" "${CONFIG_DIR}" "${WWW_BASE_DIR}" "${RELEASES_DIR}"
  log 'Directorios listos.'
}

prompt_required() { # <label> <default|""> <validator> <target-var>
  local label="$1" default="${2:-}" validator="$3" target="$4"
  local current="${!target:-}" input=""
  if [[ -n "${current}" ]]; then
    if "${validator}" "${current}"; then
      return 0
    fi
    die "$(validation_reason "${validator}")"
  fi
  if [[ ! -t 0 ]]; then
    die "falta $(flag_hint "${target}") (sin TTY no hay prompt)"
  fi
  while :; do
    if [[ -n "${default}" ]]; then
      IFS= read -r -p "${label} [${default}]: " input || abort_cancel
    else
      IFS= read -r -p "${label}: " input || abort_cancel
    fi
    [[ -n "${input}" ]] || input="${default}"
    if "${validator}" "${input}"; then
      printf -v "${target}" '%s' "${input}"
      return 0
    fi
    warn "$(validation_reason "${validator}")"
  done
}

split_channels() {
  local csv="${1:-}"
  local -a parts=()
  CHANNEL_PATHS=()
  [[ -n "${csv}" ]] || return 0
  IFS=',' read -r -a parts <<< "${csv}" || true
  CHANNEL_PATHS=("${parts[@]}")
}

collect_password() {
  if [[ -z "${PASSWORD_FILE:-}" ]]; then
    if [[ ! -t 0 ]]; then
      die 'falta --password-file (sin TTY no hay prompt de contraseña)'
    fi
    IFS= read -rs -p 'Contraseña del DVR: ' DVR_PASSWORD || abort_cancel
    printf '\n' >&2
    [[ -n "${DVR_PASSWORD:-}" ]] || die 'la contraseña no puede estar vacía'
    return 0
  fi
  if [[ "${PASSWORD_FILE}" == "-" ]]; then
    IFS= read -r DVR_PASSWORD || true
  else
    local reason
    reason="$(password_file_error "${PASSWORD_FILE}")"
    [[ -z "${reason}" ]] || die "${reason}"
    IFS= read -r DVR_PASSWORD < "${PASSWORD_FILE}" || true
  fi
  [[ -n "${DVR_PASSWORD:-}" ]] || die 'la contraseña no puede estar vacía'
}

collect_channels() {
  if [[ -n "${CHANNELS_CSV:-}" ]]; then
    split_channels "${CHANNELS_CSV}"
    [[ ${#CHANNEL_PATHS[@]} -eq 4 ]] \
      || die 'se esperan exactamente 4 rutas de canal separadas por coma (--channels)'
    local i
    for i in 0 1 2 3; do
      is_valid_channel_path "${CHANNEL_PATHS[i]}" \
        || die "$(validation_reason is_valid_channel_path)"
    done
    return 0
  fi
  if [[ ! -t 0 ]]; then
    # Las rutas tienen default (patrón Hikvision): sin TTY se usan tal cual.
    CHANNEL_PATHS=("${DEFAULT_CHANNELS[@]}")
    warn 'sin TTY: se usan las rutas Hikvision por defecto (pasá --channels para cambiarlas).'
    return 0
  fi
  local i value
  for i in 0 1 2 3; do
    value=""
    prompt_required "Ruta RTSP canal $((i + 1))" "${DEFAULT_CHANNELS[i]}" \
      is_valid_channel_path value
    CHANNEL_PATHS[i]="${value}"
  done
}

collect_inputs() {
  local default_address=""
  if [[ -z "${LXC_ADDRESS:-}" ]]; then
    default_address="$(detect_address)"
  fi
  prompt_required 'Dirección publicada del LXC' "${default_address}" is_ipv4 LXC_ADDRESS
  prompt_required 'IP o host del DVR' '' is_valid_dvr_host DVR_HOST
  prompt_required 'Usuario del DVR' '' is_valid_user DVR_USER
  collect_password
  collect_channels
}

print_summary() {
  printf '\n--- Resumen ---\n'
  printf '  LXC:        %s\n' "${LXC_ADDRESS}"
  printf '  DVR:        %s\n' "${DVR_HOST}"
  printf '  Usuario:    %s\n' "${DVR_USER}"
  printf '  Contraseña: ********\n'
  printf '  Layout:     %s\n' "$(layout_summary_line)"
  local i
  for i in 0 1 2 3; do
    printf '  Canal %d:    %s\n' "$((i + 1))" "$(build_rtsp_url_masked "${CHANNEL_PATHS[i]}")"
  done
  printf -- '---------------\n'
}

confirm_or_exit() {
  print_summary
  (( ASSUME_YES )) && return 0
  if [[ ! -t 0 ]]; then
    die 'falta --yes (sin TTY no hay confirmación)'
  fi
  local answer=""
  IFS= read -r -p '¿Aplicar? [S/n]: ' answer || abort_cancel
  case "${answer:-s}" in
    s|S|si|SI|sí|SÍ|y|Y|yes|YES) return 0 ;;
    *) abort_cancel ;;
  esac
}

render_dry_run() {
  local i
  local -a urls=()
  for i in 0 1 2 3; do
    urls+=("$(build_rtsp_url_masked "${CHANNEL_PATHS[i]}")")
  done
  render_config "${LXC_ADDRESS}" "${urls[0]}" "${urls[1]}" "${urls[2]}" "${urls[3]}"
  warn 'dry-run: no se escribió nada.'
}

write_config_atomic() { # fases 6 y 7
  [[ -d "${CONFIG_DIR}" ]] || fatal "no existe ${CONFIG_DIR}"
  local -a urls=()
  local i
  for i in 0 1 2 3; do
    urls+=("$(build_rtsp_url "${CHANNEL_PATHS[i]}")")
  done

  # Fase 6: render al temporal (mismo filesystem -> rename atómico).
  TMP_CONFIG="$(mktemp "${CONFIG_DIR}/.go2rtc.yaml.XXXXXX")" \
    || fatal 'no se pudo crear el temporal de configuración'
  render_config "${LXC_ADDRESS}" "${urls[0]}" "${urls[1]}" "${urls[2]}" "${urls[3]}" \
    > "${TMP_CONFIG}"
  assert_config_sane "${TMP_CONFIG}"
  chown "${RUN_USER}:${RUN_USER}" "${TMP_CONFIG}"
  chmod 0600 "${TMP_CONFIG}"

  # Fase 7: copia del actual a .prev (copia + mv; el path vivo nunca falta).
  if [[ -f "${CONFIG_PATH}" ]]; then
    TMP_PREV="$(mktemp "${CONFIG_DIR}/.go2rtc.yaml.prev.XXXXXX")" \
      || fatal 'no se pudo crear el temporal de backup'
    cp -- "${CONFIG_PATH}" "${TMP_PREV}"
    chown "${RUN_USER}:${RUN_USER}" "${TMP_PREV}"
    chmod 0600 "${TMP_PREV}"
    mv -f -- "${TMP_PREV}" "${PREV_PATH}"
    TMP_PREV=""
  fi
  mv -f -- "${TMP_CONFIG}" "${CONFIG_PATH}"
  TMP_CONFIG=""
  log "Configuración aplicada: ${CONFIG_PATH} (${RUN_USER}:${RUN_USER}, 0600)"
}

install_service_unit() { # fase 8
  local src="${SCRIPT_DIR}/go2rtc.service"
  [[ -f "${src}" ]] || fatal "Falta ${src}"
  if [[ -f "${SERVICE_PATH}" ]] && cmp -s -- "${src}" "${SERVICE_PATH}"; then
    log 'Unidad systemd sin cambios.'
  else
    install -m 0644 -o root -g root -- "${src}" "${SERVICE_PATH}"
    systemctl daemon-reload
    log 'Unidad systemd instalada.'
  fi
  systemctl enable "${SERVICE_NAME}" >/dev/null
}

# --- Updater del frontend (PR5) ------------------------------------------------

# install_file_if_changed <origen> <destino> <modo>: copia sólo si el destino
# difiere (cmp -s), crea el directorio padre y fija root:root. El chown va
# aparte del install para poder testear la copia real sin root (mismo patrón
# que write_config_atomic con el chown stubbeado).
install_file_if_changed() {
  local src="$1" dest="$2" mode="$3" dir
  [[ -f "${src}" ]] || fatal "falta ${src}"
  if [[ -f "${dest}" ]] && cmp -s -- "${src}" "${dest}"; then
    log "sin cambios: ${dest}"
    return 0
  fi
  dir="$(dirname -- "${dest}")"
  install -d -m 0755 -- "${dir}" || fatal "no se pudo crear ${dir}"
  install -m "${mode}" -- "${src}" "${dest}" \
    || fatal "no se pudo instalar ${src} en ${dest}"
  chown root:root -- "${dest}" || warn "no se pudo fijar root:root en ${dest}"
  log "instalado: ${dest} (${mode})"
}

# install_update_program: updater a /usr/local/sbin (0755) y manifest.sh al
# directorio de librerías (0644). El updater busca el helper en SCRIPT_DIR,
# /usr/local/lib/visor-camaras/ y /usr/local/sbin/ (load_manifest_helper), así
# que instalarlo ahí lo deja resoluble sin más.
install_update_program() {
  install_file_if_changed "${SCRIPT_DIR}/visor-camaras-update.sh" "${UPDATE_BIN_PATH}" 0755
  install_file_if_changed "${SCRIPT_DIR}/manifest.sh" "${MANIFEST_HELPER_PATH}" 0644
}

# install_update_units: unidades del updater con el patrón idempotente del
# instalador (cmp -s + install -m 0644 + daemon-reload sólo si cambió alguna).
install_update_units() {
  local changed=0 pair src dest dir
  for pair in "${SCRIPT_DIR}/visor-camaras-update.service:${UPDATE_SERVICE_PATH}" \
              "${SCRIPT_DIR}/visor-camaras-update.timer:${UPDATE_TIMER_PATH}"; do
    src="${pair%%:*}"
    dest="${pair#*:}"
    if [[ -f "${dest}" ]] && cmp -s -- "${src}" "${dest}"; then
      log "sin cambios: ${dest}"
      continue
    fi
    dir="$(dirname -- "${dest}")"
    install -d -m 0755 -- "${dir}" || fatal "no se pudo crear ${dir}"
    install -m 0644 -- "${src}" "${dest}" \
      || fatal "no se pudo instalar ${src} en ${dest}"
    chown root:root -- "${dest}" || warn "no se pudo fijar root:root en ${dest}"
    log "instalado: ${dest} (0644)"
    changed=1
  done
  if (( changed )); then
    systemctl daemon-reload
    log 'daemon-reload: unidades del updater actualizadas.'
  fi
}

# seed_initial_release: release vacío inicial para que www apunte a un
# directorio real desde el arranque (hasta el primer update, GET / devuelve 200
# con un listado de directorio vacío, no 404: el updater puede snapshottearlo y
# activar sobre él sin casos especiales).
seed_initial_release() {
  local initial="${RELEASES_DIR}/initial"
  install -d -m 0755 -- "${initial}" \
    || fatal "no se pudo crear ${initial}"
  chown "${RUN_USER}:${RUN_USER}" "${initial}" \
    || warn "no se pudo fijar ${RUN_USER} en ${initial}"
}

# migrate_legacy_www [<id>]: migración ATENDIDA del layout legacy (P-D17): www
# es un directorio real -> releases/<id> (rename same-fs) + symlink relativo.
# Nunca la hace el timer. Orden a prueba de pérdida: primero se prepara el
# symlink en www.migrate, después se renombra el directorio real al release y
# recién ahí el symlink a www. Cualquier fallo anterior al rename final deja www
# intacto; un fallo del rename final intenta restaurar www desde el release.
# Reversión: rm www && mv releases/<id> www.
# El argumento opcional no se usa en este archivo, pero sí en el harness
# (deploy/tests/install-lxc.test.sh), que pasa un id fijo para que el nombre del
# release sea determinista. ShellCheck no cruza archivos, así que SC2120 es un
# falso positivo acá. Detectado por la versión 0.9.0 de CI; la 0.11.0 local no lo marca.
# shellcheck disable=SC2120
migrate_legacy_www() {
  local id="${1:-}" dest tmp
  [[ -n "${id}" ]] || id="legacy-$(date -u +%Y%m%dT%H%M%SZ)"
  dest="${RELEASES_DIR}/${id}"
  tmp="${WWW_DIR}.migrate"
  install -d -m 0755 -- "${RELEASES_DIR}" \
    || fatal "migración: no se pudo preparar ${RELEASES_DIR}; el sitio quedó intacto"
  [[ ! -e "${dest}" ]] \
    || fatal "migración: ya existe ${dest}; resolvelo a mano antes de seguir"
  warn "migración atendida: ${WWW_DIR} es un directorio real; se moverá a releases/${id}"
  rm -f -- "${tmp}" || fatal "migración: no se pudo limpiar ${tmp}; el sitio quedó intacto"
  ln -s -- "releases/${id}" "${tmp}" \
    || fatal "migración: no se pudo preparar el symlink ${tmp}; el sitio quedó intacto"
  if ! mv -T -- "${WWW_DIR}" "${dest}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    fatal "migración: no se pudo mover ${WWW_DIR} a ${dest}; el sitio quedó intacto"
  fi
  if ! mv -T -- "${tmp}" "${WWW_DIR}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    if mv -T -- "${dest}" "${WWW_DIR}" 2>/dev/null; then
      fatal "migración: falló el symlink; ${WWW_DIR} se restauró intacto"
    fi
    fatal "migración: falló el symlink; el front quedó a salvo en ${dest}"
  fi
  chown -R "${RUN_USER}:${RUN_USER}" "${dest}" \
    || warn "migración: no se pudo fijar ${RUN_USER} en ${dest}"
  chmod -R a+rX -- "${dest}" \
    || warn "migración: no se pudieron ajustar los permisos de ${dest}"
  MIGRATED_LEGACY_DEST="${dest}"
  log "migración completa: ${WWW_DIR} -> releases/${id}"
  warn "para revertirla: rm -- '${WWW_DIR}' && mv -- '${dest}' '${WWW_DIR}'"
}

# layout_summary_line: describe el estado del layout para el resumen previo a la
# confirmación (la migración es atendida: el operador la ve antes de aplicarla).
layout_summary_line() {
  if [[ -L "${WWW_DIR}" ]]; then
    if [[ -d "${WWW_DIR}/" ]]; then
      printf 'www ya es symlink a %s: sin cambios' "$(readlink -- "${WWW_DIR}")"
    else
      printf 'www es un symlink que no resuelve (%s)' "$(readlink -- "${WWW_DIR}")"
    fi
  elif [[ -d "${WWW_DIR}" ]]; then
    printf 'migración atendida: www (directorio real) -> releases/legacy-<ts> + symlink'
  elif [[ -e "${WWW_DIR}" ]]; then
    printf 'layout inesperado: %s no es directorio ni symlink' "${WWW_DIR}"
  else
    printf 'se creará releases/ y el symlink www -> releases/initial'
  fi
}

# ensure_www_layout: invariante P-D17. Idempotente y re-ejecutable: no-op si www
# ya es un symlink (con aviso si no resuelve); migración atendida si es un
# directorio real (nunca la hace el updater); si no existe, crea releases/initial
# y el symlink relativo. Cualquier otro estado se rechaza sin tocar nada.
ensure_www_layout() {
  install -d -m 0755 -- "${RELEASES_DIR}" \
    || fatal "layout: no se pudo preparar ${RELEASES_DIR}"
  if [[ -L "${WWW_DIR}" ]]; then
    log "layout: ${WWW_DIR} ya es un symlink ($(readlink -- "${WWW_DIR}")); sin cambios."
    if [[ ! -d "${WWW_DIR}/" ]]; then
      warn 'layout: el symlink no resuelve a un directorio; el updater lo va a rechazar hasta arreglarlo.'
    fi
    return 0
  fi
  if [[ -d "${WWW_DIR}" ]]; then
    migrate_legacy_www
    return 0
  fi
  if [[ -e "${WWW_DIR}" ]]; then
    fatal "layout inesperado: ${WWW_DIR} no es un directorio ni un symlink"
  fi
  seed_initial_release
  ln -s -- 'releases/initial' "${WWW_DIR}" \
    || fatal "layout: no se pudo crear el symlink ${WWW_DIR} -> releases/initial"
  log "layout creado: ${WWW_DIR} -> releases/initial"
}

enable_update_timer() {
  systemctl enable --now "${UPDATE_UNIT}.timer" >/dev/null \
    || fatal "no se pudo habilitar ${UPDATE_UNIT}.timer"
  log "timer del updater habilitado y arrancado (${UPDATE_UNIT}.timer, cada 30 min)"
}

# install_update_artifacts: fases PR5 de instalación (updater + helper,
# unidades y layout/migración). NO habilita el timer: eso se hace recién
# cuando go2rtc quedó activo y verificado (si el timer corriera con el sitio
# caído, el updater haría rollback+cuarentena del commit publicado).
install_update_artifacts() {
  install_update_program
  install_update_units
  ensure_www_layout
}

report_success() {
  printf '\n'
  log 'Provisioning completo.'
  printf '    Config:   %s (%s:%s, 0600)\n' "${CONFIG_PATH}" "${RUN_USER}" "${RUN_USER}"
  printf '    Servicio: %s activo\n' "${SERVICE_NAME}"
  printf '    Updater:  %s (timer %s, cada 30 min)\n' "${UPDATE_BIN_PATH}" "${UPDATE_UNIT}.timer"
  if [[ -n "${MIGRATED_LEGACY_DEST:-}" ]]; then
    printf '    Migración: front legacy en %s (revertir: rm %s && mv %s %s)\n' \
      "${MIGRATED_LEGACY_DEST}" "${WWW_DIR}" "${MIGRATED_LEGACY_DEST}" "${WWW_DIR}"
  fi
  printf '    UI:       http://%s:1984/\n' "${LXC_ADDRESS}"
  printf '    Siguiente paso (desde la PC de desarrollo): ./deploy/deploy-frontend.sh %s\n' "${LXC_ADDRESS}"
}

report_failure() {
  err 'La configuración se aplicó pero go2rtc no quedó activo.'
  printf '    Logs:     journalctl -u %s -n 50 --no-pager\n' "${SERVICE_NAME}" >&2
  printf '    Rollback: cp %s %s && systemctl restart %s\n' \
    "${PREV_PATH}" "${CONFIG_PATH}" "${SERVICE_NAME}" >&2
}

restart_and_verify() { # fases 9 y 10
  log "Reiniciando ${SERVICE_NAME}..."
  # Si restart falla, no abortamos: el poll de abajo reporta el fallo con logs
  # y rollback (contrato de [R: Verification and reporting]).
  systemctl restart "${SERVICE_NAME}" || true
  local i
  for i in {1..10}; do
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
      break
    fi
    sleep 1
  done
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    if command -v curl >/dev/null 2>&1; then
      curl -fsS --max-time 3 'http://127.0.0.1:1984/' >/dev/null 2>&1 \
        || warn 'La API local todavía no responde (aviso, no error).'
    fi
    # Recién con go2rtc activo se habilita el auto-update: con el sitio caído
    # un tick haría rollback+cuarentena del commit publicado y quedaría inerte.
    enable_update_timer
    report_success
    exit 0
  fi
  report_failure
  exit 1
}

warn_unset_env_password() {
  if [[ -n "${ENV_DVR_PASSWORD:-}" ]]; then
    warn 'DVR_PASSWORD se ignora por seguridad: usá --password-file o el prompt interactivo.'
    unset DVR_PASSWORD ENV_DVR_PASSWORD
  fi
}

main() {
  set -euo pipefail
  parse_args "$@"

  if (( PRINT_ENCODED )); then
    print_encoded_stdin
    exit 0
  fi

  warn_unset_env_password

  if (( DRY_RUN )); then
    warn 'Modo --dry-run: no se escribe nada; no requiere root.'
  else
    [[ "${EUID}" -eq 0 ]] || die "Hay que ejecutarlo como root (sudo $0), o usá --dry-run"
  fi

  umask 077
  trap cleanup EXIT
  trap on_signal INT TERM

  if (( ! DRY_RUN )); then
    phase_dependencies
    phase_binary
    phase_user_dirs
  fi

  collect_inputs
  validate_inputs
  confirm_or_exit

  if (( DRY_RUN )); then
    render_dry_run
    exit 0
  fi

  write_config_atomic
  install_service_unit
  install_update_artifacts
  restart_and_verify
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
