#!/usr/bin/env bash
#
# visor-camaras-update.sh -- actualiza el frontend publicado del visor de cámaras.
#
# Alcance PR4: fetch / validación / staging / activación atómica (swap del
# symlink www), snapshot .prev, verificación post-swap, rollback, cuarentena,
# estado/poda y reanudación de una activación interrumpida. `success` significa
# ACTIVADO Y VERIFICADO: el commit publicado se sirve en www y respondió la
# verificación; `SERVED_COMMIT`/`ACTIVATED_COMMIT` lo confirman.
#
# Uso:
#   visor-camaras-update.sh [--root DIR] [--dry-run] [--status] [--check-url URL]
#   visor-camaras-update.sh --rollback     (operador: www -> www.prev + cuarentena)
#   visor-camaras-update.sh --force        (ignora la cuarentena de P-D25)
#
# Test-only (no usar en producción):
#   visor-camaras-update.sh --root DIR --source-url file:///ruta [--dry-run]
#   --source-url exige --root explícito y saltea el forzado HTTPS; sirve para
#   correr el harness en un sandbox, sin red y sin root.
#
# Cortes en medio de la activación: el snapshot .prev puede quedar ausente o
# como www.prev.new parcial; www nunca se toca y la próxima corrida rehace el
# snapshot. Tras el swap, ACTIVATION_PENDING queda persistido: si el proceso
# muere, la próxima corrida verifica el commit pendiente y lo finaliza o hace
# rollback; nunca se acepta en silencio un release sin verificar. El único hueco
# residual es el lapso entre el swap y el resultado persistido, y la reanudación
# lo cubre en el siguiente tick.
#
# Fases (P-D18/P-D19):
#   0. preflight: dependencias, layout (www debe ser symlink), flock -n
#   1. fetch del MANIFEST.json publicado (HTTPS, timeout corto)
#   2. detección de cambios (commit servido / cuarentena / ya staged)
#   3. fetch del tarball (HTTPS, timeouts, retry y tope de tamaño)
#   4. extracción a .staging rechazando entradas hostiles (absolutas, .., symlinks)
#   5. validación: index.html usable + tree_sha256 vía deploy/manifest.sh
#   6. promoción a releases/<UTC>-<sha7> (rename en el mismo filesystem)
#   7. snapshot .prev (copia real) + swap atómico del symlink www
#   8. verificación post-swap (symlink + <check-url>/) y rollback con cuarentena
#   9. poda acotada (se conservan los 5 releases más nuevos + el servido)
#  10. estado atómico en /var/lib/visor-camaras-update/state
#
# Exit: 0 éxito/skip/busy · 1 fallo de ejecución · 2 artefacto o layout rechazado.
#
# Estructura: constantes + funciones; main_update() sólo corre si el script se
# ejecuta directamente (mismo patrón que install-lxc.sh), así los tests pueden
# sourcearlo. No se llama main() para no colisionar con manifest.sh sourceado.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_URL_DEFAULT="https://codeload.github.com/eduJaime/DVRStream/tar.gz/refs/heads/frontend-dist"
MANIFEST_URL_DEFAULT="https://raw.githubusercontent.com/eduJaime/DVRStream/frontend-dist/MANIFEST.json"
TARBALL_NAME="frontend-dist.tar.gz"
RUN_USER="go2rtc"
KEEP_RELEASES=5
MAX_TARBALL_BYTES=52428800 # 50 MiB
CONNECT_TIMEOUT=10
MANIFEST_MAX_TIME=15
TARBALL_MAX_TIME=600
CHECK_TIMEOUT=5
CHECK_URL_DEFAULT="http://127.0.0.1:1984/"

# Rutas relativas al --root (en producción ROOT=/ y quedan las del diseño).
WWW_REL="opt/visor-camaras/www"
RELEASES_REL="opt/visor-camaras/releases"
STAGING_REL="opt/visor-camaras/.staging"
STATE_DIR_REL="var/lib/visor-camaras-update"
STATE_REL="var/lib/visor-camaras-update/state"
LOCK_REL="run/visor-camaras-update/lock"

ROOT="/"
ROOT_EXPLICIT=0
DRY_RUN=0
STATUS=0
FORCE=0
ROLLBACK=0
SOURCE_URL_OVERRIDE=0
CHECK_URL="${VISOR_CHECK_URL:-${CHECK_URL_DEFAULT}}"
SOURCE_URL=""
MANIFEST_URL=""
MANIFEST_HELPER="${VISOR_MANIFEST_HELPER:-}"

WWW_DIR=""
WWW_PREV_DIR=""
WWW_SWAP_PATH=""
RELEASES_DIR=""
STAGING_DIR=""
STATE_DIR=""
STATE_PATH=""
LOCK_PATH=""

RUN_TMP=""
STAGING_ACTIVE=""
TARBALL_FILE=""
RELEASE_PATH=""
VERIFY_ERROR=""
PREV_COMMIT=""

declare -A STATE_MAP=()

# --- Salida --------------------------------------------------------------------

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die_usage() { err "$*"; exit 2; }

