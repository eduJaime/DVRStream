#!/usr/bin/env bash
#
# visor-camaras-update.sh -- actualiza el frontend publicado del visor de cámaras.
#
# Alcance PR3: fetch / validación / staging / estado / poda, más las unidades
# systemd. NO activa nada: el swap atómico del symlink www, el snapshot .prev,
# el rollback y la cuarentena son PR4 y se insertan en el seam activate_release().
# Un run exitoso deja el release validado en releases/<UTC>-<sha7> y NO toca lo
# que se está sirviendo.
#
# Uso:
#   visor-camaras-update.sh [--root DIR] [--dry-run] [--status]
#
# Test-only (no usar en producción):
#   visor-camaras-update.sh --root DIR --source-url file:///ruta [--dry-run]
#   --source-url exige --root explícito y saltea el forzado HTTPS; sirve para
#   correr el harness en un sandbox, sin red y sin root.
#
# Fases (P-D18/P-D19):
#   0. preflight: dependencias, layout (www debe ser symlink), flock -n
#   1. fetch del MANIFEST.json publicado (HTTPS, timeout corto)
#   2. detección de cambios (commit publicado vs servido / ya staged)
#   3. fetch del tarball (HTTPS, timeouts, retry y tope de tamaño)
#   4. extracción a .staging rechazando entradas hostiles (absolutas, .., symlinks)
#   5. validación: index.html usable + tree_sha256 vía deploy/manifest.sh
#   6. promoción a releases/<UTC>-<sha7> (rename en el mismo filesystem)
#   7. [SEAM PR4] activación atómica, .prev, verificación post-swap, rollback
#   8. poda acotada (se conservan los 5 releases más nuevos + el servido)
#   9. estado atómico en /var/lib/visor-camaras-update/state
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
SOURCE_URL_OVERRIDE=0
SOURCE_URL=""
MANIFEST_URL=""
MANIFEST_HELPER="${VISOR_MANIFEST_HELPER:-}"

WWW_DIR=""
RELEASES_DIR=""
STAGING_DIR=""
STATE_DIR=""
STATE_PATH=""
LOCK_PATH=""

RUN_TMP=""
STAGING_ACTIVE=""
TARBALL_FILE=""
RELEASE_PATH=""

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

Descarga el frontend publicado, lo valida en staging y lo deja listo en
releases/<UTC>-<sha7>. No activa nada: eso es PR4. El contenido servido
(normalmente ${WWW_DIR}) queda intacto.

Opciones:
  --root DIR         prefijo para todas las rutas gestionadas (default: /)
  --dry-run          sólo informa qué haría; no escribe ni descarga el tarball
  --status           imprime SERVED_COMMIT/LAST_OUTCOME y el estado completo
  -h, --help         esta ayuda

Test-only:
  --source-url URL   base file:// (o ruta absoluta) con MANIFEST.json y
                     ${TARBALL_NAME}; exige --root explícito y no fuerza HTTPS.
Entorno:
  VISOR_MANIFEST_HELPER  ruta al helper deploy/manifest.sh (default: junto al script)

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
  for cmd in curl tar flock mktemp sha256sum find sort xargs stat chmod mv rm mkdir date; do
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

# --- Seam PR4 ------------------------------------------------------------------
#
# Acá va la activación atómica de PR4: snapshot .prev (cp -a www/. ), swap del
# symlink con `ln -sfn releases/<id> .www.swap && mv -T .www.swap www`,
# verificación post-swap contra http://127.0.0.1:1984/ y rollback con cuarentena
# (el commit fallado no se reintenta sin --force). En PR3 el release queda
# validado y visible en STAGED_COMMIT/STAGED_PATH; el path servido no se toca.
activate_release() { # <release-dir>
  log "release validado, listo para activar (activación atómica: PR4): $1"
  return 0
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

run_phases() {
  local served candidate staged commit tarball_existing
  served="$(live_commit)"
  candidate="$(fetch_candidate_commit)"

  if [[ -n "${candidate}" ]]; then
    if [[ "${candidate}" == "${served}" ]]; then
      log "sin cambios: ya se sirve ${candidate:0:7}"
      record_outcome skipped ''
      return 0
    fi
    staged="$(find_staged_release "${candidate:0:7}")"
    if [[ -n "${staged}" ]]; then
      # SEAM PR4: con el release ya validado, acá PR4 activaría (swap + .prev).
      log "sin cambios: ${candidate:0:7} ya está staged en ${staged}"
      record_outcome skipped ''
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
  tarball_existing="$(find_staged_release "${commit:0:7}")"
  if [[ -n "${tarball_existing}" ]]; then
    log "sin cambios: ${commit:0:7} ya está staged en ${tarball_existing}"
    cleanup_run
    record_outcome skipped ''
    return 0
  fi

  promote_release "${commit}"
  activate_release "${RELEASE_PATH}"
  prune_releases "${KEEP_RELEASES}"

  state_set STAGED_COMMIT "${commit}"
  state_set STAGED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state_set STAGED_PATH "${RELEASE_PATH}"
  record_outcome success ''
  log "release staged: ${RELEASE_PATH}"
  return 0
}

cmd_status() {
  local served outcome
  served="$(state_file_value SERVED_COMMIT)"
  outcome="$(state_file_value LAST_OUTCOME)"
  if [[ -z "${served}" ]]; then
    served="$(live_commit)"
  fi
  [[ -n "${served}" ]] || served="unknown"
  [[ -n "${outcome}" ]] || outcome="unknown"
  printf 'SERVED_COMMIT=%s\n' "${served}"
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

main_update() {
  parse_args "$@"
  resolve_paths

  if (( STATUS )); then
    cmd_status
    exit 0
  fi

  require_dependencies
  load_manifest_helper
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
