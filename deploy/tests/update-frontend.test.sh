#!/usr/bin/env bash
#
# update-frontend.test.sh -- Tests sin dependencias del updater del visor.
#
# Uso:
#   bash deploy/tests/update-frontend.test.sh
#
# Alcance (slice PR4): fetch/validar/staging + activación atómica (swap del
# symlink), .prev, verificación post-swap, rollback, cuarentena y reanudación
# de una activación interrumpida, más estado/poda y unidades systemd.
#
# Sólo usa bash + coreutils + tar + flock + curl (el runtime del propio updater).
# No requiere root ni red: el updater corre con --root en un sandbox y
# --source-url file://…; las fallas de red y de permisos se inyectan stubbeando
# curl, igual que install-lxc.test.sh stubbea chown/systemctl. La verificación
# post-swap apunta a --check-url file://<sandbox>/opt/visor-camaras/www, que
# curl resuelve localmente contra el symlink servido (sin red y sin stubs).
#
# Cubre:
#   - CLI: uso, flags, contención del hook --source-url, --status sin estado
#   - helpers puros: manifest_field, index_src_targets, artifact_index_error,
#     tar_entries_error, release_id, missing_dependencies
#   - sandbox end-to-end: staging válido, activación atómica, .prev, idempotencia,
#     skip, manifiesto y tar hostiles, fetch parcial/vacío, tope de tamaño,
#     layout inválido, flock ocupado, --dry-run, poda acotada, estado atómico
#   - activación: verificación post-swap (ok / commit incorrecto / check
#     inejecutable), rollback, cuarentena, --force, --rollback manual y
#     reanudación de ACTIVATION_PENDING tras un corte
#   - unidades systemd: invariantes estructurales (cadencia + endurecimiento)
#
# Corta en el primer fallo (exit 1) para mantener la salida legible.

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UPDATER="${TEST_DIR}/../visor-camaras-update.sh"
MANIFEST_SH="${TEST_DIR}/../manifest.sh"
UNIT_SERVICE="${TEST_DIR}/../visor-camaras-update.service"
UNIT_TIMER="${TEST_DIR}/../visor-camaras-update.timer"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/update-frontend.test.XXXXXX")"
trap 'rm -rf -- "${WORK_DIR}"' EXIT

CASES=0
CURRENT=""

begin() { CURRENT="$1"; }

fail() {
  printf '\033[1;31mFAIL\033[0m %s\n' "${CURRENT}" >&2
  printf '     %s\n' "$1" >&2
  printf '\n%d assertions pasaron, 1 falló (se corta acá)\n' "${CASES}" >&2
  exit 1
}

ok() { CASES=$((CASES + 1)); }

assert_eq() { # <label> <esperado> <obtenido>
  [[ "$2" == "$3" ]] || fail "$1: esperado [$2], obtenido [$3]"
  ok
}

assert_ne() { # <label> <a> <b>
  [[ "$2" != "$3" ]] || fail "$1: ambos valores son [$2]"
  ok
}

assert_contains() { # <label> <texto> <substring>
  [[ "$2" == *"$3"* ]] || fail "$1: se esperaba encontrar [$3] en [$2]"
  ok
}

assert_not_contains() { # <label> <texto> <substring>
  [[ "$2" != *"$3"* ]] || fail "$1: NO debía contener [$3]"
  ok
}

assert_regex() { # <label> <regex> <valor>
  [[ "$3" =~ $2 ]] || fail "$1: [$3] no matchea /$2/"
  ok
}

assert_exists() { # <label> <path>
  [[ -e "$2" ]] || fail "$1: no existe $2"
  ok
}

assert_missing() { # <label> <path>
  [[ ! -e "$2" ]] || fail "$1: no debía existir $2"
  ok
}

assert_clean_staging() { # <label> <sandbox>
  local rest
  rest="$(find "$2/opt/visor-camaras/.staging" -mindepth 1 2>/dev/null | head -n1 || true)"
  assert_eq "$1" "" "${rest}"
}

assert_no_crlf() { # <label> <archivo>
  if grep -q $'\r' -- "$2"; then fail "$1: $2 tiene CRLF"; fi
  ok
}

assert_args_has() { # <archivo de args de curl> <token literal>
  grep -qxF -- "$2" "$1" || fail "curl no recibió [$2]"
  ok
}

# run_capture <cmd...> -> OUT (stdout), ERR (stderr), RC (exit code).
# stdin se cierra para que ningún prompt pueda bloquear el test.
run_capture() {
  local errfile="${WORK_DIR}/stderr"
  set +e
  OUT="$("$@" </dev/null 2>"${errfile}")"
  RC=$?
  set -e
  ERR="$(<"${errfile}")"
}

# --- Estado global de los fixtures y stub de curl ------------------------------

SERVED_COMMIT="1111111111111111111111111111111111111111"
SERVED_SHA7="1111111"
NEW_COMMIT="2222222222222222222222222222222222222222"
NEW_SHA7="2222222"
OTHER_COMMIT="3333333333333333333333333333333333333333"

SB_COUNTER=0
PUB_COUNTER=0
SB_ROOT=""
PUB_DIR=""
SERVED_RELEASE=""

CURL_ARGS_FILE="${WORK_DIR}/curl.args"
CURL_MANIFEST_MODE="ok"
CURL_TARBALL_MODE="ok"
FIXTURE_MANIFEST=""
FIXTURE_TARBALL=""

# Stub de curl: registra los argumentos y copia el fixture local según el modo
# inyectado (fail/partial/empty/oversize). Nunca toca la red.
curl() {
  local -a args=("$@")
  local i out="" url=""
  printf '%s\n' "$@" >> "${CURL_ARGS_FILE}"
  printf -- '--\n' >> "${CURL_ARGS_FILE}"
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[i]}" == "-o" ]]; then
      out="${args[i + 1]}"
    fi
  done
  url="${args[${#args[@]} - 1]}"

  # file:// fuera del directorio publicado (p. ej. el --check-url de la
  # verificación post-swap): se atiende con curl real, que para file:// no usa
  # la red. Así la verificación lee de verdad el symlink servido del sandbox.
  if [[ "${url}" == file://* && "${url}" != "file://${PUB_DIR}/"* ]]; then
    command curl "$@"
    return $?
  fi

  if [[ "${url}" == *MANIFEST.json ]]; then
    if [[ "${CURL_MANIFEST_MODE}" == "fail" ]]; then
      return 22
    fi
    cp -- "${FIXTURE_MANIFEST}" "${out}"
    return 0
  fi

  case "${CURL_TARBALL_MODE}" in
    fail) return 22 ;;
    partial)
      head -c 64 -- "${FIXTURE_TARBALL}" > "${out}"
      return 22
      ;;
    empty)
      : > "${out}"
      return 0
      ;;
    oversize)
      truncate -s 52428801 -- "${out}"
      return 0
      ;;
    *)
      cp -- "${FIXTURE_TARBALL}" "${out}"
      return 0
      ;;
  esac
}

# run_update <args...> -> OUT/RC/ERR ejecutando main_update en un subshell, así
# los stubs de curl valen y ningún `exit` del updater mata al harness.
run_update() {
  local errfile="${WORK_DIR}/run.stderr"
  set +e
  OUT="$( ( main_update "$@" ) </dev/null 2>"${errfile}" )"
  RC=$?
  set -e
  ERR="$(<"${errfile}")"
}

# run_update_swap_falla <args...>: inyecta un fallo del swap atómico de la
# activación. La redefinición vive sólo en el subshell.
run_update_swap_falla() {
  local errfile="${WORK_DIR}/run.stderr"
  set +e
  OUT="$( ( swap_www_to() { return 1; }; main_update "$@" ) </dev/null 2>"${errfile}" )"
  RC=$?
  set -e
  ERR="$(<"${errfile}")"
}

# run_update_swap_equivocado <args...>: el swap de activación apunta al release
# viejo (rc 0), así la verificación local detecta que no se sirve el commit
# nuevo; el swap del rollback (destino www.prev) sí se aplica de verdad.
run_update_swap_equivocado() {
  local errfile="${WORK_DIR}/run.stderr"
  set +e
  OUT="$( (
    swap_www_to() {
      local target="$1"
      if [[ "${target}" == "www.prev" ]]; then
        ln -sfn -- "${target}" "${WWW_SWAP_PATH}" && mv -T -- "${WWW_SWAP_PATH}" "${WWW_DIR}"
      else
        ln -sfn -- "releases/20260101T000000Z-${SERVED_SHA7}" "${WWW_SWAP_PATH}" \
          && mv -T -- "${WWW_SWAP_PATH}" "${WWW_DIR}"
      fi
    }
    main_update "$@"
  ) </dev/null 2>"${errfile}" )"
  RC=$?
  set -e
  ERR="$(<"${errfile}")"
}

