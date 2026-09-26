#!/usr/bin/env bash
#
# ci-workflow.test.sh -- Invariantes de contención de .github/workflows/ci.yml.
#
# Uso:
#   bash deploy/tests/ci-workflow.test.sh
#
# Sólo usa bash + coreutils (awk, grep). No requiere root, red ni un parser
# YAML: verifica estructura, no semántica de Actions. La validez YAML se
# comprueba aparte con un parser real (PyYAML) en la verificación local.
#
# El objetivo es que un cambio futuro que borre una guarda de contención
# (el `if` de push a main, el refspec literal, la aserción de rama, el permiso
# de escritura acotado al job) rompa este test en CI, en vez de publicarse.
#
# Corta en el primer fallo (exit 1) para mantener la salida legible.

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${TEST_DIR}/../.." && pwd)"
WORKFLOW="${REPO_DIR}/.github/workflows/ci.yml"
MANIFEST="${REPO_DIR}/deploy/manifest.sh"

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

assert_lt() { # <label> <numero> <numero>: exige ambos presentes y $2 < $3
  [[ -n "$2" && -n "$3" && "$2" -lt "$3" ]] || fail "$1: [$2] no es menor que [$3]"
  ok
}

# block <job> -> líneas internas del job (clave a dos espacios)
block() {
  awk -v job="$1" '
    $0 == "  " job ":" { inside = 1; next }
    inside && $0 ~ /^  [A-Za-z0-9_-]+:/ { inside = 0 }
    inside { print }
  ' "${WORKFLOW}"
}

