#!/usr/bin/env bash
#
# install-lxc.sh -- Provisioner interactivo de go2rtc para el visor de cámaras.
#
# Un solo script (D7): instala dependencias, binario, usuario de sistema,
# directorios, unidad systemd y renderiza /etc/go2rtc/go2rtc.yaml a partir de
# prompts (o flags/env para runs desatendidos). Supersede el comportamiento
# no-interactivo anterior: no queda nada por editar a mano.
#
# Pensado para un LXC Debian 12 nativo (sin Docker). IDEMPOTENTE: volver a
# correrlo es la forma soportada de rotar credenciales o cambiar rutas.
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
WWW_DIR="/opt/visor-camaras/www"
SERVICE_NAME="go2rtc"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
RUN_USER="go2rtc"
GO2RTC_RELEASE_URL="https://github.com/AlexxIT/go2rtc/releases/latest/download"
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

validation_reason() {
  case "${1:-}" in
    is_ipv4)                printf 'dirección inválida: se espera IPv4' ;;
    is_valid_dvr_host)      printf 'host del DVR inválido (sin rtsp://, puerto ni ruta)' ;;
    is_valid_user)          printf 'usuario inválido' ;;
    is_valid_channel_path)  printf 'ruta de canal inválida' ;;
    *)                      printf 'valor inválido' ;;
  esac
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
  local file="${1:-}" count
  if [[ ! -f "${file}" ]]; then
    printf 'no se generó el archivo de configuración'
    return 0
  fi
  if grep -qE '(IP_LXC|IP_DVR|USUARIO|PASSWORD|RUTA_CAM|%s)' -- "${file}"; then
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
directorios, renderiza /etc/go2rtc/go2rtc.yaml y deja el servicio activo.

Opciones:
  --address IP              dirección publicada del LXC (default: detectada)
  --dvr-host HOST           IP o host del DVR (requerido)
  --dvr-user USER           usuario del DVR (requerido)
  --password-file PATH      archivo modo 0600 con la contraseña; '-' = stdin
  --channels "p1,p2,p3,p4"  rutas RTSP de los 4 canales
  --yes                     no pedir confirmación (runs desatendidos)
  --dry-run                 validar y renderizar a stdout, sin escribir ni root
  --upgrade                 forzar la re-descarga del binario
  --print-encoded           leer una línea de stdin y mostrar su percent-encoding
  -h, --help                esta ayuda

Entorno equivalente: LXC_ADDRESS, DVR_HOST, DVR_USER, DVR_PASSWORD_FILE,
DVR_CHANNELS. La contraseña NUNCA se acepta por línea de comandos.
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
      --channels)      (( $# >= 2 )) || die 'falta el valor de --channels';      CHANNELS_CSV="$2"; shift 2 ;;
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
  local asset
  case "$(uname -m)" in
    x86_64|amd64)  asset="go2rtc_linux_amd64" ;;
    aarch64|arm64) asset="go2rtc_linux_arm64" ;;
    armv7l)        asset="go2rtc_linux_arm"   ;;
    *)             fatal "Arquitectura no soportada: $(uname -m)" ;;
  esac
  log "Descargando go2rtc (${asset})..."
  TMP_BIN="$(mktemp)"
  curl -fsSL "${GO2RTC_RELEASE_URL}/${asset}" -o "${TMP_BIN}"
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
  install -d -m 0755 "${WWW_DIR}"
  chown "${RUN_USER}:${RUN_USER}" "${CONFIG_DIR}" "${WWW_DIR}"
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

report_success() {
  printf '\n'
  log 'Provisioning completo.'
  printf '    Config:   %s (%s:%s, 0600)\n' "${CONFIG_PATH}" "${RUN_USER}" "${RUN_USER}"
  printf '    Servicio: %s activo\n' "${SERVICE_NAME}"
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
  restart_and_verify
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
