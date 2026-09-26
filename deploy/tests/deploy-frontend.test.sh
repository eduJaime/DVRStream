#!/usr/bin/env bash
#
# deploy-frontend.test.sh -- Contrato del fallback manual deploy/deploy-frontend.sh.
#
# Uso:
#   bash deploy/tests/deploy-frontend.test.sh
#
# Sólo usa bash + coreutils (awk, grep). No requiere root, red ni rsync: verifica
# el CONTRATO de la invocación, no la semántica de rsync. La prueba real del
# comportamiento (rsync contra un sandbox con el layout de symlink) vive en la
# verificación del cambio; este harness protege el contrato en CI, al estilo de
# ci-workflow.test.sh con ci.yml.
#
# Por qué: tras PR5, /opt/visor-camaras/www es un symlink a releases/<id> que el
# updater reemplaza con un rename(2). El fallback manual tiene que escribir A
# TRAVES de ese symlink (--keep-dirlinks), no resolverlo, y ajustar el dueño del
# contenido real (chown -RH), o rompe el layout del que depende
# visor-camaras-update.
#
# Corta en el primer fallo (exit 1) para mantener la salida legible.

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${TEST_DIR}/../.." && pwd)"
DEPLOY="${REPO_DIR}/deploy/deploy-frontend.sh"

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

assert_contains() { # <label> <texto> <substring>
  [[ "$2" == *"$3"* ]] || fail "$1: se esperaba encontrar [$3] en [$2]"
  ok
}

assert_not_contains() { # <label> <texto> <substring>
  [[ "$2" != *"$3"* ]] || fail "$1: NO debía contener [$3]"
  ok
}

assert_matches() { # <label> <texto> <ERE>
  printf '%s\n' "$2" | grep -qE "$3" || fail "$1: [$2] no matchea /$3/"
  ok
}

assert_lt() { # <label> <numero> <numero>: exige ambos presentes y $2 < $3
  [[ -n "$2" && -n "$3" && "$2" -lt "$3" ]] || fail "$1: [$2] no es menor que [$3]"
  ok
}

assert_nonempty() { # <label> <texto>
  [[ -n "$2" ]] || fail "$1: bloque vacío"
  ok
}

assert_exists() { # <label> <path>
  [[ -e "$2" ]] || fail "$1: no existe [$2]"
  ok
}

assert_executable() { # <label> <path>
  [[ -x "$2" ]] || fail "$1: no es ejecutable [$2]"
  ok
}

# assert_keep_dirlinks <label> <texto>: acepta la forma larga o el cluster corto
# con K (p. ej. -K, -azK). Es el flag que hace escribir A TRAVES del symlink.
assert_keep_dirlinks() {
  if [[ "$2" == *"--keep-dirlinks"* ]] \
    || printf '%s\n' "$2" | grep -qE '(^|[[:space:]])-[a-zA-Z]*K[a-zA-Z]*([[:space:]]|$)'; then
    ok
  else
    fail "$1: falta -K/--keep-dirlinks en el rsync: el symlink del destino se reemplazaría por un directorio real"
  fi
}

# command_block <comando> -> primera invocación del comando con sus continuaciones
# (lee de stdin; se le pasa el código sin comentarios para que un comentario no
# pueda satisfacer ni tapar el contrato).
command_block() {
  awk -v cmd="$1" '
    $0 ~ "^[[:space:]]*" cmd "([[:space:]]|$)" { inside = 1 }
    inside { print; if ($0 !~ /\\$/) exit }
  '
}

# line_of <texto> <substring> -> número de línea (1-based) o vacío
line_of() {
  printf '%s\n' "$1" | awk -v pat="$2" 'index($0, pat) > 0 { print NR; exit }'
}

if [[ ! -f "${DEPLOY}" ]]; then
  printf 'FAIL: no existe %s\n' "${DEPLOY}" >&2
  exit 1
fi

DEPLOY_TEXT="$(< "${DEPLOY}")"
# El contrato se busca en el código, no en los comentarios: un comentario que
# mencione las banderas no debe poder satisfacer el test.
DEPLOY_CODE="$(grep -vE '^[[:space:]]*#' "${DEPLOY}" || true)"
RSYNC_CMD="$(printf '%s\n' "${DEPLOY_CODE}" | command_block rsync)"
OWNERSHIP_CMD="$(printf '%s\n' "${DEPLOY_CODE}" | grep -m1 'chown -R' || true)"