# top_block <clave> -> líneas internas de un bloque de primer nivel
top_block() {
  awk -v key="$1" '
    $0 == key ":" { inside = 1; next }
    inside && $0 ~ /^[^[:space:]]/ { inside = 0 }
    inside { print }
  ' "${WORKFLOW}"
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

# line_of <texto> <substring> -> número de línea (1-based) o vacío
line_of() {
  printf '%s\n' "$1" | awk -v pat="$2" 'index($0, pat) > 0 { print NR; exit }'
}

if [[ ! -f "${WORKFLOW}" ]]; then
  printf 'FAIL: no existe %s\n' "${WORKFLOW}" >&2
  exit 1
fi

VERIFY="$(block verify)"
PUBLISH="$(block publish)"

printf '\n== archivos y jobs ==\n'

begin "el workflow declara verify y publish"
assert_nonempty "bloque verify" "${VERIFY}"
assert_nonempty "bloque publish" "${PUBLISH}"

jobs_block="$(awk '/^jobs:/{inside=1;next} inside && /^[^[:space:]]/{inside=0} inside{print}' "${WORKFLOW}")"
assert_eq "dos jobs en total" "2" \
  "$(printf '%s\n' "${jobs_block}" | grep -cE '^  [A-Za-z0-9_-]+:$' || true)"

begin "existe el helper del manifiesto y su harness"
assert_executable "deploy/manifest.sh ejecutable" "${MANIFEST}"
assert_exists "deploy/tests/manifest.test.sh" "${TEST_DIR}/manifest.test.sh"

printf '\n== disparadores y permisos del workflow ==\n'

begin "dispara en push a main, PR y dispatch"
on_block="$(top_block on)"
assert_contains "push" "${on_block}" 'push:'
assert_contains "sólo main" "${on_block}" 'branches: [main]'
assert_contains "pull_request" "${on_block}" 'pull_request:'
assert_contains "workflow_dispatch" "${on_block}" 'workflow_dispatch:'

begin "permiso global de sólo lectura (sin write)"
perms_glob="$(top_block permissions)"
assert_contains "contents: read" "${perms_glob}" 'contents: read'
assert_not_contains "sin write a nivel workflow" "${perms_glob}" 'write'

begin "contents: write aparece exactamente una vez como clave YAML"
assert_eq "una sola vez" "1" "$(grep -cE '^[[:space:]]*contents: write[[:space:]]*$' "${WORKFLOW}" || true)"

printf '\n== verify: sube los bytes que verificó ==\n'

begin "conserva los gates de PR1"
assert_contains "install-lxc" "${VERIFY}" 'install-lxc.test.sh'
assert_contains "check-artifact" "${VERIFY}" 'check-artifact.test.sh'
assert_contains "manifest harness" "${VERIFY}" 'manifest.test.sh'
assert_contains "workflow harness" "${VERIFY}" 'ci-workflow.test.sh'
test_cmd="$(printf '%s\n' "${VERIFY}" | grep -m1 'ng test' || true)"
assert_contains "vitest sin watch" "${test_cmd}" 'ng test --watch=false'
assert_not_contains "sin --no-watch" "${test_cmd}" '--no-watch'

begin "escribe el manifiesto con el helper (no inline)"
assert_contains "manifest.sh write" "${VERIFY}" 'manifest.sh write'
assert_contains "incluye el SHA de origen" "${VERIFY}" 'GITHUB_SHA'

begin "sube exactamente el dist construido"
assert_contains "upload-artifact" "${VERIFY}" 'actions/upload-artifact@v4'
assert_contains "nombre del artefacto" "${VERIFY}" 'name: frontend-dist'
assert_contains "path del dist" "${VERIFY}" 'path: frontend/dist/frontend/browser'
assert_contains "falla si no hay archivos" "${VERIFY}" 'if-no-files-found: error'
write_line="$(line_of "${VERIFY}" 'manifest.sh write')"
upload_line="$(line_of "${VERIFY}" 'actions/upload-artifact')"
assert_lt "manifiesto antes de subir" "${write_line}" "${upload_line}"

printf '\n== publish: gating, permisos y concurrencia ==\n'

begin "sólo en push a main (nunca en PR)"
assert_contains "needs verify" "${PUBLISH}" 'needs: verify'
if_line="$(printf '%s\n' "${PUBLISH}" | grep -m1 '^    if:' || true)"
assert_contains "evento push" "${if_line}" "github.event_name == 'push'"
assert_contains "ref main" "${if_line}" 'refs/heads/main'
assert_not_contains "sin workflow_run" "${if_line}" 'workflow_run'
assert_not_contains "sin inputs" "${if_line}" 'inputs.'

begin "permiso de escritura acotado al job publish"
pub_perms="$(printf '%s\n' "${PUBLISH}" | awk '
  /^    permissions:/ { inside = 1; next }
  inside && /^    [A-Za-z0-9_-]+:/ { inside = 0 }
  inside { print }
')"
assert_contains "contents: write" "${pub_perms}" 'contents: write'
assert_eq "una sola clave de permiso" "1" \
  "$(printf '%s\n' "${pub_perms}" | grep -cE '^[[:space:]]*[a-z-]+:[[:space:]]*[a-z]+' || true)"

begin "concurrencia serializada sin cancelar a mitad del push"
assert_contains "grupo" "${PUBLISH}" 'group: frontend-dist-publish'
assert_contains "no cancela" "${PUBLISH}" 'cancel-in-progress: false'

begin "no reconstruye: publica los bytes descargados"
assert_contains "descarga el artefacto" "${PUBLISH}" 'actions/download-artifact@v4'
assert_contains "mismo nombre" "${PUBLISH}" 'name: frontend-dist'
assert_not_contains "sin npm ci" "${PUBLISH}" 'npm ci'
assert_not_contains "sin ng build" "${PUBLISH}" 'ng build'
assert_not_contains "sin ng test" "${PUBLISH}" 'ng test'

printf '\n== publish: construcción de la rama ==\n'

begin "rama huérfana limpia y un solo commit"
assert_contains "orphan" "${PUBLISH}" 'git checkout --orphan frontend-dist'
assert_contains "borra el árbol versionado" "${PUBLISH}" 'git rm -rf'
assert_contains "limpia los no versionados" "${PUBLISH}" 'find . -mindepth 1 -maxdepth 1'
assert_contains "copia los bytes descargados" "${PUBLISH}" 'cp -a'
assert_contains "identidad del bot por comando" "${PUBLISH}" '-c user.name='
assert_contains "un commit por publish, con mensaje trazable" "${PUBLISH}" \
  'commit -m "build: publish ${GITHUB_SHA:0:7} (run ${GITHUB_RUN_ID})"'

printf '\n== publish: contención del push ==\n'

begin "un único git push en todo el workflow"
assert_eq "una sola vez" "1" "$(grep -c 'git push' "${WORKFLOW}" || true)"
push_text="$(printf '%s\n' "${PUBLISH}" | grep 'git push' || true)"
assert_contains "refspec literal" "${push_text}" 'HEAD:refs/heads/frontend-dist'
assert_contains "force explícito" "${push_text}" '--force'
assert_not_contains "sin --all" "${push_text}" '--all'
assert_not_contains "sin --mirror" "${push_text}" '--mirror'
assert_not_contains "sin ref derivado de expresión" "${push_text}" '${{'
assert_not_contains "sin ref derivado de input" "${push_text}" 'inputs.'

begin "guardas de evento, ref y rama corren antes del push"
push_line="$(line_of "${PUBLISH}" 'git push')"
ref_guard_line="$(line_of "${PUBLISH}" 'GITHUB_REF')"
branch_guard_line="$(line_of "${PUBLISH}" 'rev-parse --abbrev-ref HEAD')"
assert_lt "guarda de ref antes" "${ref_guard_line}" "${push_line}"
assert_lt "guarda de rama antes" "${branch_guard_line}" "${push_line}"

printf '\n== publish: integridad del artefacto publicado ==\n'

begin "verifica el hash del artefacto descargado antes de empujar"
first_check="$(line_of "${PUBLISH}" 'manifest.sh check')"
assert_lt "check antes del push" "${first_check}" "${push_line}"
after_push="$(printf '%s\n' "${PUBLISH}" | awk -v n="${push_line}" 'NR > n { print }')"
assert_contains "re-verifica tras empujar" "${after_push}" 'check "$out"'
assert_contains "re-descarga desde codeload" "${after_push}" 'codeload'
assert_contains "reintentos" "${after_push}" 'for attempt in 1 2 3'
assert_contains "job summary" "${after_push}" 'GITHUB_STEP_SUMMARY'

printf '\n== publish-safety ==\n'

begin "GITHUB_TOKEN únicamente: sin secrets, PAT ni token explícito"
assert_eq "cero secrets.* en el workflow" "0" \
  "$(grep -c 'secrets\.' "${WORKFLOW}" || true)"
assert_not_contains "sin token explícito" "${PUBLISH}" 'token:'
assert_not_contains "sin github.token manual" "${PUBLISH}" 'github.token'
assert_not_contains "sin checkout de otro repo" "${PUBLISH}" 'repository:'

printf '\n\033[1;32mOK\033[0m: %d assertions pasaron.\n' "${CASES}"
