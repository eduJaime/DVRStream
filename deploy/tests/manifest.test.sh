#!/usr/bin/env bash
#
# manifest.test.sh -- Tests sin dependencias de deploy/manifest.sh.
#
# Uso:
#   bash deploy/tests/manifest.test.sh
#
# Sólo usa bash + coreutils (mktemp, mkdir, printf, find, sort, sha256sum).
# No requiere root ni red. Corta en el primer fallo (exit 1) para mantener la
# salida legible.
#
# Cubre:
#   - uso del CLI (subcomandos y validación de argumentos)
#   - validación de campos del manifiesto (bloquea inyección de JSON)
#   - hash canónico: determinismo, exclusión de MANIFEST.json, orden por bytes,
#     subdirectorios, nombres con espacios/UTF-8 y directorio vacío
#   - write: forma exacta del JSON, stdout = tree_sha256, sobrescritura
#   - check: coincide, archivo tamperado, manifiesto ausente o incompleto

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${TEST_DIR}/../manifest.sh"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manifest.test.XXXXXX")"
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

assert_ne() { # <label> <valor1> <valor2>
  [[ "$2" != "$3" ]] || fail "$1: ambos valores son [$2]"
  ok
}

assert_contains() { # <label> <texto> <substring>
  [[ "$2" == *"$3"* ]] || fail "$1: se esperaba encontrar [$3] en [$2]"
  ok
}