# --- Rutas ---------------------------------------------------------------------

path_join() { # <relativa>
  printf '%s/%s' "${ROOT%/}" "$1"
}

resolve_paths() {
  WWW_DIR="$(path_join "${WWW_REL}")"
  WWW_PREV_DIR="${WWW_DIR}.prev"
  WWW_SWAP_PATH="$(dirname -- "${WWW_DIR}")/.www.swap"
  RELEASES_DIR="$(path_join "${RELEASES_REL}")"
  STAGING_DIR="$(path_join "${STAGING_REL}")"
  STATE_DIR="$(path_join "${STATE_DIR_REL}")"
  STATE_PATH="$(path_join "${STATE_REL}")"
  LOCK_PATH="$(path_join "${LOCK_REL}")"
}

# --- CLI -----------------------------------------------------------------------

print_usage() {
  cat <<EOF
Uso: $0 [opciones]

Descarga el frontend publicado, lo valida en staging, lo promueve a
releases/<UTC>-<sha7>, actualiza el snapshot .prev y activa www con un único
rename(2) (swap del symlink). Después exige que <check-url> sirva el commit
recién activado; si no, hace rollback a .prev y cuarentena el commit fallado
(P-D25) para que el timer no lo re-aplique.

Opciones:
  --root DIR         prefijo para todas las rutas gestionadas (default: /)
  --dry-run          sólo informa qué haría; no escribe ni descarga el tarball
  --status           imprime SERVED_COMMIT/ACTIVATED_COMMIT/LAST_OUTCOME y el
                     estado completo
  --force            ignora la cuarentena de P-D25 y reintenta el commit
                     publicado (sólo tras revisar por qué se hizo rollback)
  --rollback         operador: vuelve www a www.prev (copia) y cuarentena el
                     commit servido; no descarga nada ni requiere red
  --check-url URL    base de la verificación post-swap (default:
                     ${CHECK_URL_DEFAULT}); el updater exige que
                     <URL>/MANIFEST.json sirva el commit recién activado.
  -h, --help         esta ayuda

Test-only:
  --source-url URL   base file:// (o ruta absoluta) con MANIFEST.json y
                     ${TARBALL_NAME}; exige --root explícito y no fuerza HTTPS.
  --check-url file://ruta   verificación local del symlink servido, sin red.
Entorno:
  VISOR_MANIFEST_HELPER  ruta al helper deploy/manifest.sh (default: junto al script)
  VISOR_CHECK_URL        default de --check-url

Exit: 0 éxito/skip/busy · 1 fallo de ejecución · 2 uso/artefacto/layout inválido.
EOF
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --root)
        (( $# >= 2 )) || die_usage 'falta el valor de --root'
        ROOT="${2%/}"
        [[ -n "${ROOT}" ]] || ROOT="/"
        ROOT_EXPLICIT=1
        shift 2
        ;;
      --source-url)
        (( $# >= 2 )) || die_usage 'falta el valor de --source-url'
        SOURCE_URL_OVERRIDE=1
        SOURCE_URL="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --status)
        STATUS=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --rollback)
        ROLLBACK=1
        shift
        ;;
      --check-url)
        (( $# >= 2 )) || die_usage 'falta el valor de --check-url'
        [[ -n "$2" ]] || die_usage '--check-url no admite un valor vacío'
        CHECK_URL="$2"
        shift 2
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      -*)
        die_usage "opción desconocida: $1"
        ;;
      *)
        die_usage "argumento inesperado: $1"
        ;;
    esac
  done

  [[ "${ROOT}" == /* ]] || die_usage "--root debe ser una ruta absoluta: ${ROOT}"
  [[ -d "${ROOT}" ]] || die_usage "--root no existe o no es un directorio: ${ROOT}"

  if (( ROLLBACK && DRY_RUN )); then
    die_usage '--rollback y --dry-run no se combinan'
  fi

  if (( SOURCE_URL_OVERRIDE )); then
    (( ROOT_EXPLICIT )) || die_usage '--source-url es sólo para tests y exige --root explícito'
    [[ -n "${SOURCE_URL}" ]] || die_usage 'falta el valor de --source-url'
    case "${SOURCE_URL}" in
      file://*) ;;
      /*) SOURCE_URL="file://${SOURCE_URL}" ;;
      *) die_usage '--source-url sólo acepta file:// o una ruta absoluta (test-only)' ;;
    esac
    MANIFEST_URL="${SOURCE_URL%/}/MANIFEST.json"
    SOURCE_URL="${SOURCE_URL%/}/${TARBALL_NAME}"
  else
    SOURCE_URL="${SOURCE_URL_DEFAULT}"
    MANIFEST_URL="${MANIFEST_URL_DEFAULT}"
  fi
}

# --- Preflight -----------------------------------------------------------------

missing_dependencies() {
  local cmd
  for cmd in curl tar flock mktemp sha256sum find sort xargs stat chmod mv cp ln readlink rm mkdir date; do
    command -v "${cmd}" >/dev/null 2>&1 || printf '%s\n' "${cmd}"
  done
  return 0
}

require_dependencies() {
  local missing
  missing="$(missing_dependencies)"
  if [[ -n "${missing}" ]]; then
    err "faltan dependencias: $(printf '%s' "${missing}" | tr '\n' ' ')"
    exit 1
  fi
}

load_manifest_helper() {
  # En los tests el helper ya está sourceado; en producción se carga una vez.
  if declare -F check_manifest >/dev/null 2>&1; then
    return 0
  fi
  local candidate
  if [[ -n "${MANIFEST_HELPER}" ]]; then
    [[ -f "${MANIFEST_HELPER}" ]] || { err "no existe el helper de manifiesto: ${MANIFEST_HELPER}"; exit 1; }
  else
    for candidate in "${SCRIPT_DIR}/manifest.sh" "/usr/local/lib/visor-camaras/manifest.sh" "/usr/local/sbin/manifest.sh"; do
      if [[ -f "${candidate}" ]]; then
        MANIFEST_HELPER="${candidate}"
        break
      fi
    done
    if [[ -z "${MANIFEST_HELPER}" ]]; then
      err 'no se encontró manifest.sh (debe instalarse junto al updater)'
      exit 1
    fi
  fi
  # shellcheck source=../manifest.sh
  source "${MANIFEST_HELPER}"
}

# --- Helpers puros -------------------------------------------------------------

# manifest_field <archivo> <campo>: imprime el valor del campo (whitelist), o
# vacío si el archivo o el campo no están. Nunca interpreta JSON arbitrario.
manifest_field() {
  local file="$1" campo="$2"
  case "${campo}" in
    commit|run_id|node|built_at|tree_sha256) ;;
    *)
      err "campo de manifiesto no permitido: ${campo}"
      return 2
      ;;
  esac
  [[ -f "${file}" ]] || return 0
  sed -n "s/.*\"${campo}\":\"\([^\"]*\)\".*/\1/p" "${file}" | head -n1
  return 0
}

# index_src_targets <index.html>: imprime el valor de cada src="...".
index_src_targets() {
  grep -oE 'src="[^"]*"' -- "$1" 2>/dev/null | sed -e 's/^src="//' -e 's/"$//' || true
}

# artifact_index_error <dir>: razón por la que index.html no sirve, o vacío.
artifact_index_error() {
  local dir="$1"
  local index="${dir}/index.html"
  local target path
  if [[ ! -f "${index}" ]]; then
    printf 'falta index.html'
    return 0
  fi
  if [[ ! -s "${index}" ]]; then
    printf 'index.html vacío'
    return 0
  fi
  if ! grep -q '<app-root' -- "${index}"; then
    printf 'index.html sin <app-root>'
    return 0
  fi
  while IFS= read -r target; do
    [[ -n "${target}" ]] || continue
    case "${target}" in
      http://*|https://*|//*|data:*) continue ;;
    esac
    if [[ "${target}" == /* ]]; then
      path="${dir}${target}"
    else
      path="${dir}/${target}"
    fi
    if [[ ! -e "${path}" ]]; then
      printf 'src= apunta a un archivo inexistente: %s' "${target}"
      return 0
    fi
  done < <(index_src_targets "${index}")
  return 0
}

# tar_entries_error <tarball>: razón por la que el tar es hostil, o vacío.
# Rechaza entradas absolutas, con .. y cualquier cosa que no sea archivo o
# directorio regular (symlinks y hardlinks incluidos): el staging no debe poder
# escribir fuera de su árbol.
tar_entries_error() {
  local tarball="$1" entry line tipo listing
  if ! listing="$(tar -tzf "${tarball}" 2>/dev/null)"; then
    printf 'no se pudo leer el tarball'
    return 0
  fi
  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    case "${entry}" in
      /*)
        printf 'entrada absoluta en el tarball: %s' "${entry}"
        return 0
        ;;
    esac
    case "/${entry}/" in
      */../*)
        printf 'entrada con .. en el tarball: %s' "${entry}"
        return 0
        ;;
    esac
  done <<< "${listing}"

  if ! listing="$(tar -tvzf "${tarball}" 2>/dev/null)"; then
    printf 'no se pudo inspeccionar el tarball'
    return 0
  fi
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    tipo="${line:0:1}"
    case "${tipo}" in
      -|d) ;;
      *)
        printf 'entrada no regular en el tarball (tipo [%s]): %s' "${tipo}" "${line}"
        return 0
        ;;
    esac
  done <<< "${listing}"
  return 0
}

release_id() { # <commit> -> <UTC>-<sha7>
  local commit="$1"
  printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$(printf '%s' "${commit}" | cut -c1-7)"
}

# --- Lecturas del artefacto servido --------------------------------------------

live_commit() {
  local manifest="${WWW_DIR}/MANIFEST.json" value=""
  if [[ -f "${manifest}" ]]; then
    value="$(manifest_field "${manifest}" commit 2>/dev/null)" || value=""
  fi
  printf '%s' "${value}"
}

find_staged_release() { # <sha7> -> path del release staged o vacío
  local sha7="$1" dir
  [[ -d "${RELEASES_DIR}" ]] || return 0
  for dir in "${RELEASES_DIR}"/*-"${sha7}"; do
    if [[ -d "${dir}" ]]; then
      printf '%s' "${dir}"
      return 0
    fi
  done
  return 0
}

count_releases() {
  [[ -d "${RELEASES_DIR}" ]] || { printf '0'; return 0; }
  find "${RELEASES_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

resolve_www_path() {
  local target=""
  if [[ -e "${WWW_DIR}" || -L "${WWW_DIR}" ]]; then
    target="$(readlink -f -- "${WWW_DIR}" 2>/dev/null || true)"
  fi
  printf '%s' "${target:-unknown}"
}

# --- Estado --------------------------------------------------------------------

state_load() {
  STATE_MAP=()
  [[ -f "${STATE_PATH}" ]] || return 0
  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" != \#* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    [[ "${key}" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    STATE_MAP["${key}"]="${value}"
  done < "${STATE_PATH}"
  return 0
}

state_set() { STATE_MAP["$1"]="$2"; }

state_unset() { unset "STATE_MAP[$1]"; }

state_value() { printf '%s' "${STATE_MAP[$1]:-}"; }

# state_flush: escribe todas las claves (las gestionadas y las desconocidas que
# ya estuvieran, p. ej. QUARANTINED_COMMIT de PR4) de forma atómica. Best-effort:
# un fallo de escritura del estado no invalida el run.
state_flush() {
  if (( DRY_RUN )); then
    return 0
  fi
  local tmp
  if ! mkdir -p -- "${STATE_DIR}" 2>/dev/null \
    || ! tmp="$(mktemp "${STATE_DIR}/.state.XXXXXX" 2>/dev/null)"; then
    warn "no se pudo preparar ${STATE_DIR}; el estado no se registró"
    return 0
  fi
  {
    while IFS= read -r key; do
      [[ -n "${key}" ]] || continue
      printf '%s=%s\n' "${key}" "${STATE_MAP[${key}]}"
    done < <(printf '%s\n' "${!STATE_MAP[@]}" | LC_ALL=C sort)
  } > "${tmp}"
  chmod 0600 -- "${tmp}" 2>/dev/null || true
  if ! mv -fT -- "${tmp}" "${STATE_PATH}" 2>/dev/null; then
    warn "no se pudo escribir ${STATE_PATH}"
    rm -f -- "${tmp}"
    return 0
  fi
  return 0
}

state_file_value() { # <clave> -> valor del archivo, o vacío
  local key="$1" value=""
  if [[ -f "${STATE_PATH}" ]]; then
    value="$(sed -n "s/^${key}=//p" "${STATE_PATH}" | head -n1)"
  fi
  printf '%s' "${value}"
}

record_outcome() { # <outcome> <error>
  local now live
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state_set LAST_OUTCOME "$1"
  state_set LAST_AT "${now}"
  state_set LAST_ERROR "${2:-}"
  live="$(live_commit)"
  [[ -n "${live}" ]] || live="unknown"
  if [[ "$(state_value SERVED_COMMIT)" != "${live}" || -z "$(state_value SERVED_AT)" ]]; then
    state_set SERVED_AT "${now}"
  fi
  state_set SERVED_COMMIT "${live}"
  state_flush
}

# --- Errores -------------------------------------------------------------------

fail_run() { # <mensaje> -> exit 1
  err "$1"
  record_outcome failed "$1"
  exit 1
}

reject_artifact() { # <mensaje> -> exit 2
  err "$1"
  record_outcome failed "$1"
  exit 2
}

cleanup_run() {
  if [[ -n "${STAGING_ACTIVE}" && -d "${STAGING_ACTIVE}" ]]; then
    rm -rf -- "${STAGING_ACTIVE}"
  fi
  if [[ -n "${RUN_TMP}" && -d "${RUN_TMP}" ]]; then
    rm -rf -- "${RUN_TMP}"
  fi
  return 0
}

# --- Fases ---------------------------------------------------------------------

https_fetch() { # <url> <destino> <max-time>
  local url="$1" out="$2" max="$3"
  local -a proto=()
  if (( SOURCE_URL_OVERRIDE )); then
    proto=()
  else
    proto=(--proto '=https' --tlsv1.2)
  fi
  curl -fsSL "${proto[@]}" \
    --connect-timeout "${CONNECT_TIMEOUT}" \
    --max-time "${max}" \
    --retry 3 \
    --max-filesize "${MAX_TARBALL_BYTES}" \
    -o "${out}" "${url}"
}

fetch_candidate_commit() { # imprime el commit publicado, o vacío si no se pudo
  local tmp="${RUN_TMP}/MANIFEST.published.json" commit=""
  if ! https_fetch "${MANIFEST_URL}" "${tmp}" "${MANIFEST_MAX_TIME}"; then
    warn 'no se pudo descargar el MANIFEST.json publicado; se decide con el tarball'
    return 0
  fi
  if [[ ! -s "${tmp}" ]]; then
    warn 'el MANIFEST.json publicado llegó vacío; se decide con el tarball'
    return 0
  fi
  commit="$(manifest_field "${tmp}" commit 2>/dev/null)" || commit=""
  if [[ -z "${commit}" ]]; then
    warn 'el MANIFEST.json publicado no tiene commit válido; se decide con el tarball'
    return 0
  fi
  printf '%s' "${commit}"
}

fetch_tarball() { # -> TARBALL_FILE
  local size
  TARBALL_FILE="${RUN_TMP}/${TARBALL_NAME}"
  if ! https_fetch "${SOURCE_URL}" "${TARBALL_FILE}" "${TARBALL_MAX_TIME}"; then
    fail_run 'no se pudo descargar el tarball publicado'
  fi
  if [[ ! -s "${TARBALL_FILE}" ]]; then
    fail_run 'la descarga del tarball quedó vacía'
  fi
  size="$(stat -c '%s' -- "${TARBALL_FILE}")"
  if (( size > MAX_TARBALL_BYTES )); then
    reject_artifact "tarball demasiado grande: ${size} bytes (tope ${MAX_TARBALL_BYTES})"
  fi
}

stage_tarball() { # <tarball> -> STAGING_ACTIVE (mismo filesystem que releases/)
  local reason
  reason="$(tar_entries_error "$1")"
  [[ -z "${reason}" ]] || reject_artifact "tarball rechazado: ${reason}"
  STAGING_ACTIVE="$(mktemp -d "${STAGING_DIR}/update.XXXXXX")" \
    || fail_run "no se pudo crear el staging en ${STAGING_DIR}"
  if ! tar -xzf "$1" --strip-components=1 --no-same-owner --no-same-permissions \
    -C "${STAGING_ACTIVE}" 2>"${RUN_TMP}/tar.err"; then
    reject_artifact "tarball rechazado: falló la extracción ($(head -n1 -- "${RUN_TMP}/tar.err"))"
  fi
}

validate_staged() { # <dir> <commit-esperado|"">
  local dir="$1" expected="$2" reason helper_out commit
  reason="$(artifact_index_error "${dir}")"
  [[ -z "${reason}" ]] || reject_artifact "artefacto inválido: ${reason}"
  [[ -f "${dir}/MANIFEST.json" ]] || reject_artifact 'artefacto inválido: falta MANIFEST.json'
  helper_out=""
  if ! helper_out="$(check_manifest "${dir}" 2>&1)"; then
    reject_artifact "artefacto inválido: ${helper_out}"
  fi
  commit="$(manifest_field "${dir}/MANIFEST.json" commit 2>/dev/null)" || commit=""
  [[ -n "${commit}" ]] || reject_artifact 'artefacto inválido: MANIFEST.json sin commit'
  if [[ -n "${expected}" && "${commit}" != "${expected}" ]]; then
    reject_artifact "artefacto inválido: el manifiesto publicado (${expected:0:7}) no coincide con el del tarball (${commit:0:7})"
  fi
}

promote_release() { # <commit> -> RELEASE_PATH
  local commit="$1" dest
  dest="${RELEASES_DIR}/$(release_id "${commit}")"
  if [[ -e "${dest}" ]]; then
    if [[ "$(readlink -f -- "${dest}")" == "$(readlink -f -- "${WWW_DIR}")" ]]; then
      fail_run "el destino de la promoción es el release servido: ${dest}"
    fi
    warn "se reemplaza un release previo incompleto: ${dest}"
    rm -rf -- "${dest}"
  fi
  mv -T -- "${STAGING_ACTIVE}" "${dest}" \
    || fail_run "no se pudo promover el staging a ${dest}"
  STAGING_ACTIVE=""
  if (( EUID == 0 )); then
    chown -R "${RUN_USER}:${RUN_USER}" "${dest}" || warn "no se pudo hacer chown de ${dest}"
  fi
  chmod -R a+rX -- "${dest}" || warn "no se pudo hacer chmod de ${dest}"
  RELEASE_PATH="${dest}"
}

# --- Activación (P-D15/P-D16/P-D17/P-D25) --------------------------------------
#
# Semántica de www.prev: copia real (no symlink, no rename) del contenido
# servido antes del swap; es el destino del rollback. Mientras www sirva desde
# www.prev (post-rollback), el snapshot se conserva tal cual: reemplazarlo
# borraría el contenido vivo. La activación siguiente (con www sobre
# releases/<id>) vuelve a copiar normalmente.
#
# Atomicidad: el swap es `ln -sfn <destino> .www.swap && mv -T .www.swap www`,
# un único rename(2) de symlink sobre symlink: el path servido nunca falta ni
# queda a medio escribir. Un corte se reanuda con ACTIVATION_PENDING.

swap_www_to() { # <destino relativo al directorio padre de www>
  local target="$1"
  ln -sfn -- "${target}" "${WWW_SWAP_PATH}" || return 1
  if ! mv -T -- "${WWW_SWAP_PATH}" "${WWW_DIR}"; then
    rm -f -- "${WWW_SWAP_PATH}"
    return 1
  fi
  return 0
}

snapshot_prev() {
  local www_resolved prev_resolved
  www_resolved="$(readlink -f -- "${WWW_DIR}" 2>/dev/null || true)"
  prev_resolved="$(readlink -f -- "${WWW_PREV_DIR}" 2>/dev/null || true)"
  if [[ -n "${www_resolved}" && -n "${prev_resolved}" && "${www_resolved}" == "${prev_resolved}" ]]; then
    log "www ya sirve desde ${WWW_PREV_DIR}; se conserva como rollback"
    return 0
  fi
  rm -rf -- "${WWW_PREV_DIR}.new" || fail_run "no se pudo limpiar ${WWW_PREV_DIR}.new"
  mkdir -p -- "${WWW_PREV_DIR}.new" || fail_run "no se pudo crear ${WWW_PREV_DIR}.new"
  cp -a -- "${WWW_DIR}/." "${WWW_PREV_DIR}.new/" \
    || fail_run "no se pudo copiar el sitio servido a ${WWW_PREV_DIR}.new"
  rm -rf -- "${WWW_PREV_DIR}" || fail_run "no se pudo reemplazar ${WWW_PREV_DIR}"
  mv -T -- "${WWW_PREV_DIR}.new" "${WWW_PREV_DIR}" || fail_run "no se pudo instalar ${WWW_PREV_DIR}"
  log "snapshot .prev actualizado: ${WWW_PREV_DIR}"
}

verify_served_release() { # <commit> -> 0 si el sitio sirve y responde ese commit
  local commit="$1" base out got
  VERIFY_ERROR=""
  got="$(live_commit)"
  if [[ "${got}" != "${commit}" ]]; then
    VERIFY_ERROR="el symlink ${WWW_DIR} sirve ${got:-nada} (esperado ${commit:0:7})"
    return 1
  fi
  base="${CHECK_URL%/}"
  out="${RUN_TMP}/check-root.html"
  if ! curl -fsS --connect-timeout "${CHECK_TIMEOUT}" --max-time "${CHECK_TIMEOUT}" \
    -o "${out}" "${base}/"; then
    VERIFY_ERROR="no se pudo consultar ${base}/"
    return 1
  fi
  if [[ ! -s "${out}" ]]; then
    VERIFY_ERROR="${base}/ respondió vacío"
    return 1
  fi
  out="${RUN_TMP}/check-manifest.json"
  if ! curl -fsS --connect-timeout "${CHECK_TIMEOUT}" --max-time "${CHECK_TIMEOUT}" \
    -o "${out}" "${base}/MANIFEST.json"; then
    VERIFY_ERROR="no se pudo consultar ${base}/MANIFEST.json"
    return 1
  fi
  got="$(manifest_field "${out}" commit 2>/dev/null)" || got=""
  if [[ "${got}" != "${commit}" ]]; then
    VERIFY_ERROR="${base}/MANIFEST.json sirve ${got:-nada} (esperado ${commit:0:7})"
    return 1
  fi
  return 0
}

rollback_and_fail() { # <commit-fallado> <motivo> -> exit 1
  local commit="$1" reason="$2" now live
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state_set QUARANTINED_COMMIT "${commit}"
  state_set QUARANTINED_AT "${now}"
  state_unset ACTIVATION_PENDING
  if [[ -e "${WWW_PREV_DIR}" ]] && swap_www_to "${WWW_PREV_DIR##*/}"; then
    err "rollback: ${WWW_DIR} vuelve a ${WWW_PREV_DIR}"
    live="$(live_commit)"
    if [[ -n "${PREV_COMMIT}" && "${live}" != "${PREV_COMMIT}" ]]; then
      warn "rollback: se sirve ${live:-nada}, distinto de lo servido antes (${PREV_COMMIT:0:7})"
    fi
  else
    warn "rollback: no se pudo volver a ${WWW_PREV_DIR}; el sitio queda en el release no verificado"
  fi
  record_outcome failed "${reason}"
  exit 1
}

finalize_activation() { # <commit> <release>
  local commit="$1" release="$2" now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state_set ACTIVATED_COMMIT "${commit}"
  state_set ACTIVATED_AT "${now}"
  state_set STAGED_COMMIT "${commit}"
  state_set STAGED_AT "${now}"
  [[ -n "${release}" ]] && state_set STAGED_PATH "${release}"
  state_unset ACTIVATION_PENDING
  if [[ "$(state_value QUARANTINED_COMMIT)" == "${commit}" ]]; then
    state_unset QUARANTINED_COMMIT
    state_unset QUARANTINED_AT
  fi
}

activate_release() { # <release-dir>
  local release="$1" commit rel
  [[ -d "${release}" && -f "${release}/MANIFEST.json" ]] \
    || fail_run "activación: release inválido: ${release}"
  commit="$(manifest_field "${release}/MANIFEST.json" commit 2>/dev/null)" || commit=""
  [[ -n "${commit}" ]] || fail_run "activación: el release no declara commit: ${release}"
  rel="${release#"${RELEASES_DIR}/"}"
  if [[ "${rel}" == "${release}" || "${rel}" == */* || -z "${rel}" ]]; then
    fail_run "activación: release fuera de ${RELEASES_DIR}: ${release}"
  fi
  PREV_COMMIT="$(live_commit)"
  snapshot_prev
  state_set ACTIVATION_PENDING "${commit}"
  state_set STAGED_COMMIT "${commit}"
  state_set STAGED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state_set STAGED_PATH "${release}"
  state_flush
  if ! swap_www_to "releases/${rel}"; then
    state_unset ACTIVATION_PENDING
    fail_run "activación: no se pudo hacer el swap atómico de ${WWW_DIR}"
  fi
  if ! verify_served_release "${commit}"; then
    rollback_and_fail "${commit}" "activación fallida: ${VERIFY_ERROR}"
  fi
  finalize_activation "${commit}" "${release}"
  record_outcome success ''
  log "release activado y verificado: ${release}"
}

prune_releases() { # <keep>
  local keep="$1" served rel path removable i n
  local -a all=()
  [[ -d "${RELEASES_DIR}" ]] || return 0
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] && all+=("${rel}")
  done < <(find "${RELEASES_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
  n="${#all[@]}"
  (( n > keep )) || return 0
  served="$(resolve_www_path)"
  removable=$((n - keep))
  for ((i = 0; i < removable; i++)); do
    rel="${all[i]}"
    path="${RELEASES_DIR}/${rel}"
    if [[ "$(readlink -f -- "${path}")" == "${served}" ]]; then
      warn "poda: se conserva ${rel} (es el release que sirve www)"
      continue
    fi
    if rm -rf -- "${path}"; then
      log "poda: release viejo eliminado: ${rel}"
    else
      warn "poda: no se pudo eliminar ${rel}"
    fi
  done
  return 0
}

# resume_pending_activation: si un corte dejó ACTIVATION_PENDING, decide con el
# estado real del symlink. Devuelve 0 si resolvió el run (verificó y finalizó, o
# hizo rollback); 1 para seguir con las fases normales.
resume_pending_activation() {
  local pending live release
  pending="$(state_value ACTIVATION_PENDING)"
  [[ -n "${pending}" ]] || return 1
  if (( DRY_RUN )); then
    warn "dry-run: hay una activación pendiente (${pending:0:7}); no se toca (reanudala sin --dry-run)"
    return 0
  fi
  live="$(live_commit)"
  if [[ "${live}" != "${pending}" ]]; then
    log "activación pendiente ${pending:0:7} sin aplicar; se limpia y se reintenta"
    state_unset ACTIVATION_PENDING
    state_flush
    return 1
  fi
  log "activación pendiente detectada (${pending:0:7}); se verifica antes de continuar"
  if ! verify_served_release "${pending}"; then
    rollback_and_fail "${pending}" "activación pendiente no verificó: ${VERIFY_ERROR}"
  fi
  release="$(find_staged_release "${pending:0:7}")"
  finalize_activation "${pending}" "${release}"
  record_outcome success ''
  log "activación pendiente completada y verificada: ${pending:0:7}"
  prune_releases "${KEEP_RELEASES}"
  return 0
}

run_phases() {
  local served candidate staged commit tarball_existing quarantine
  if resume_pending_activation; then
    return 0
  fi
  served="$(live_commit)"
  candidate="$(fetch_candidate_commit)"
  quarantine="$(state_value QUARANTINED_COMMIT)"

  if [[ -n "${candidate}" ]]; then
    if [[ "${candidate}" == "${served}" ]]; then
      log "sin cambios: ya se sirve ${candidate:0:7}"
      record_outcome skipped ''
      return 0
    fi
    if [[ "${candidate}" == "${quarantine}" ]] && (( ! FORCE )); then
      log "commit en cuarentena (${candidate:0:7}); no se re-aplica sin --force"
      record_outcome quarantined "commit en cuarentena: ${candidate:0:7}"
      return 0
    fi
    staged="$(find_staged_release "${candidate:0:7}")"
    if [[ -n "${staged}" ]]; then
      log "release ya validado (${candidate:0:7}); se activa: ${staged}"
      activate_release "${staged}"
      prune_releases "${KEEP_RELEASES}"
      return 0
    fi
    if (( DRY_RUN )); then
      log "dry-run: hay actualización disponible (${candidate:0:7}); se saltea el tarball"
      return 0
    fi
  elif (( DRY_RUN )); then
    warn 'dry-run: no se pudo leer el manifiesto publicado'
    return 1
  fi

  fetch_tarball
  stage_tarball "${TARBALL_FILE}"
  validate_staged "${STAGING_ACTIVE}" "${candidate}"
  commit="$(manifest_field "${STAGING_ACTIVE}/MANIFEST.json" commit 2>/dev/null)" || commit=""

  # Sin manifiesto previo el commit recién se conoce acá: si ya está servido o
  # staged, el staging se descarta sin tocar nada.
  if [[ "${commit}" == "${served}" ]]; then
    log "sin cambios: el tarball coincide con lo servido (${commit:0:7})"
    cleanup_run
    record_outcome skipped ''
    return 0
  fi
  if [[ "${commit}" == "${quarantine}" ]] && (( ! FORCE )); then
    log "commit en cuarentena (${commit:0:7}); se descarta el staging"
    cleanup_run
    record_outcome quarantined "commit en cuarentena: ${commit:0:7}"
    return 0
  fi
  tarball_existing="$(find_staged_release "${commit:0:7}")"
  if [[ -n "${tarball_existing}" ]]; then
    log "release ya validado (${commit:0:7}); se activa: ${tarball_existing}"
    if [[ -n "${STAGING_ACTIVE}" && -d "${STAGING_ACTIVE}" ]]; then
      rm -rf -- "${STAGING_ACTIVE}"
    fi
    STAGING_ACTIVE=""
    activate_release "${tarball_existing}"
    prune_releases "${KEEP_RELEASES}"
    return 0
  fi

  promote_release "${commit}"
  activate_release "${RELEASE_PATH}"
  prune_releases "${KEEP_RELEASES}"
  return 0
}

cmd_status() {
  local served outcome activated quarantined
  served="$(state_file_value SERVED_COMMIT)"
  outcome="$(state_file_value LAST_OUTCOME)"
  if [[ -z "${served}" ]]; then
    served="$(live_commit)"
  fi
  [[ -n "${served}" ]] || served="unknown"
  [[ -n "${outcome}" ]] || outcome="unknown"
  activated="$(state_file_value ACTIVATED_COMMIT)"
  [[ -n "${activated}" ]] || activated="unknown"
  quarantined="$(state_file_value QUARANTINED_COMMIT)"
  [[ -n "${quarantined}" ]] || quarantined="none"
  printf 'SERVED_COMMIT=%s\n' "${served}"
  printf 'ACTIVATED_COMMIT=%s\n' "${activated}"
  printf 'QUARANTINED_COMMIT=%s\n' "${quarantined}"
  printf 'LAST_OUTCOME=%s\n' "${outcome}"
  if [[ -f "${STATE_PATH}" ]]; then
    printf -- '--- estado completo (%s) ---\n' "${STATE_PATH}"
    cat -- "${STATE_PATH}"
  else
    printf 'STATE_FILE=ausente (%s)\n' "${STATE_PATH}"
  fi
  printf 'SERVED_PATH=%s\n' "$(resolve_www_path)"
  printf 'STAGED_RELEASES=%s\n' "$(count_releases)"
  return 0
}

cmd_rollback() { # operador: www -> www.prev + cuarentena del commit servido
  local served now
  if [[ ! -e "${WWW_PREV_DIR}" ]]; then
    fail_run "rollback manual: no existe ${WWW_PREV_DIR}; no hay a qué volver"
  fi
  served="$(live_commit)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! swap_www_to "${WWW_PREV_DIR##*/}"; then
    fail_run "rollback manual: no se pudo hacer el swap de ${WWW_DIR}"
  fi
  state_unset ACTIVATION_PENDING
  if [[ -n "${served}" ]]; then
    state_set QUARANTINED_COMMIT "${served}"
    state_set QUARANTINED_AT "${now}"
  else
    warn 'rollback manual: no se pudo leer el commit servido; no se cuarentenó nada'
  fi
  record_outcome quarantined "rollback manual: ${served:0:7}"
  log "rollback manual completo: ${WWW_DIR} -> ${WWW_PREV_DIR} (cuarentena: ${served:0:7})"
  return 0
}

main_update() {
  parse_args "$@"
  resolve_paths

  if (( STATUS )); then
    cmd_status
    exit 0
  fi

  require_dependencies
  state_load

  if (( SOURCE_URL_OVERRIDE )); then
    warn "--source-url activo (sólo tests): no se fuerza HTTPS"
  fi

  if [[ ! -L "${WWW_DIR}" ]]; then
    reject_artifact "layout inválido: ${WWW_DIR} debe ser un symlink a releases/ (la migración legacy la hace install-lxc.sh, atendida)"
  fi

  if ! mkdir -p -- "$(dirname -- "${LOCK_PATH}")" 2>/dev/null; then
    err "no se pudo crear $(dirname -- "${LOCK_PATH}")"
    exit 1
  fi
  exec 9>"${LOCK_PATH}"
  if ! flock -n 9; then
    log 'otra corrida del updater en curso; se sale sin tocar nada'
    exit 0
  fi

  if (( ROLLBACK )); then
    # El rollback no valida artefactos: no debe depender del helper de manifiesto.
    cmd_rollback
    exit 0
  fi

  load_manifest_helper
  umask 077
  RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/visor-camaras-update.XXXXXX")"
  trap 'cleanup_run' EXIT INT TERM

  if (( DRY_RUN )); then
    warn '--dry-run: no se escribe nada (ni staging, ni releases, ni estado)'
  else
    mkdir -p -- "${STAGING_DIR}" "${RELEASES_DIR}"
  fi

  run_phases
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main_update "$@"
fi