# --- Fixtures ------------------------------------------------------------------

make_artifact() { # <dir> <marca>
  local dir="$1" marca="$2"
  mkdir -p -- "${dir}/go2rtc"
  printf '<!doctype html><html><head><base href="/"></head><body><app-root></app-root><script src="main-%s.js" type="module"></script></body></html>\n' \
    "${marca}" > "${dir}/index.html"
  printf 'console.log("visor-camaras %s");\n' "${marca}" > "${dir}/main-${marca}.js"
  printf 'VERSION=%s\n' "${marca}" > "${dir}/go2rtc/VERSION.txt"
}

write_manifest_for() { # <dir> <commit>
  bash "${MANIFEST_SH}" write "$1" "$2" "1234567890" "v22.22.2" "2026-09-25T12:00:00Z" >/dev/null
}

prepare_sandbox() { # <nombre>: crea --root con www -> release servido
  SB_COUNTER=$((SB_COUNTER + 1))
  SB_ROOT="${WORK_DIR}/sb-${SB_COUNTER}-$1"
  local rel="20260101T000000Z-${SERVED_SHA7}"
  SERVED_RELEASE="${SB_ROOT}/opt/visor-camaras/releases/${rel}"
  make_artifact "${SERVED_RELEASE}" "servido"
  write_manifest_for "${SERVED_RELEASE}" "${SERVED_COMMIT}"
  ln -s -- "releases/${rel}" "${SB_ROOT}/opt/visor-camaras/www"
}

prepare_published() { # <commit> <marca>: fuente con MANIFEST.json + tarball
  PUB_COUNTER=$((PUB_COUNTER + 1))
  PUB_DIR="${WORK_DIR}/pub-${PUB_COUNTER}"
  local staging="${PUB_DIR}/DVRStream-frontend-dist"
  make_artifact "${staging}" "$2"
  write_manifest_for "${staging}" "$1"
  rebuild_tarball
  cp -- "${staging}/MANIFEST.json" "${PUB_DIR}/MANIFEST.json"
  FIXTURE_MANIFEST="${PUB_DIR}/MANIFEST.json"
}

rebuild_tarball() {
  tar -czf "${PUB_DIR}/frontend-dist.tar.gz" -C "${PUB_DIR}" DVRStream-frontend-dist
  FIXTURE_TARBALL="${PUB_DIR}/frontend-dist.tar.gz"
}

hostile_tarball() { # <absolute|dotdot|symlink|hardlink>
  local staging="${PUB_DIR}/DVRStream-frontend-dist"
  case "$1" in
    absolute)
      tar -P -czf "${PUB_DIR}/frontend-dist.tar.gz" "${staging}/index.html"
      ;;
    dotdot)
      tar -czf "${PUB_DIR}/frontend-dist.tar.gz" --transform='s|^|../|' -C "${staging}" index.html
      ;;
    symlink)
      ln -sf -- index.html "${staging}/enlace"
      tar -czf "${PUB_DIR}/frontend-dist.tar.gz" -C "${staging}" index.html enlace
      rm -f -- "${staging}/enlace"
      ;;
    hardlink)
      cp -- "${staging}/index.html" "${staging}/copia.html"
      ln -f -- "${staging}/copia.html" "${staging}/enlace-duro.html"
      tar -czf "${PUB_DIR}/frontend-dist.tar.gz" -C "${staging}" index.html copia.html enlace-duro.html
      ;;
    *)
      fail "modo hostil desconocido: $1"
      ;;
  esac
  FIXTURE_TARBALL="${PUB_DIR}/frontend-dist.tar.gz"
}

fake_commit() { # <n> -> commit hex40 determinista
  printf '%s' "$1" | sha256sum | cut -c1-40
}

state_get() { # <sandbox> <clave>
  local file="$1/var/lib/visor-camaras-update/state"
  [[ -f "${file}" ]] || return 0
  sed -n "s/^$2=//p" "${file}" | head -n1
}