assert_is_hex64() { # <label> <valor>
  [[ "$2" =~ ^[0-9a-f]{64}$ ]] || fail "$1: no es un sha256 hexadecimal de 64: [$2]"
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

fixture_dir() { # <nombre> -> crea e imprime el path del fixture
  local dir="${WORK_DIR}/$1"
  mkdir -p -- "${dir}"
  printf '%s' "${dir}"
}

put_text() { # <path> <contenido>
  mkdir -p -- "$(dirname -- "$1")"
  printf '%s\n' "$2" > "$1"
}

# make_artifact <dir>: artefacto mínimo realista, con la misma forma que el
# dist publicado (raíz + subdirectorio assets/).
make_artifact() {
  put_text "$1/index.html" \
    '<!doctype html><html><body><app-root></app-root><script src="main-abc.js"></script></body></html>'
  put_text "$1/main-abc.js" 'console.log("visor-camaras");'
  put_text "$1/assets/styles.css" 'app-root{display:block}'
}

# Hash canónico de make_artifact. Constante calculada con una implementación
# independiente (python3 hashlib) y contrastada contra el pipeline del diseño.
# Fija el formato para que un cambio de separador, de prefijo ./ o de criterio
# de orden rompa este test (y no la verificación de integridad en producción).
GOLDEN="ffe7f71c12f5935c89f948f8d8c45954c734f603976a11c73d5355e2721bfee1"
EMPTY_SHA="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

COMMIT_OK="0123456789abcdef0123456789abcdef01234567"
RUN_OK="1234567890"
NODE_OK="v22.22.2"
BUILT_OK="2026-09-25T12:00:00Z"

if [[ ! -f "${MANIFEST}" ]]; then
  printf 'FAIL: no existe %s\n' "${MANIFEST}" >&2
  exit 1
fi

printf '\n== uso del CLI ==\n'

begin "sin argumentos -> exit 2 y uso"
run_capture bash "${MANIFEST}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "mensaje de uso" "${ERR}" 'Uso'

begin "subcomando desconocido -> exit 2"
run_capture bash "${MANIFEST}" volar "${WORK_DIR}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "mensaje de uso" "${ERR}" 'Uso'

begin "hash sin directorio -> exit 2"
run_capture bash "${MANIFEST}" hash
assert_eq "exit 2" "2" "${RC}"
assert_contains "mensaje de uso" "${ERR}" 'Uso'

begin "hash con directorio inexistente -> exit 2"
run_capture bash "${MANIFEST}" hash "${WORK_DIR}/no-existe"
assert_eq "exit 2" "2" "${RC}"
assert_contains "motivo" "${ERR}" 'No existe'

begin "hash con un archivo en vez de un directorio -> exit 2"
put_text "${WORK_DIR}/archivo.txt" 'x'
run_capture bash "${MANIFEST}" hash "${WORK_DIR}/archivo.txt"
assert_eq "exit 2" "2" "${RC}"
assert_contains "motivo" "${ERR}" 'No es un directorio'

begin "argumentos de más -> exit 2"
run_capture bash "${MANIFEST}" hash "${WORK_DIR}" extra
assert_eq "exit 2" "2" "${RC}"
assert_contains "mensaje de uso" "${ERR}" 'Uso'

printf '\n== hash canónico ==\n'

begin "artefacto fijo -> digest conocido (golden)"
golden="$(fixture_dir golden)"
make_artifact "${golden}"
run_capture bash "${MANIFEST}" hash "${golden}"
assert_eq "exit 0" "0" "${RC}"
assert_eq "digest golden" "${GOLDEN}" "${OUT}"

begin "mismo árbol hasheado dos veces -> idéntico"
assert_eq "determinista" "${OUT}" "$(bash "${MANIFEST}" hash "${golden}")"

begin "otro orden de creación -> mismo digest"
reorder="$(fixture_dir reorder)"
put_text "${reorder}/assets/styles.css" 'app-root{display:block}'
put_text "${reorder}/main-abc.js" 'console.log("visor-camaras");'
put_text "${reorder}/index.html" \
  '<!doctype html><html><body><app-root></app-root><script src="main-abc.js"></script></body></html>'
assert_eq "orden irrelevante" "${GOLDEN}" "$(bash "${MANIFEST}" hash "${reorder}")"

begin "cambiar un byte cambia el digest"
tampered="$(fixture_dir tampered)"
make_artifact "${tampered}"
put_text "${tampered}/main-abc.js" 'console.log("visor-camaras!");'
assert_ne "contenido sensible" "${GOLDEN}" "$(bash "${MANIFEST}" hash "${tampered}")"

begin "renombrar un archivo cambia el digest (la ruta se hashea)"
moved="$(fixture_dir moved)"
make_artifact "${moved}"
mv "${moved}/main-abc.js" "${moved}/main-def.js"
assert_ne "ruta sensible" "${GOLDEN}" "$(bash "${MANIFEST}" hash "${moved}")"

begin "subdirectorios incluidos"
flat="$(fixture_dir flat)"
put_text "${flat}/index.html" \
  '<!doctype html><html><body><app-root></app-root><script src="main-abc.js"></script></body></html>'
put_text "${flat}/main-abc.js" 'console.log("visor-camaras");'
assert_ne "assets/ cuenta" "${GOLDEN}" "$(bash "${MANIFEST}" hash "${flat}")"

begin "directorios vacíos no cambian el digest"
mkdir -p "${golden}/vacio"
assert_eq "dir vacío neutro" "${GOLDEN}" "$(bash "${MANIFEST}" hash "${golden}")"
rmdir "${golden}/vacio"

begin "MANIFEST.json excluido del hash"
put_text "${golden}/MANIFEST.json" '{"cualquier":"cosa"}'
assert_eq "excluido" "${GOLDEN}" "$(bash "${MANIFEST}" hash "${golden}")"

begin "MANIFEST.json anidado también se excluye"
put_text "${golden}/assets/MANIFEST.json" '{"x":"y"}'
assert_eq "excluido en subdirectorio" "${GOLDEN}" "$(bash "${MANIFEST}" hash "${golden}")"

begin "nombres con espacios"
spaces="$(fixture_dir spaces)"
make_artifact "${spaces}"
put_text "${spaces}/archivo con espacios.js" 'x'
first_space="$(bash "${MANIFEST}" hash "${spaces}")"
assert_ne "el nombre cuenta" "${GOLDEN}" "${first_space}"
assert_eq "estable" "${first_space}" "$(bash "${MANIFEST}" hash "${spaces}")"

begin "nombres UTF-8"
utf8="$(fixture_dir utf8)"
make_artifact "${utf8}"
put_text "${utf8}/ñandú.js" 'x'
first_utf8="$(bash "${MANIFEST}" hash "${utf8}")"
assert_is_hex64 "digest válido" "${first_utf8}"
assert_eq "estable" "${first_utf8}" "$(bash "${MANIFEST}" hash "${utf8}")"

begin "directorio vacío -> sha256 del stream vacío (constante)"
vacio="$(fixture_dir vacio)"
run_capture bash "${MANIFEST}" hash "${vacio}"
assert_eq "exit 0" "0" "${RC}"
assert_eq "constante del vacío" "${EMPTY_SHA}" "${OUT}"

printf '\n== write: MANIFEST.json ==\n'

begin "write escribe el manifiesto con forma exacta y devuelve el hash"
wdir="$(fixture_dir write)"
make_artifact "${wdir}"
before="$(bash "${MANIFEST}" hash "${wdir}")"
run_capture bash "${MANIFEST}" write "${wdir}" "${COMMIT_OK}" "${RUN_OK}" "${NODE_OK}" "${BUILT_OK}"
assert_eq "exit 0" "0" "${RC}"
assert_eq "stdout = tree_sha256" "${before}" "${OUT}"
expected="{\"commit\":\"${COMMIT_OK}\",\"run_id\":\"${RUN_OK}\",\"node\":\"${NODE_OK}\",\"built_at\":\"${BUILT_OK}\",\"tree_sha256\":\"${before}\"}"
assert_eq "JSON exacto" "${expected}" "$(cat "${wdir}/MANIFEST.json")"
assert_eq "una sola línea" "1" "$(wc -l < "${wdir}/MANIFEST.json")"
assert_eq "hash sin cambios tras escribir" "${before}" "$(bash "${MANIFEST}" hash "${wdir}")"

begin "write sobrescribe un MANIFEST.json previo"
put_text "${wdir}/MANIFEST.json" '{"basura":true}'
run_capture bash "${MANIFEST}" write "${wdir}" "${COMMIT_OK}" "${RUN_OK}" "${NODE_OK}" "${BUILT_OK}"
assert_eq "exit 0" "0" "${RC}"
assert_eq "JSON exacto tras sobrescribir" "${expected}" "$(cat "${wdir}/MANIFEST.json")"

begin "write con el directorio inexistente -> exit 2"
run_capture bash "${MANIFEST}" write "${WORK_DIR}/no-existe" \
  "${COMMIT_OK}" "${RUN_OK}" "${NODE_OK}" "${BUILT_OK}"
assert_eq "exit 2" "2" "${RC}"

begin "write con argumentos faltantes -> exit 2"
run_capture bash "${MANIFEST}" write "${wdir}" "${COMMIT_OK}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "uso" "${ERR}" 'Uso'

printf '\n== validación de campos (anti-inyección de JSON) ==\n'

begin "commit no hexadecimal -> exit 2"
run_capture bash "${MANIFEST}" write "${wdir}" 'no-es-sha' "${RUN_OK}" "${NODE_OK}" "${BUILT_OK}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "motivo" "${ERR}" 'commit'

begin "commit demasiado corto -> exit 2"
run_capture bash "${MANIFEST}" write "${wdir}" 'abc123' "${RUN_OK}" "${NODE_OK}" "${BUILT_OK}"
assert_eq "exit 2" "2" "${RC}"

begin "commit con comilla (intento de inyección) -> exit 2"
run_capture bash "${MANIFEST}" write "${wdir}" \
  '0123456789abcdef0123456789abcdef0123456789"' "${RUN_OK}" "${NODE_OK}" "${BUILT_OK}"
assert_eq "exit 2" "2" "${RC}"

begin "run_id no numérico -> exit 2"
run_capture bash "${MANIFEST}" write "${wdir}" "${COMMIT_OK}" 'run-1' "${NODE_OK}" "${BUILT_OK}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "motivo" "${ERR}" 'run_id'

begin "node con espacio -> exit 2"
run_capture bash "${MANIFEST}" write "${wdir}" "${COMMIT_OK}" "${RUN_OK}" 'v 22.22.2' "${BUILT_OK}"
assert_eq "exit 2" "2" "${RC}"

begin "built_at que no es ISO-8601 UTC -> exit 2"
run_capture bash "${MANIFEST}" write "${wdir}" "${COMMIT_OK}" "${RUN_OK}" "${NODE_OK}" 'ayer'
assert_eq "exit 2" "2" "${RC}"

begin "un write rechazado no toca el manifiesto existente"
assert_eq "manifiesto intacto" "${expected}" "$(cat "${wdir}/MANIFEST.json")"

printf '\n== check: integridad del artefacto ==\n'

begin "check sobre un artefacto válido -> exit 0 y hash"
run_capture bash "${MANIFEST}" check "${wdir}"
assert_eq "exit 0" "0" "${RC}"
assert_eq "hash impreso" "$(bash "${MANIFEST}" hash "${wdir}")" "${OUT}"

begin "check ignora built_at (el manifiesto no se hashea a sí mismo)"
sed -i 's/"built_at":"[^"]*"/"built_at":"1999-01-01T00:00:00Z"/' "${wdir}/MANIFEST.json"
run_capture bash "${MANIFEST}" check "${wdir}"
assert_eq "exit 0" "0" "${RC}"

begin "archivo tamperado -> exit 1 y motivo"
put_text "${wdir}/index.html" \
  '<!doctype html><html><body><app-root></app-root><script src="main-evil.js"></script></body></html>'
run_capture bash "${MANIFEST}" check "${wdir}"
assert_eq "exit 1" "1" "${RC}"
assert_contains "explica el desajuste" "${ERR}" 'no coincide'

begin "tree_sha256 cambiado en el manifiesto -> exit 1"
make_artifact "${wdir}"
run_capture bash "${MANIFEST}" write "${wdir}" "${COMMIT_OK}" "${RUN_OK}" "${NODE_OK}" "${BUILT_OK}"
assert_eq "exit 0 al re-escribir" "0" "${RC}"
sed -i 's/"tree_sha256":"[0-9a-f]/"tree_sha256":"0/' "${wdir}/MANIFEST.json"
run_capture bash "${MANIFEST}" check "${wdir}"
assert_eq "exit 1" "1" "${RC}"

begin "sin MANIFEST.json -> exit 1"
nomanifest="$(fixture_dir nomanifest)"
make_artifact "${nomanifest}"
run_capture bash "${MANIFEST}" check "${nomanifest}"
assert_eq "exit 1" "1" "${RC}"
assert_contains "motivo" "${ERR}" 'falta'

begin "manifiesto sin tree_sha256 -> exit 1"
notree="$(fixture_dir notree)"
make_artifact "${notree}"
put_text "${notree}/MANIFEST.json" "{\"commit\":\"${COMMIT_OK}\"}"
run_capture bash "${MANIFEST}" check "${notree}"
assert_eq "exit 1" "1" "${RC}"

begin "manifiesto sin commit -> exit 1"
nocommit="$(fixture_dir nocommit)"
make_artifact "${nocommit}"
put_text "${nocommit}/MANIFEST.json" "{\"tree_sha256\":\"${GOLDEN}\"}"
run_capture bash "${MANIFEST}" check "${nocommit}"
assert_eq "exit 1" "1" "${RC}"

begin "tree_sha256 en ceros (64) -> exit 1"
zeros="$(fixture_dir zeros)"
make_artifact "${zeros}"
put_text "${zeros}/MANIFEST.json" \
  "{\"commit\":\"${COMMIT_OK}\",\"tree_sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}"
run_capture bash "${MANIFEST}" check "${zeros}"
assert_eq "exit 1" "1" "${RC}"

begin "sourcearlo no ejecuta main y expone tree_sha256"
sourced="$(bash -c 'source "$1"; if declare -F tree_sha256 >/dev/null; then echo expuesta; else echo ausente; fi' _ "${MANIFEST}")"
assert_eq "función expuesta sin ejecutar main" "expuesta" "${sourced}"

printf '\n\033[1;32mOK\033[0m: %d assertions pasaron.\n' "${CASES}"