printf '\n== archivo y sintaxis ==\n'

begin "existe el fallback manual"
assert_exists "deploy-frontend.sh" "${DEPLOY}"
assert_executable "deploy-frontend.sh es ejecutable" "${DEPLOY}"

begin "sintaxis bash válida"
bash -n "${DEPLOY}"
assert_eq "bash -n" "0" "$?"

printf '\n== una sola invocación de rsync ==\n'

begin "una única invocación de rsync en todo el script"
assert_eq "una sola vez" "1" \
  "$(grep -cE '^[[:space:]]*rsync([[:space:]]|$)' "${DEPLOY}" || true)"
assert_nonempty "bloque de rsync" "${RSYNC_CMD}"

printf '\n== contrato de banderas: escribir A TRAVES del symlink ==\n'

begin "el rsync conserva el dirlink del destino (-K/--keep-dirlinks)"
assert_keep_dirlinks "keep-dirlinks presente" "${RSYNC_CMD}"

begin "el rsync espeja el build exacto (archive, compresión, borrado)"
assert_matches "archivo (-a)" "${RSYNC_CMD}" '(^|[[:space:]])-[a-zA-Z]*a[a-zA-Z]*([[:space:]]|$)'
assert_matches "compresión (-z)" "${RSYNC_CMD}" '(^|[[:space:]])-[a-zA-Z]*z[a-zA-Z]*([[:space:]]|$)'
assert_contains "borra lo que ya no está (--delete)" "${RSYNC_CMD}" '--delete'

begin "transporte y extremos de la copia"
assert_contains "ssh con SSH_PORT" "${RSYNC_CMD}" '-e "ssh -p ${SSH_PORT}"'
assert_contains "origen es el build" "${RSYNC_CMD}" '"${BROWSER_DIR}/"'
assert_contains "destino es el path del symlink" "${RSYNC_CMD}" \
  '"${SSH_USER}@${IP_LXC}:${DEST_DIR}/"'

printf '\n== coherencia con el layout de symlink ==\n'

begin "el destino es /opt/visor-camaras/www (el symlink, sin resolverlo)"
assert_contains "DEST_DIR literal" "${DEPLOY_TEXT}" 'DEST_DIR="/opt/visor-camaras/www"'
assert_not_contains "sin --copy-dirlinks (semántica opuesta)" "${RSYNC_CMD}" '--copy-dirlinks'
assert_not_contains "no resuelve el symlink con readlink" "${DEPLOY_TEXT}" 'readlink'
assert_not_contains "no resuelve el symlink con realpath" "${DEPLOY_TEXT}" 'realpath'

begin "la intención del symlink queda documentada en el script"
assert_contains "comentario con symlink" "${DEPLOY_TEXT}" 'symlink'
assert_contains "comentario con keep-dirlinks" "${DEPLOY_TEXT}" 'keep-dirlinks'

printf '\n== ajuste de dueño y permisos coherente con el symlink ==\n'

begin "el ajuste de dueño atraviesa el symlink (chown -R no lo hace por defecto)"
assert_nonempty "comando de dueño/permisos" "${OWNERSHIP_CMD}"
assert_matches "chown recursivo y transversal (-RH)" "${OWNERSHIP_CMD}" \
  "chown[[:space:]]+-[A-Za-z]*(RH|HR)[A-Za-z]*([[:space:]]|$)"
assert_contains "dueño go2rtc:go2rtc" "${OWNERSHIP_CMD}" 'go2rtc:go2rtc'
assert_contains "sobre el path servido" "${OWNERSHIP_CMD}" "'\${DEST_DIR}'"
assert_contains "permisos de lectura" "${OWNERSHIP_CMD}" 'chmod -R a+rX'

begin "el orden es: copiar y después ajustar"
rsync_line="$(line_of "${DEPLOY_CODE}" 'rsync -')"
ownership_line="$(line_of "${DEPLOY_CODE}" 'chown -R')"
assert_lt "rsync antes del ajuste" "${rsync_line}" "${ownership_line}"

printf '\n== verificación HTTP conservada ==\n'

begin "el script sigue verificando el sitio por HTTP"
assert_contains "curl -fsS" "${DEPLOY_TEXT}" 'curl -fsS'
assert_contains "puerto 1984" "${DEPLOY_TEXT}" ':1984/'

printf '\n\033[1;32mOK\033[0m: %d assertions pasaron.\n' "${CASES}"