count_releases_in() { # <sandbox>
  find "$1/opt/visor-camaras/releases" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

www_target() { # <sandbox>
  readlink -- "$1/opt/visor-camaras/www"
}

www_prev_is_real_dir() { # <sandbox> -> 1 si www.prev existe como directorio real
  if [[ -d "$1/opt/visor-camaras/www.prev" && ! -L "$1/opt/visor-camaras/www.prev" ]]; then
    printf '1'
  else
    printf '0'
  fi
}

prev_commit_in() { # <sandbox> -> commit del MANIFEST.json de www.prev
  local mf="$1/opt/visor-camaras/www.prev/MANIFEST.json"
  [[ -f "${mf}" ]] || return 0
  manifest_field "${mf}" commit
}

activate_check_url() { # <sandbox>: check-url local que lee el symlink servido
  printf 'file://%s/opt/visor-camaras/www' "$1"
}

make_check_fixture() { # <dir> <commit>: "sitio servido" ajeno para el check
  mkdir -p -- "$1"
  printf '<!doctype html><html><body><app-root></app-root></body></html>\n' > "$1/index.html"
  write_manifest_for "$1" "$2"
}

# crash_activation_state <sandbox> <commit> <con-swap:0|1>: deja el sandbox como
# si el updater hubiera muerto en medio de la activación. Si <con-swap> es 1,
# www ya apunta al release nuevo (corte tras el swap); si es 0, www sigue viejo
# (corte tras el snapshot, antes del swap). En ambos casos .prev es la copia del
# contenido anterior y el estado declara ACTIVATION_PENDING.
crash_activation_state() {
  local sb="$1" commit="$2" con_swap="$3"
  local rel="releases/20260201T000000Z-${commit:0:7}"
  make_artifact "${sb}/opt/visor-camaras/${rel}" "pendiente"
  write_manifest_for "${sb}/opt/visor-camaras/${rel}" "${commit}"
  mkdir -p "${sb}/opt/visor-camaras/www.prev"
  cp -a -- "${sb}/opt/visor-camaras/www/." "${sb}/opt/visor-camaras/www.prev/"
  if (( con_swap )); then
    ln -sfn -- "${rel}" "${sb}/opt/visor-camaras/.www.swap"
    mv -T -- "${sb}/opt/visor-camaras/.www.swap" "${sb}/opt/visor-camaras/www"
  fi
  mkdir -p "${sb}/var/lib/visor-camaras-update"
  printf 'ACTIVATION_PENDING=%s\nSERVED_COMMIT=%s\n' "${commit}" "${SERVED_COMMIT}" \
    > "${sb}/var/lib/visor-camaras-update/state"
}

served_commit_in() { # <sandbox>
  local mf="$1/opt/visor-camaras/www/MANIFEST.json"
  [[ -f "${mf}" ]] || return 0
  manifest_field "${mf}" commit
}

unit_value() { # <archivo> <clave>
  grep -E "^${2}=" -- "$1" | head -n1 | cut -d= -f2- || true
}

unit_key_count() { # <archivo> <clave>
  grep -cE "^${2}=" -- "$1" || true
}

# --- Guardas del harness -------------------------------------------------------

if [[ ! -f "${UPDATER}" ]]; then
  printf 'FAIL: no existe %s\n' "${UPDATER}" >&2
  exit 1
fi

# shellcheck source=../manifest.sh
source "${MANIFEST_SH}"
# shellcheck source=../visor-camaras-update.sh
source "${UPDATER}"

if ! declare -F main_update >/dev/null; then
  printf 'FAIL: visor-camaras-update.sh no expone main_update() al sourcearlo (falta el guard)\n' >&2
  exit 1
fi

printf '\n== CLI (proceso real) ==\n'

# Nota: sin argumentos el updater corre contra ROOT=/ (es el ExecStart del
# timer). Nunca se invoca así desde el harness: sería tocar el layout real.
begin "--status con ROOT por defecto -> exit 0 (sólo lectura)"
run_capture bash "${UPDATER}" --status
assert_eq "exit 0" "0" "${RC}"
assert_contains "SERVED_COMMIT presente" "${OUT}" 'SERVED_COMMIT='
assert_contains "LAST_OUTCOME presente" "${OUT}" 'LAST_OUTCOME='

begin "--help -> exit 0"
run_capture bash "${UPDATER}" --help
assert_eq "exit 0" "0" "${RC}"
assert_contains "mensaje de uso" "${OUT}" 'Uso:'

begin "flag desconocido -> exit 2"
run_capture bash "${UPDATER}" --volar
assert_eq "exit 2" "2" "${RC}"
assert_contains "motivo" "${ERR}" 'desconocida'

begin "--check-url sin valor -> exit 2"
run_capture bash "${UPDATER}" --root "${WORK_DIR}" --check-url
assert_eq "exit 2" "2" "${RC}"
assert_contains "falta el valor" "${ERR}" 'falta el valor'

begin "--rollback con --dry-run -> exit 2 (contradictorio)"
run_capture bash "${UPDATER}" --root "${WORK_DIR}" --rollback --dry-run
assert_eq "exit 2" "2" "${RC}"
assert_contains "motivo" "${ERR}" 'no se combinan'

begin "--root relativo -> exit 2"
run_capture bash "${UPDATER}" --root relativo
assert_eq "exit 2" "2" "${RC}"
assert_contains "se exige ruta absoluta" "${ERR}" 'absoluta'

begin "--root inexistente -> exit 2"
run_capture bash "${UPDATER}" --root "${WORK_DIR}/no-existe"
assert_eq "exit 2" "2" "${RC}"

begin "--source-url sin --root explícito -> exit 2 (hook de tests contenido)"
run_capture bash "${UPDATER}" --source-url "file://${WORK_DIR}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "contención del hook" "${ERR}" 'exige --root'

begin "--source-url con scheme no file -> exit 2"
run_capture bash "${UPDATER}" --root "${WORK_DIR}" --source-url 'http://ejemplo/x'
assert_eq "exit 2" "2" "${RC}"

begin "--status sin estado -> exit 0 y unknowns"
EMPTY_SB="${WORK_DIR}/vacio"
mkdir -p "${EMPTY_SB}"
run_capture bash "${UPDATER}" --status --root "${EMPTY_SB}"
assert_eq "exit 0" "0" "${RC}"
assert_contains "outcome inicial" "${OUT}" 'LAST_OUTCOME=unknown'
assert_contains "served inicial" "${OUT}" 'SERVED_COMMIT=unknown'
assert_contains "state ausente" "${OUT}" 'STATE_FILE=ausente'

printf '\n== helpers puros ==\n'

begin "manifest_field extrae los campos del manifiesto"
MF_DIR="${WORK_DIR}/mf"
mkdir -p "${MF_DIR}"
printf '%s\n' "{\"commit\":\"${NEW_COMMIT}\",\"run_id\":\"99\",\"node\":\"v22.22.2\",\"built_at\":\"2026-09-25T12:00:00Z\",\"tree_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}" \
  > "${MF_DIR}/MANIFEST.json"
assert_eq "commit" "${NEW_COMMIT}" "$(manifest_field "${MF_DIR}/MANIFEST.json" commit)"
assert_eq "run_id" "99" "$(manifest_field "${MF_DIR}/MANIFEST.json" run_id)"
assert_eq "built_at" "2026-09-25T12:00:00Z" "$(manifest_field "${MF_DIR}/MANIFEST.json" built_at)"

begin "manifest_field rechaza campos fuera de la whitelist"
set +e
manifest_field "${MF_DIR}/MANIFEST.json" 'commit";echo pwned' >/dev/null 2>&1
MF_RC=$?
set -e
assert_eq "exit 2" "2" "${MF_RC}"

begin "manifest_field con archivo ausente -> vacío"
assert_eq "vacío" "" "$(manifest_field "${MF_DIR}/no-existe.json" commit)"

begin "index_src_targets lista los src= tal cual"
mkdir -p "${WORK_DIR}/idx-probe"
printf '<html><body><app-root></app-root><script src="main-a.js"></script><script src="https://cdn/x.js"></script><img src="/logo.png"></body></html>\n' \
  > "${WORK_DIR}/idx-probe/index.html"
SRC_TARGETS="$(index_src_targets "${WORK_DIR}/idx-probe/index.html")"
assert_contains "relativo" "${SRC_TARGETS}" 'main-a.js'
assert_contains "absoluto" "${SRC_TARGETS}" 'https://cdn/x.js'
assert_contains "root-relativo" "${SRC_TARGETS}" '/logo.png'

IDX_DIR="${WORK_DIR}/idx"
mkdir -p "${IDX_DIR}"

begin "artifact_index_error: index válido -> sin error"
printf '<!doctype html><html><body><app-root></app-root><script src="main-a.js" type="module"></script></body></html>\n' \
  > "${IDX_DIR}/index.html"
printf 'js\n' > "${IDX_DIR}/main-a.js"
assert_eq "válido" "" "$(artifact_index_error "${IDX_DIR}")"

begin "artifact_index_error: target en subdirectorio -> sin error"
mkdir -p "${IDX_DIR}/assets"
printf 'css\n' > "${IDX_DIR}/assets/styles.css"
printf '<html><body><app-root></app-root><link rel="stylesheet" href="styles.css"><script src="assets/app.js"></script></body></html>\n' \
  > "${IDX_DIR}/index.html"
printf 'js\n' > "${IDX_DIR}/assets/app.js"
assert_eq "subdir válido" "" "$(artifact_index_error "${IDX_DIR}")"

begin "artifact_index_error: index ausente -> rechaza"
rm -f -- "${IDX_DIR}/index.html"
assert_contains "falta index.html" "$(artifact_index_error "${IDX_DIR}")" 'falta index.html'

begin "artifact_index_error: index vacío -> rechaza"
: > "${IDX_DIR}/index.html"
assert_contains "vacío" "$(artifact_index_error "${IDX_DIR}")" 'vacío'

begin "artifact_index_error: sin <app-root> -> rechaza"
printf '<html><body><div>otra app</div></body></html>\n' > "${IDX_DIR}/index.html"
assert_contains "<app-root>" "$(artifact_index_error "${IDX_DIR}")" '<app-root>'

begin "artifact_index_error: src= sin archivo -> rechaza"
printf '<html><body><app-root></app-root><script src="main-fantasma.js"></script></body></html>\n' \
  > "${IDX_DIR}/index.html"
assert_contains "src inexistente" "$(artifact_index_error "${IDX_DIR}")" 'main-fantasma.js'

begin "release_id: formato <UTC>-<sha7>"
assert_regex "formato" '^[0-9]{8}T[0-9]{6}Z-'"${NEW_SHA7}"'$' "$(release_id "${NEW_COMMIT}")"

printf '\n== tar: entradas hostiles ==\n'

TAR_DIR="${WORK_DIR}/tars"
mkdir -p "${TAR_DIR}/ok"
printf 'a\n' > "${TAR_DIR}/ok/a.txt"
printf 'b\n' > "${TAR_DIR}/ok/b.txt"
tar -czf "${TAR_DIR}/ok.tar.gz" -C "${TAR_DIR}/ok" a.txt b.txt

begin "tar normal -> sin error"
assert_eq "sin error" "" "$(tar_entries_error "${TAR_DIR}/ok.tar.gz")"

begin "tar con entrada absoluta -> rechaza"
tar -P -czf "${TAR_DIR}/abs.tar.gz" "${TAR_DIR}/ok/a.txt"
assert_contains "absoluta" "$(tar_entries_error "${TAR_DIR}/abs.tar.gz")" 'absoluta'

begin "tar con .. -> rechaza"
tar -czf "${TAR_DIR}/dd.tar.gz" --transform='s|^|../|' -C "${TAR_DIR}/ok" a.txt
assert_contains ".." "$(tar_entries_error "${TAR_DIR}/dd.tar.gz")" '..'

begin "tar con symlink -> rechaza"
ln -sf -- a.txt "${TAR_DIR}/ok/enlace"
tar -czf "${TAR_DIR}/link.tar.gz" -C "${TAR_DIR}/ok" a.txt enlace
assert_contains "tipo l" "$(tar_entries_error "${TAR_DIR}/link.tar.gz")" 'tipo [l]'
rm -f -- "${TAR_DIR}/ok/enlace"

begin "tar con hardlink -> rechaza"
cp -- "${TAR_DIR}/ok/a.txt" "${TAR_DIR}/ok/copia.txt"
ln -f -- "${TAR_DIR}/ok/copia.txt" "${TAR_DIR}/ok/duro.txt"
tar -czf "${TAR_DIR}/hard.tar.gz" -C "${TAR_DIR}/ok" a.txt copia.txt duro.txt
assert_contains "tipo h" "$(tar_entries_error "${TAR_DIR}/hard.tar.gz")" 'tipo [h]'

begin "archivo que no es tar -> rechaza"
printf 'no soy un tar\n' > "${TAR_DIR}/basura.tar.gz"
assert_contains "no se pudo leer" "$(tar_entries_error "${TAR_DIR}/basura.tar.gz")" 'no se pudo leer'

printf '\n== dependencias ==\n'

begin "missing_dependencies con PATH vacío lista todo"
EMPTY_PATH="${WORK_DIR}/path-vacio"
mkdir -p "${EMPTY_PATH}"
# En el subshell se quita el stub de curl: acá se simula el entorno real.
MISSING="$( ( unset -f curl; PATH="${EMPTY_PATH}" missing_dependencies ) )"
assert_contains "curl" "${MISSING}" 'curl'
assert_contains "tar" "${MISSING}" 'tar'
assert_contains "flock" "${MISSING}" 'flock'

begin "missing_dependencies en este entorno -> vacío"
assert_eq "sin faltantes" "" "$(missing_dependencies)"

printf '\n== unidades systemd ==\n'

begin "existen service y timer"
assert_exists "service" "${UNIT_SERVICE}"
assert_exists "timer" "${UNIT_TIMER}"
assert_no_crlf "service sin CRLF" "${UNIT_SERVICE}"
assert_no_crlf "timer sin CRLF" "${UNIT_TIMER}"

begin "service: identidad y ejecución"
assert_eq "Type" "oneshot" "$(unit_value "${UNIT_SERVICE}" Type)"
assert_eq "User" "go2rtc" "$(unit_value "${UNIT_SERVICE}" User)"
assert_eq "Group" "go2rtc" "$(unit_value "${UNIT_SERVICE}" Group)"
assert_eq "ExecStart" "/usr/local/sbin/visor-camaras-update" "$(unit_value "${UNIT_SERVICE}" ExecStart)"
assert_eq "TimeoutStartSec" "15min" "$(unit_value "${UNIT_SERVICE}" TimeoutStartSec)"
assert_eq "StateDirectory" "visor-camaras-update" "$(unit_value "${UNIT_SERVICE}" StateDirectory)"
assert_eq "CacheDirectory" "visor-camaras-update" "$(unit_value "${UNIT_SERVICE}" CacheDirectory)"
assert_eq "RuntimeDirectory" "visor-camaras-update" "$(unit_value "${UNIT_SERVICE}" RuntimeDirectory)"

begin "service: endurecimiento P-D20"
assert_eq "NoNewPrivileges" "true" "$(unit_value "${UNIT_SERVICE}" NoNewPrivileges)"
assert_eq "PrivateTmp" "true" "$(unit_value "${UNIT_SERVICE}" PrivateTmp)"
assert_eq "ProtectSystem" "strict" "$(unit_value "${UNIT_SERVICE}" ProtectSystem)"
assert_eq "ReadWritePaths" "/opt/visor-camaras" "$(unit_value "${UNIT_SERVICE}" ReadWritePaths)"
assert_eq "CapabilityBoundingSet vacío" "" "$(unit_value "${UNIT_SERVICE}" CapabilityBoundingSet)"
assert_eq "AmbientCapabilities vacío" "" "$(unit_value "${UNIT_SERVICE}" AmbientCapabilities)"
assert_eq "RestrictAddressFamilies" "AF_INET AF_INET6 AF_UNIX" "$(unit_value "${UNIT_SERVICE}" RestrictAddressFamilies)"
assert_eq "MemoryDenyWriteExecute" "true" "$(unit_value "${UNIT_SERVICE}" MemoryDenyWriteExecute)"
assert_eq "UMask" "0077" "$(unit_value "${UNIT_SERVICE}" UMask)"

begin "service: claves únicas y sin [Install] (lo instala el timer)"
for clave in Type User Group ExecStart TimeoutStartSec StateDirectory CacheDirectory RuntimeDirectory NoNewPrivileges PrivateTmp ProtectSystem ReadWritePaths CapabilityBoundingSet AmbientCapabilities RestrictAddressFamilies MemoryDenyWriteExecute UMask; do
  assert_eq "${clave} única" "1" "$(unit_key_count "${UNIT_SERVICE}" "${clave}")"
done
assert_eq "sin [Install]" "0" "$(unit_key_count "${UNIT_SERVICE}" '\[Install\]')"

begin "timer: cadencia fija de 30 min y activación por timers.target"
assert_eq "OnBootSec" "5min" "$(unit_value "${UNIT_TIMER}" OnBootSec)"
assert_eq "OnUnitActiveSec" "30min" "$(unit_value "${UNIT_TIMER}" OnUnitActiveSec)"
assert_eq "RandomizedDelaySec" "3min" "$(unit_value "${UNIT_TIMER}" RandomizedDelaySec)"
assert_eq "Persistent" "true" "$(unit_value "${UNIT_TIMER}" Persistent)"
assert_eq "WantedBy" "timers.target" "$(unit_value "${UNIT_TIMER}" WantedBy)"
assert_eq "sin OnCalendar" "0" "$(unit_key_count "${UNIT_TIMER}" OnCalendar)"

printf '\n== sandbox: staging válido ==\n'

begin "artefacto nuevo válido -> swap atómico, .prev real, estado success (activado)"
prepare_sandbox "ok"
prepare_published "${NEW_COMMIT}" "nuevo"
CURL_MANIFEST_MODE="ok"
CURL_TARBALL_MODE="ok"
: > "${CURL_ARGS_FILE}"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "$(activate_check_url "${SB_ROOT}")"
assert_eq "exit 0" "0" "${RC}"
RELEASE_DIR="$(find "${SB_ROOT}/opt/visor-camaras/releases" -mindepth 1 -maxdepth 1 -type d -name "*-${NEW_SHA7}" | head -n1)"
assert_regex "nombre <UTC>-<sha7>" '/[0-9]{8}T[0-9]{6}Z-2222222$' "${RELEASE_DIR}"
assert_exists "index.html promovido" "${RELEASE_DIR}/index.html"
assert_exists "MANIFEST.json promovido" "${RELEASE_DIR}/MANIFEST.json"
assert_exists "go2rtc/ promovido" "${RELEASE_DIR}/go2rtc/VERSION.txt"
assert_regex "www apunta al release nuevo" '^releases/[0-9]{8}T[0-9]{6}Z-'"${NEW_SHA7}"'$' "$(www_target "${SB_ROOT}")"
assert_eq "lo servido es el release nuevo" "${NEW_COMMIT}" "$(served_commit_in "${SB_ROOT}")"
assert_eq "2 releases" "2" "$(count_releases_in "${SB_ROOT}")"
assert_eq "www.prev es copia (directorio real, no symlink)" "1" "$(www_prev_is_real_dir "${SB_ROOT}")"
assert_eq "www.prev conserva el contenido anterior" "${SERVED_COMMIT}" "$(prev_commit_in "${SB_ROOT}")"
assert_exists "el release anterior sigue en releases/ (copia, no rename)" "${SERVED_RELEASE}"
assert_eq "estado SERVED_COMMIT" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" SERVED_COMMIT)"
assert_ne "estado SERVED_AT" "" "$(state_get "${SB_ROOT}" SERVED_AT)"
assert_eq "estado ACTIVATED_COMMIT" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" ACTIVATED_COMMIT)"
assert_ne "estado ACTIVATED_AT" "" "$(state_get "${SB_ROOT}" ACTIVATED_AT)"
assert_eq "estado STAGED_COMMIT" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" STAGED_COMMIT)"
assert_eq "estado STAGED_PATH" "${RELEASE_DIR}" "$(state_get "${SB_ROOT}" STAGED_PATH)"
assert_eq "estado LAST_OUTCOME" "success" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_eq "estado LAST_ERROR" "" "$(state_get "${SB_ROOT}" LAST_ERROR)"
assert_eq "sin ACTIVATION_PENDING tras activar" "" "$(state_get "${SB_ROOT}" ACTIVATION_PENDING)"
assert_eq "estado modo 0600" "600" "$(stat -c '%a' -- "${SB_ROOT}/var/lib/visor-camaras-update/state")"
assert_eq "estado sin temporales" "" "$(find "${SB_ROOT}/var/lib/visor-camaras-update" -name '.state.*' -print -quit)"
assert_clean_staging "staging limpio" "${SB_ROOT}"

begin "fetch test-only: file:// y sin forzado HTTPS"
assert_not_contains "sin --proto en tests" "$(cat -- "${CURL_ARGS_FILE}")" '--proto'
assert_contains "usa file://" "$(tr '\n' ' ' < "${CURL_ARGS_FILE}")" 'file://'
assert_args_has "${CURL_ARGS_FILE}" '--connect-timeout'
assert_args_has "${CURL_ARGS_FILE}" '10'
assert_args_has "${CURL_ARGS_FILE}" '--max-time'
assert_args_has "${CURL_ARGS_FILE}" '600'
assert_args_has "${CURL_ARGS_FILE}" '--max-filesize'
assert_args_has "${CURL_ARGS_FILE}" '52428800'

begin "--status después de un run exitoso (confirma la activación)"
run_update --status --root "${SB_ROOT}"
assert_eq "exit 0" "0" "${RC}"
assert_contains "SERVED_COMMIT" "${OUT}" "SERVED_COMMIT=${NEW_COMMIT}"
assert_contains "LAST_OUTCOME" "${OUT}" 'LAST_OUTCOME=success'
assert_contains "ACTIVATED_COMMIT" "${OUT}" "ACTIVATED_COMMIT=${NEW_COMMIT}"
assert_contains "STAGED_COMMIT" "${OUT}" "STAGED_COMMIT=${NEW_COMMIT}"
assert_contains "path servido" "${OUT}" "SERVED_PATH=${RELEASE_DIR}"
assert_contains "sin cuarentena" "${OUT}" 'QUARANTINED_COMMIT=none'

printf '\n== sandbox: idempotencia ==\n'

begin "commit publicado == servido -> skip sin descargar el tarball"
prepare_sandbox "skip"
prepare_published "${SERVED_COMMIT}" "mismo-commit"
: > "${CURL_ARGS_FILE}"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
assert_eq "exit 0" "0" "${RC}"
assert_eq "estado LAST_OUTCOME" "skipped" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_eq "un solo release" "1" "$(count_releases_in "${SB_ROOT}")"
assert_eq "no se descargó el tarball" "0" "$(grep -c 'frontend-dist.tar.gz' "${CURL_ARGS_FILE}" || true)"
assert_eq "www intacto" "releases/20260101T000000Z-${SERVED_SHA7}" "$(www_target "${SB_ROOT}")"
assert_clean_staging "staging limpio" "${SB_ROOT}"

begin "activado en el primer run -> el segundo run no re-descarga ni duplica"
prepare_sandbox "staged"
prepare_published "${NEW_COMMIT}" "nuevo"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "$(activate_check_url "${SB_ROOT}")"
assert_eq "primer run exit 0" "0" "${RC}"
assert_eq "un release nuevo" "2" "$(count_releases_in "${SB_ROOT}")"
assert_regex "www apunta al release nuevo" '^releases/[0-9]{8}T[0-9]{6}Z-'"${NEW_SHA7}"'$' "$(www_target "${SB_ROOT}")"
assert_eq "activado" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" ACTIVATED_COMMIT)"
: > "${CURL_ARGS_FILE}"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "$(activate_check_url "${SB_ROOT}")"
assert_eq "segundo run exit 0" "0" "${RC}"
assert_eq "estado skipped" "skipped" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_eq "sigue habiendo 2 releases" "2" "$(count_releases_in "${SB_ROOT}")"
assert_eq "sin re-descarga del tarball" "0" "$(grep -c 'frontend-dist.tar.gz' "${CURL_ARGS_FILE}" || true)"
assert_eq "STAGED_COMMIT preservado" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" STAGED_COMMIT)"
assert_regex "www intacto" '^releases/[0-9]{8}T[0-9]{6}Z-'"${NEW_SHA7}"'$' "$(www_target "${SB_ROOT}")"

begin "sin MANIFEST.json publicado -> decide con el tarball y activa"
prepare_sandbox "fallback"
prepare_published "${OTHER_COMMIT}" "sin-manifiesto"
CURL_MANIFEST_MODE="fail"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "$(activate_check_url "${SB_ROOT}")"
CURL_MANIFEST_MODE="ok"
assert_eq "exit 0" "0" "${RC}"
assert_eq "estado success" "success" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_eq "release del tarball" "${OTHER_COMMIT}" "$(state_get "${SB_ROOT}" STAGED_COMMIT)"
assert_eq "activado" "${OTHER_COMMIT}" "$(state_get "${SB_ROOT}" ACTIVATED_COMMIT)"
assert_eq "SERVED_COMMIT" "${OTHER_COMMIT}" "$(state_get "${SB_ROOT}" SERVED_COMMIT)"
assert_contains "aviso de manifiesto" "${ERR}" 'MANIFEST.json'

begin "sin manifiesto y tarball == servido -> skip sin promover"
prepare_sandbox "fallback-eq"
prepare_published "${SERVED_COMMIT}" "servido-igual"
CURL_MANIFEST_MODE="fail"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
CURL_MANIFEST_MODE="ok"
assert_eq "exit 0" "0" "${RC}"
assert_eq "estado skipped" "skipped" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_eq "un solo release" "1" "$(count_releases_in "${SB_ROOT}")"
assert_clean_staging "staging limpio" "${SB_ROOT}"

printf '\n== sandbox: verificación post-swap, rollback y cuarentena ==\n'

begin "check post-swap que sirve el commit viejo -> rollback, cuarentena y sitio servido"
prepare_sandbox "check-malo"
prepare_published "${NEW_COMMIT}" "nuevo"
CHECK_STALE="${WORK_DIR}/check-stale"
make_check_fixture "${CHECK_STALE}" "${SERVED_COMMIT}"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "file://${CHECK_STALE}"
assert_eq "exit 1" "1" "${RC}"
assert_eq "estado failed" "failed" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_contains "error diagnóstico del check" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'esperado'
assert_eq "commit fallado en cuarentena" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" QUARANTINED_COMMIT)"
assert_ne "cuarentena con timestamp" "" "$(state_get "${SB_ROOT}" QUARANTINED_AT)"
assert_eq "www volvió a www.prev" "www.prev" "$(www_target "${SB_ROOT}")"
assert_eq "www.prev es copia real" "1" "$(www_prev_is_real_dir "${SB_ROOT}")"
assert_eq "el sitio sigue sirviendo el commit anterior" "${SERVED_COMMIT}" "$(served_commit_in "${SB_ROOT}")"
assert_eq "SERVED_COMMIT no cambió" "${SERVED_COMMIT}" "$(state_get "${SB_ROOT}" SERVED_COMMIT)"
assert_eq "sin ACTIVATION_PENDING" "" "$(state_get "${SB_ROOT}" ACTIVATION_PENDING)"
assert_eq "nada se reportó como activado" "" "$(state_get "${SB_ROOT}" ACTIVATED_COMMIT)"
assert_eq "el release promovido queda, sin podar" "2" "$(count_releases_in "${SB_ROOT}")"
assert_clean_staging "staging limpio" "${SB_ROOT}"

begin "check post-swap inejecutable -> NO se reporta success: rollback y cuarentena"
prepare_sandbox "check-caido"
prepare_published "${NEW_COMMIT}" "nuevo"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "file://${WORK_DIR}/no-existe-check"
assert_eq "exit 1" "1" "${RC}"
assert_eq "estado failed" "failed" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_contains "no se pudo consultar" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'no se pudo consultar'
assert_eq "commit fallado en cuarentena" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" QUARANTINED_COMMIT)"
assert_eq "www volvió a www.prev" "www.prev" "$(www_target "${SB_ROOT}")"
assert_eq "sirve el commit anterior" "${SERVED_COMMIT}" "$(served_commit_in "${SB_ROOT}")"
assert_eq "SERVED_COMMIT no cambió" "${SERVED_COMMIT}" "$(state_get "${SB_ROOT}" SERVED_COMMIT)"

begin "swap que aplica el release equivocado -> la verificación local lo detecta y hace rollback"
prepare_sandbox "swap-equivocado"
prepare_published "${NEW_COMMIT}" "nuevo"
run_update_swap_equivocado --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "$(activate_check_url "${SB_ROOT}")"
assert_eq "exit 1" "1" "${RC}"
assert_eq "estado failed" "failed" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_contains "detectado por el symlink" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'el symlink'
assert_eq "commit fallado en cuarentena" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" QUARANTINED_COMMIT)"
assert_eq "www volvió a www.prev (sitio servido)" "www.prev" "$(www_target "${SB_ROOT}")"
assert_eq "sirve el commit anterior" "${SERVED_COMMIT}" "$(served_commit_in "${SB_ROOT}")"

begin "fallo del swap -> exit 1, www intacto, sin cuarentena (se reintenta)"
prepare_sandbox "swap-falla"
prepare_published "${NEW_COMMIT}" "nuevo"
run_update_swap_falla --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "$(activate_check_url "${SB_ROOT}")"
assert_eq "exit 1" "1" "${RC}"
assert_eq "estado failed" "failed" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_contains "motivo del swap" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'swap atómico'
assert_eq "www intacto" "releases/20260101T000000Z-${SERVED_SHA7}" "$(www_target "${SB_ROOT}")"
assert_eq "sin cuarentena (no hubo rollback)" "" "$(state_get "${SB_ROOT}" QUARANTINED_COMMIT)"
assert_eq "sin pendiente colgado" "" "$(state_get "${SB_ROOT}" ACTIVATION_PENDING)"
assert_eq "sirve el commit anterior" "${SERVED_COMMIT}" "$(served_commit_in "${SB_ROOT}")"

printf '\n== sandbox: cuarentena P-D25 ==\n'

begin "tras el rollback, el siguiente tick no re-aplica el commit en cuarentena"
prepare_sandbox "q-skip"
prepare_published "${NEW_COMMIT}" "nuevo"
CHECK_STALE="${WORK_DIR}/check-stale-q"
make_check_fixture "${CHECK_STALE}" "${SERVED_COMMIT}"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "file://${CHECK_STALE}"
assert_eq "primer run exit 1 (rollback)" "1" "${RC}"
assert_eq "cuarentena registrada" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" QUARANTINED_COMMIT)"
: > "${CURL_ARGS_FILE}"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "$(activate_check_url "${SB_ROOT}")"
assert_eq "segundo run exit 0" "0" "${RC}"
assert_eq "estado quarantined" "quarantined" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_contains "motivo de cuarentena" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'cuarentena'
assert_eq "cuarentena conservada" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" QUARANTINED_COMMIT)"
assert_eq "www sigue en www.prev" "www.prev" "$(www_target "${SB_ROOT}")"
assert_eq "sirve el commit anterior" "${SERVED_COMMIT}" "$(served_commit_in "${SB_ROOT}")"
assert_eq "sin descarga del tarball" "0" "$(grep -c 'frontend-dist.tar.gz' "${CURL_ARGS_FILE}" || true)"
assert_eq "nada activado" "" "$(state_get "${SB_ROOT}" ACTIVATED_COMMIT)"

begin "--force re-aplica el commit en cuarentena y levanta la cuarentena al verificar"
prepare_sandbox "q-force"
prepare_published "${NEW_COMMIT}" "nuevo"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "file://${CHECK_STALE}"
assert_eq "primer run exit 1 (rollback)" "1" "${RC}"
run_update --force --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "$(activate_check_url "${SB_ROOT}")"
assert_eq "run forzado exit 0" "0" "${RC}"
assert_eq "estado success" "success" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_eq "activado" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" ACTIVATED_COMMIT)"
assert_eq "cuarentena levantada" "" "$(state_get "${SB_ROOT}" QUARANTINED_COMMIT)"
assert_regex "www apunta al release nuevo" '^releases/[0-9]{8}T[0-9]{6}Z-'"${NEW_SHA7}"'$' "$(www_target "${SB_ROOT}")"

begin "sin manifiesto, la cuarentena se evalúa tras validar el tarball"
prepare_sandbox "q-fallback"
mkdir -p "${SB_ROOT}/var/lib/visor-camaras-update"
printf 'QUARANTINED_COMMIT=%s\n' "${NEW_COMMIT}" > "${SB_ROOT}/var/lib/visor-camaras-update/state"
prepare_published "${NEW_COMMIT}" "nuevo"
CURL_MANIFEST_MODE="fail"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "$(activate_check_url "${SB_ROOT}")"
CURL_MANIFEST_MODE="ok"
assert_eq "exit 0" "0" "${RC}"
assert_eq "estado quarantined" "quarantined" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_eq "un solo release (no se promovió)" "1" "$(count_releases_in "${SB_ROOT}")"
assert_eq "www intacto" "releases/20260101T000000Z-${SERVED_SHA7}" "$(www_target "${SB_ROOT}")"
assert_clean_staging "staging limpio" "${SB_ROOT}"

begin "--force con actualización disponible -> dry-run no escribe nada"
prepare_sandbox "force-dry"
prepare_published "${NEW_COMMIT}" "nuevo"
run_update --force --dry-run --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
assert_eq "exit 0" "0" "${RC}"
assert_contains "anuncia actualización" "${OUT}" 'dry-run'
assert_missing "sin estado" "${SB_ROOT}/var/lib/visor-camaras-update/state"

printf '\n== sandbox: rollback manual y corte en medio de la activación ==\n'

begin "rollback manual -> www vuelve a www.prev y el commit servido queda en cuarentena"
prepare_sandbox "rollback-manual"
prepare_published "${NEW_COMMIT}" "nuevo"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "$(activate_check_url "${SB_ROOT}")"
assert_eq "activación previa exit 0" "0" "${RC}"
assert_eq "activado" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" ACTIVATED_COMMIT)"
: > "${CURL_ARGS_FILE}"
run_update --rollback --root "${SB_ROOT}"
assert_eq "rollback exit 0" "0" "${RC}"
assert_eq "www volvió a www.prev" "www.prev" "$(www_target "${SB_ROOT}")"
assert_eq "sirve el commit anterior" "${SERVED_COMMIT}" "$(state_get "${SB_ROOT}" SERVED_COMMIT)"
assert_eq "servido en disco" "${SERVED_COMMIT}" "$(served_commit_in "${SB_ROOT}")"
assert_eq "commit revertido en cuarentena" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" QUARANTINED_COMMIT)"
assert_eq "estado quarantined" "quarantined" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_contains "motivo" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'rollback manual'
assert_eq "sin red en el rollback manual" "" "$(cat -- "${CURL_ARGS_FILE}")"

begin "tras un rollback manual, el tick siguiente no re-aplica (sin --force)"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "$(activate_check_url "${SB_ROOT}")"
assert_eq "exit 0" "0" "${RC}"
assert_eq "estado quarantined" "quarantined" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_eq "www sigue en www.prev" "www.prev" "$(www_target "${SB_ROOT}")"

begin "rollback manual sin www.prev -> exit 1, sin tocar nada"
prepare_sandbox "rollback-sin-prev"
run_update --rollback --root "${SB_ROOT}"
assert_eq "exit 1" "1" "${RC}"
assert_contains "no hay a qué volver" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'no existe'
assert_eq "www intacto" "releases/20260101T000000Z-${SERVED_SHA7}" "$(www_target "${SB_ROOT}")"
assert_eq "un solo release" "1" "$(count_releases_in "${SB_ROOT}")"

begin "corte tras el swap: se reanuda, verifica y finaliza la activación"
prepare_sandbox "resume-ok"
crash_activation_state "${SB_ROOT}" "${NEW_COMMIT}" 1
: > "${CURL_ARGS_FILE}"
run_update --root "${SB_ROOT}" --check-url "$(activate_check_url "${SB_ROOT}")"
assert_eq "exit 0" "0" "${RC}"
assert_eq "estado success" "success" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_eq "activación completada" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" ACTIVATED_COMMIT)"
assert_eq "sin pendiente" "" "$(state_get "${SB_ROOT}" ACTIVATION_PENDING)"
assert_eq "www sigue en el release nuevo" "releases/20260201T000000Z-${NEW_SHA7}" "$(www_target "${SB_ROOT}")"
assert_eq "sin descarga del tarball" "0" "$(grep -c 'frontend-dist.tar.gz' "${CURL_ARGS_FILE}" || true)"
assert_eq "sin fetch del canal publicado" "0" "$(grep -c 'codeload.github.com' "${CURL_ARGS_FILE}" || true)"
assert_eq "el check sí corrió" "1" "$(grep -cxF "file://${SB_ROOT}/opt/visor-camaras/www/MANIFEST.json" "${CURL_ARGS_FILE}" || true)"
assert_eq "sin cuarentena" "" "$(state_get "${SB_ROOT}" QUARANTINED_COMMIT)"

begin "corte tras el swap y verificación fallida: rollback y cuarentena"
prepare_sandbox "resume-fail"
crash_activation_state "${SB_ROOT}" "${NEW_COMMIT}" 1
CHECK_STALE="${WORK_DIR}/check-stale-resume"
make_check_fixture "${CHECK_STALE}" "${SERVED_COMMIT}"
run_update --root "${SB_ROOT}" --check-url "file://${CHECK_STALE}"
assert_eq "exit 1" "1" "${RC}"
assert_eq "estado failed" "failed" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_contains "motivo" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'activación pendiente no verificó'
assert_eq "www volvió a www.prev" "www.prev" "$(www_target "${SB_ROOT}")"
assert_eq "commit en cuarentena" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" QUARANTINED_COMMIT)"
assert_eq "sin pendiente" "" "$(state_get "${SB_ROOT}" ACTIVATION_PENDING)"

begin "--dry-run con activación pendiente: no toca www ni el estado"
prepare_sandbox "resume-dry"
crash_activation_state "${SB_ROOT}" "${NEW_COMMIT}" 1
run_update --dry-run --root "${SB_ROOT}" --check-url "$(activate_check_url "${SB_ROOT}")"
assert_eq "exit 0" "0" "${RC}"
assert_contains "avisa del pendiente" "${ERR}" 'pendiente'
assert_eq "www no se tocó" "releases/20260201T000000Z-${NEW_SHA7}" "$(www_target "${SB_ROOT}")"
assert_eq "ACTIVATION_PENDING intacto" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" ACTIVATION_PENDING)"
assert_eq "sin ACTIVATED_COMMIT" "" "$(state_get "${SB_ROOT}" ACTIVATED_COMMIT)"

begin "corte antes del swap: se limpia el pendiente y se activa normalmente"
prepare_sandbox "resume-pre"
crash_activation_state "${SB_ROOT}" "${NEW_COMMIT}" 0
assert_eq "www quedó viejo" "releases/20260101T000000Z-${SERVED_SHA7}" "$(www_target "${SB_ROOT}")"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "$(activate_check_url "${SB_ROOT}")"
assert_eq "exit 0" "0" "${RC}"
assert_eq "estado success" "success" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_eq "activación completada" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" ACTIVATED_COMMIT)"
assert_eq "sin pendiente" "" "$(state_get "${SB_ROOT}" ACTIVATION_PENDING)"
assert_eq "www apunta al release nuevo" "releases/20260201T000000Z-${NEW_SHA7}" "$(www_target "${SB_ROOT}")"

begin "check-url por defecto: el target es el go2rtc local (127.0.0.1:1984)"
prepare_sandbox "check-default"
prepare_published "${NEW_COMMIT}" "nuevo"
: > "${CURL_ARGS_FILE}"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
assert_eq "exit 0 (stub de curl responde el check)" "0" "${RC}"
assert_eq "root por defecto" "1" "$(grep -cxF 'http://127.0.0.1:1984/' "${CURL_ARGS_FILE}" || true)"
assert_eq "manifest por defecto" "1" "$(grep -cxF 'http://127.0.0.1:1984/MANIFEST.json' "${CURL_ARGS_FILE}" || true)"

printf '\n== sandbox: validación rechaza ==\n'

begin "index.html ausente -> exit 2, nada servido cambiado"
prepare_sandbox "sin-index"
prepare_published "${NEW_COMMIT}" "nuevo"
rm -f -- "${PUB_DIR}/DVRStream-frontend-dist/index.html"
rebuild_tarball
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
assert_eq "exit 2" "2" "${RC}"
assert_eq "estado failed" "failed" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_contains "error diagnóstico" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'index.html'
assert_eq "un solo release" "1" "$(count_releases_in "${SB_ROOT}")"
assert_eq "www intacto" "releases/20260101T000000Z-${SERVED_SHA7}" "$(www_target "${SB_ROOT}")"
assert_clean_staging "staging limpio" "${SB_ROOT}"

begin "index.html vacío -> exit 2"
prepare_sandbox "index-vacio"
prepare_published "${NEW_COMMIT}" "nuevo"
: > "${PUB_DIR}/DVRStream-frontend-dist/index.html"
rebuild_tarball
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "error diagnóstico" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'vacío'
assert_eq "un solo release" "1" "$(count_releases_in "${SB_ROOT}")"

begin "index.html sin <app-root> -> exit 2"
prepare_sandbox "sin-approot"
prepare_published "${NEW_COMMIT}" "nuevo"
printf '<html><body><div>otra app</div></body></html>\n' > "${PUB_DIR}/DVRStream-frontend-dist/index.html"
rebuild_tarball
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "error diagnóstico" "$(state_get "${SB_ROOT}" LAST_ERROR)" '<app-root>'

begin "src= apunta a un archivo que no está -> exit 2"
prepare_sandbox "src-roto"
prepare_published "${NEW_COMMIT}" "nuevo"
rm -f -- "${PUB_DIR}/DVRStream-frontend-dist/main-nuevo.js"
rebuild_tarball
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "error diagnóstico" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'src='

begin "tree_sha256 no coincide (tamper post-manifiesto) -> exit 2"
prepare_sandbox "hash"
prepare_published "${NEW_COMMIT}" "nuevo"
printf 'console.log("inyectado");\n' >> "${PUB_DIR}/DVRStream-frontend-dist/main-nuevo.js"
rebuild_tarball
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "motivo del helper" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'no coincide'
assert_eq "un solo release" "1" "$(count_releases_in "${SB_ROOT}")"
assert_clean_staging "staging limpio" "${SB_ROOT}"

begin "manifiesto publicado != manifiesto del tarball -> exit 2"
prepare_sandbox "mismatch"
prepare_published "${NEW_COMMIT}" "nuevo"
sed -i "s/${NEW_COMMIT}/${OTHER_COMMIT}/" "${PUB_DIR}/DVRStream-frontend-dist/MANIFEST.json"
rebuild_tarball
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "motivo" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'no coincide'

begin "tar con entrada absoluta -> exit 2 sin nada promovido"
prepare_sandbox "tar-abs"
prepare_published "${NEW_COMMIT}" "nuevo"
hostile_tarball absolute
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "motivo" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'absoluta'
assert_eq "un solo release" "1" "$(count_releases_in "${SB_ROOT}")"
assert_clean_staging "staging limpio" "${SB_ROOT}"

begin "tar con .. -> exit 2"
prepare_sandbox "tar-dd"
prepare_published "${NEW_COMMIT}" "nuevo"
hostile_tarball dotdot
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "motivo" "$(state_get "${SB_ROOT}" LAST_ERROR)" '..'

begin "tar con symlink -> exit 2"
prepare_sandbox "tar-link"
prepare_published "${NEW_COMMIT}" "nuevo"
hostile_tarball symlink
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "motivo" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'tipo [l]'

begin "tar con hardlink -> exit 2"
prepare_sandbox "tar-hard"
prepare_published "${NEW_COMMIT}" "nuevo"
hostile_tarball hardlink
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "motivo" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'tipo [h]'

printf '\n== sandbox: fallas de fetch ==\n'

begin "fetch parcial -> exit 1, servido intacto, estado failed"
prepare_sandbox "parcial"
prepare_published "${NEW_COMMIT}" "nuevo"
CURL_TARBALL_MODE="partial"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
CURL_TARBALL_MODE="ok"
assert_eq "exit 1" "1" "${RC}"
assert_eq "estado failed" "failed" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_contains "error diagnóstico" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'no se pudo descargar'
assert_eq "un solo release" "1" "$(count_releases_in "${SB_ROOT}")"
assert_eq "www intacto" "releases/20260101T000000Z-${SERVED_SHA7}" "$(www_target "${SB_ROOT}")"
assert_clean_staging "staging limpio" "${SB_ROOT}"

begin "descarga vacía -> exit 1"
prepare_sandbox "vacia"
prepare_published "${NEW_COMMIT}" "nuevo"
CURL_TARBALL_MODE="empty"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
CURL_TARBALL_MODE="ok"
assert_eq "exit 1" "1" "${RC}"
assert_contains "error diagnóstico" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'vacía'

begin "tarball más grande que el tope -> exit 2"
prepare_sandbox "grande"
prepare_published "${NEW_COMMIT}" "nuevo"
CURL_TARBALL_MODE="oversize"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
CURL_TARBALL_MODE="ok"
assert_eq "exit 2" "2" "${RC}"
assert_contains "error diagnóstico" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'demasiado grande'
assert_eq "un solo release" "1" "$(count_releases_in "${SB_ROOT}")"

begin "modo producción: HTTPS forzado, timeouts, retry y tope"
prepare_sandbox "https"
prepare_published "${NEW_COMMIT}" "https"
CURL_TARBALL_MODE="fail"
: > "${CURL_ARGS_FILE}"
run_update --root "${SB_ROOT}"
CURL_TARBALL_MODE="ok"
assert_eq "exit 1 (tarball no baja)" "1" "${RC}"
assert_args_has "${CURL_ARGS_FILE}" '--proto'
assert_args_has "${CURL_ARGS_FILE}" '=https'
assert_args_has "${CURL_ARGS_FILE}" '--tlsv1.2'
assert_args_has "${CURL_ARGS_FILE}" '--connect-timeout'
assert_args_has "${CURL_ARGS_FILE}" '10'
assert_args_has "${CURL_ARGS_FILE}" '--max-time'
assert_args_has "${CURL_ARGS_FILE}" '600'
assert_args_has "${CURL_ARGS_FILE}" '15'
assert_args_has "${CURL_ARGS_FILE}" '--retry'
assert_args_has "${CURL_ARGS_FILE}" '3'
assert_args_has "${CURL_ARGS_FILE}" '--max-filesize'
assert_args_has "${CURL_ARGS_FILE}" '52428800'
assert_not_contains "sin aviso test-only" "${ERR}" '--source-url'
assert_contains "error de descarga" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'no se pudo descargar'
assert_eq "www intacto" "releases/20260101T000000Z-${SERVED_SHA7}" "$(www_target "${SB_ROOT}")"

begin "layout inválido: www no es symlink -> exit 2"
prepare_sandbox "layout"
rm -f -- "${SB_ROOT}/opt/visor-camaras/www"
mkdir -p "${SB_ROOT}/opt/visor-camaras/www"
printf '<html></html>\n' > "${SB_ROOT}/opt/visor-camaras/www/index.html"
prepare_published "${NEW_COMMIT}" "nuevo"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "motivo" "$(state_get "${SB_ROOT}" LAST_ERROR)" 'symlink'
assert_eq "estado failed" "failed" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"

begin "flock ocupado -> exit 0 sin descargar ni escribir releases"
prepare_sandbox "flock"
prepare_published "${NEW_COMMIT}" "nuevo"
mkdir -p "${SB_ROOT}/run/visor-camaras-update"
exec 8>"${SB_ROOT}/run/visor-camaras-update/lock"
if ! flock -n 8; then fail "no se pudo tomar el lock de prueba"; fi
: > "${CURL_ARGS_FILE}"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
exec 8>&-
assert_eq "exit 0" "0" "${RC}"
assert_contains "mensaje busy" "${OUT}" 'en curso'
assert_eq "sin descargas" "" "$(cat -- "${CURL_ARGS_FILE}")"
assert_eq "un solo release" "1" "$(count_releases_in "${SB_ROOT}")"
assert_missing "sin estado escrito" "${SB_ROOT}/var/lib/visor-camaras-update/state"

printf '\n== sandbox: --dry-run y poda ==\n'

begin "--dry-run con actualización: no escribe nada"
prepare_sandbox "dry-run"
prepare_published "${NEW_COMMIT}" "nuevo"
: > "${CURL_ARGS_FILE}"
run_update --dry-run --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
assert_eq "exit 0" "0" "${RC}"
assert_contains "anuncia actualización" "${OUT}" 'dry-run'
assert_contains "sha7 nuevo" "${OUT}" "${NEW_SHA7}"
assert_eq "un solo release" "1" "$(count_releases_in "${SB_ROOT}")"
assert_missing "sin estado" "${SB_ROOT}/var/lib/visor-camaras-update/state"
assert_missing "sin staging" "${SB_ROOT}/opt/visor-camaras/.staging"
assert_eq "sin descarga de tarball" "0" "$(grep -c 'frontend-dist.tar.gz' "${CURL_ARGS_FILE}" || true)"

begin "--dry-run sin cambios -> exit 0 y sin escrituras"
prepare_sandbox "dry-run-skip"
prepare_published "${SERVED_COMMIT}" "mismo-commit"
run_update --dry-run --root "${SB_ROOT}" --source-url "file://${PUB_DIR}"
assert_eq "exit 0" "0" "${RC}"
assert_contains "sin cambios" "${OUT}" 'sin cambios'
assert_missing "sin estado" "${SB_ROOT}/var/lib/visor-camaras-update/state"

begin "poda: se conservan 5 releases + el servido, sin romper .prev"
prepare_sandbox "prune"
i=1
while (( i <= 7 )); do
  commit="$(fake_commit "release-$i")"
  rel="${SB_ROOT}/opt/visor-camaras/releases/2026020${i}T000000Z-$(printf '%s' "${commit}" | cut -c1-7)"
  make_artifact "${rel}" "viejo${i}"
  write_manifest_for "${rel}" "${commit}"
  i=$((i + 1))
done
assert_eq "8 releases antes de podar" "8" "$(count_releases_in "${SB_ROOT}")"
prepare_published "${NEW_COMMIT}" "nuevo"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "$(activate_check_url "${SB_ROOT}")"
assert_eq "exit 0" "0" "${RC}"
assert_eq "5 releases después de podar" "5" "$(count_releases_in "${SB_ROOT}")"
assert_missing "release viejo 1 podado" "${SB_ROOT}/opt/visor-camaras/releases/20260201T000000Z-$(printf '%s' "$(fake_commit 'release-1')" | cut -c1-7)"
assert_missing "el release que ya no se sirve se poda" "${SERVED_RELEASE}"
assert_regex "www apunta al release nuevo y sobrevive" '^releases/[0-9]{8}T[0-9]{6}Z-'"${NEW_SHA7}"'$' "$(www_target "${SB_ROOT}")"
assert_eq "www.prev conserva el contenido anterior" "${SERVED_COMMIT}" "$(prev_commit_in "${SB_ROOT}")"
assert_eq "estado success tras podar" "success" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"

begin "poda: el release servido se protege aunque sea el más viejo"
prepare_sandbox "prune-guard"
# Release staged (ya validado) con nombre anterior a los 7 históricos: al
# activarlo, la poda debe verlo como servido y no borrarlo.
staged_commit="$(fake_commit 'staged-guard')"
staged_sha7="$(printf '%s' "${staged_commit}" | cut -c1-7)"
staged_rel="${SB_ROOT}/opt/visor-camaras/releases/20260201T000000Z-${staged_sha7}"
make_artifact "${staged_rel}" "staged-guard"
write_manifest_for "${staged_rel}" "${staged_commit}"
i=1
while (( i <= 7 )); do
  rel="${SB_ROOT}/opt/visor-camaras/releases/2026030${i}T000000Z-$(printf '%s' "$(fake_commit "post-$i")" | cut -c1-7)"
  make_artifact "${rel}" "post${i}"
  write_manifest_for "${rel}" "$(fake_commit "post-$i")"
  i=$((i + 1))
done
prepare_published "${staged_commit}" "staged-guard"
assert_eq "9 releases antes de podar" "9" "$(count_releases_in "${SB_ROOT}")"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "$(activate_check_url "${SB_ROOT}")"
assert_eq "exit 0" "0" "${RC}"
assert_exists "release activado (el más viejo por nombre) sobrevive" "${staged_rel}"
assert_regex "www apunta al release activado" "^releases/20260201T000000Z-${staged_sha7}$" "$(www_target "${SB_ROOT}")"
assert_exists "www.prev sigue en su lugar" "${SB_ROOT}/opt/visor-camaras/www.prev"
assert_eq "estado success" "success" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"

begin "cuarentena de otro commit no bloquea (clave desconocida preservada)"
prepare_sandbox "estado-merge"
mkdir -p "${SB_ROOT}/var/lib/visor-camaras-update"
printf 'QUARANTINED_COMMIT=%s\n' "${OTHER_COMMIT}" > "${SB_ROOT}/var/lib/visor-camaras-update/state"
prepare_published "${NEW_COMMIT}" "nuevo"
run_update --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "$(activate_check_url "${SB_ROOT}")"
assert_eq "exit 0" "0" "${RC}"
assert_eq "cuarentena de otro commit preservada" "${OTHER_COMMIT}" "$(state_get "${SB_ROOT}" QUARANTINED_COMMIT)"
assert_eq "LAST_OUTCOME actualizado" "success" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_eq "activado" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" ACTIVATED_COMMIT)"

printf '\n== sandbox: proceso real con curl file:// ==\n'

begin "end-to-end sin stubs: fetch real file://, activación verificada y segundo run idempotente"
prepare_sandbox "e2e"
prepare_published "${NEW_COMMIT}" "e2e"
run_capture bash "${UPDATER}" --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "$(activate_check_url "${SB_ROOT}")"
assert_eq "exit 0" "0" "${RC}"
RELEASE_E2E="$(find "${SB_ROOT}/opt/visor-camaras/releases" -mindepth 1 -maxdepth 1 -type d -name "*-${NEW_SHA7}" | head -n1)"
assert_exists "release promovido" "${RELEASE_E2E}/MANIFEST.json"
assert_regex "www apunta al release nuevo" '^releases/[0-9]{8}T[0-9]{6}Z-'"${NEW_SHA7}"'$' "$(www_target "${SB_ROOT}")"
assert_eq "www.prev con el contenido anterior" "${SERVED_COMMIT}" "$(prev_commit_in "${SB_ROOT}")"
assert_eq "estado success" "success" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_eq "ACTIVATED_COMMIT" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" ACTIVATED_COMMIT)"
assert_eq "STAGED_COMMIT" "${NEW_COMMIT}" "$(state_get "${SB_ROOT}" STAGED_COMMIT)"
assert_contains "aviso del hook de tests" "${ERR}" '--source-url'
assert_clean_staging "staging limpio" "${SB_ROOT}"

run_capture bash "${UPDATER}" --root "${SB_ROOT}" --source-url "file://${PUB_DIR}" --check-url "$(activate_check_url "${SB_ROOT}")"
assert_eq "segundo run exit 0" "0" "${RC}"
assert_eq "estado skipped" "skipped" "$(state_get "${SB_ROOT}" LAST_OUTCOME)"
assert_eq "sin releases duplicados" "2" "$(count_releases_in "${SB_ROOT}")"

run_capture bash "${UPDATER}" --status --root "${SB_ROOT}"
assert_eq "--status exit 0" "0" "${RC}"
assert_contains "--status SERVED_COMMIT" "${OUT}" "SERVED_COMMIT=${NEW_COMMIT}"
assert_contains "--status LAST_OUTCOME" "${OUT}" 'LAST_OUTCOME=skipped'
assert_contains "--status ACTIVATED_COMMIT" "${OUT}" "ACTIVATED_COMMIT=${NEW_COMMIT}"
assert_contains "--status STAGED_COMMIT" "${OUT}" "STAGED_COMMIT=${NEW_COMMIT}"

printf '\n\033[1;32mOK\033[0m: %d assertions pasaron.\n' "${CASES}"
