#!/usr/bin/env bash
#
# manifest.sh -- MANIFEST.json y hash canónico del artefacto publicable.
#
# Uso:
#   bash deploy/manifest.sh hash  <directorio>
#   bash deploy/manifest.sh write <directorio> <commit> <run_id> <node> <built_at>
#   bash deploy/manifest.sh check <directorio>
#
#   hash:  imprime el sha256 canónico del árbol: archivos regulares, rutas con
#          prefijo ./, ordenadas por bytes (LC_ALL=C) y excluyendo
#          MANIFEST.json. Es la misma función que usan verify y publish (y, en
#          PR3, el contenedor), así que el hash publicado y el recalculado en
#          el LXC coinciden por construcción.
#   write: valida los campos, escribe <directorio>/MANIFEST.json en una sola
#          línea y imprime el tree_sha256. El manifiesto no entra en su propio
#          hash, por eso reescribirlo no cambia el digest.
#   check: recalcula el hash y lo compara con el tree_sha256 del manifiesto
#          existente. exit 0 e imprime el hash si coincide; exit 1 si el
#          artefacto fue tamperado o el manifiesto falta/está incompleto.
#
# exit 0: OK · exit 1: manifiesto ausente/incompleto o hash no coincide
# · exit 2: uso incorrecto, directorio inválido o campo inválido.
#
# Dependencias: bash + coreutils (find, sort, xargs, sha256sum, sed). Sin red.
#
# Los campos se validan con whitelist (no con escape) para que un valor hostil
# no pueda romper el JSON que el contenedor parsea en PR3.

set -euo pipefail

usage() {
  printf 'Uso:\n' >&2
  printf '  bash deploy/manifest.sh hash  <directorio>\n' >&2
  printf '  bash deploy/manifest.sh write <directorio> <commit> <run_id> <node> <built_at>\n' >&2
  printf '  bash deploy/manifest.sh check <directorio>\n' >&2
}

# require_dir <directorio>: sale 2 si no existe o no es un directorio.
require_dir() {
  local dir="$1"
  [[ "${dir}" == "/" ]] || dir="${dir%/}"

  if [[ ! -e "${dir}" ]]; then
    printf '[x] No existe: %s\n' "${dir}" >&2
    exit 2
  fi
  if [[ ! -d "${dir}" ]]; then
    printf '[x] No es un directorio: %s\n' "${dir}" >&2
    exit 2
  fi
}

# tree_sha256 <directorio> -> imprime el sha256 canónico
tree_sha256() {
  local dir="$1"
  (
    cd -- "${dir}" || exit 2
    # LC_ALL=C: orden por bytes, independiente del locale del runner.
    # -type f: sólo archivos regulares; un symlink no entra al hash (el
    # contenedor rechaza entradas symlink al extraer, así que no es publicable).
    # ! -name MANIFEST.json: el manifiesto no se hashea a sí mismo.
    # xargs -r: con lista vacía no ejecuta sha256sum (no lee stdin) y el digest
    # queda estable: sha256 del stream vacío.
    LC_ALL=C find . -type f ! -name MANIFEST.json -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 -r sha256sum \
      | sha256sum \
      | cut -d' ' -f1
  )
}

# campo_valido <nombre> <valor>: whitelist por campo (anti-inyección de JSON).
campo_valido() {
  local nombre="$1" valor="$2"
  case "${nombre}" in
    commit)
      [[ "${valor}" =~ ^[0-9a-f]{7,40}$ ]] || return 1
      ;;
    run_id)
      [[ "${valor}" =~ ^[0-9]+$ ]] || return 1
      ;;
    node)
      [[ "${valor}" =~ ^[vV]?[0-9][0-9A-Za-z.+-]*$ ]] || return 1
      ;;
    built_at)
      [[ "${valor}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

# write_manifest <dir> <commit> <run_id> <node> <built_at>
write_manifest() {
  local dir="$1" commit="$2" run_id="$3" node="$4" built_at="$5"

  campo_valido commit "${commit}" \
    || { printf '[x] commit inválido: [%s]\n' "${commit}" >&2; exit 2; }
  campo_valido run_id "${run_id}" \
    || { printf '[x] run_id inválido: [%s]\n' "${run_id}" >&2; exit 2; }
  campo_valido node "${node}" \
    || { printf '[x] node inválido: [%s]\n' "${node}" >&2; exit 2; }
  campo_valido built_at "${built_at}" \
    || { printf '[x] built_at inválido: [%s]\n' "${built_at}" >&2; exit 2; }

  local tree
  tree="$(tree_sha256 "${dir}")" || exit 2

  printf '{"commit":"%s","run_id":"%s","node":"%s","built_at":"%s","tree_sha256":"%s"}\n' \
    "${commit}" "${run_id}" "${node}" "${built_at}" "${tree}" \
    > "${dir}/MANIFEST.json"

  printf '%s\n' "${tree}"
}

# check_manifest <directorio> -> exit 0 e imprime el hash si coincide.
check_manifest() {
  local dir="$1"
  local file="${dir}/MANIFEST.json"

  if [[ ! -f "${file}" ]]; then
    printf '[x] falta MANIFEST.json en %s\n' "${dir}" >&2
    return 1
  fi

  local commit stored actual
  commit="$(sed -n 's/.*"commit":"\([0-9a-f]\{7,40\}\)".*/\1/p' "${file}" | head -n1)"
  stored="$(sed -n 's/.*"tree_sha256":"\([0-9a-f]\{64\}\)".*/\1/p' "${file}" | head -n1)"

  if [[ -z "${commit}" ]]; then
    printf '[x] MANIFEST.json sin commit válido\n' >&2
    return 1
  fi
  if [[ -z "${stored}" ]]; then
    printf '[x] MANIFEST.json sin tree_sha256 válido\n' >&2
    return 1
  fi

  actual="$(tree_sha256 "${dir}")" || return 1
  if [[ "${actual}" != "${stored}" ]]; then
    printf '[x] tree_sha256 no coincide: manifiesto=%s calculado=%s\n' \
      "${stored}" "${actual}" >&2
    return 1
  fi

  printf '%s\n' "${actual}"
}

main() {
  local cmd="${1:-}"
  case "${cmd}" in
    hash)
      [[ $# -eq 2 ]] || { usage; exit 2; }
      require_dir "$2"
      tree_sha256 "$2"
      ;;
    write)
      [[ $# -eq 6 ]] || { usage; exit 2; }
      require_dir "$2"
      write_manifest "$2" "$3" "$4" "$5" "$6"
      ;;
    check)
      [[ $# -eq 2 ]] || { usage; exit 2; }
      require_dir "$2"
      check_manifest "$2"
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

# Guard de sourceo (mismo patrón que install-lxc.sh): sourcearlo expone las
# funciones sin ejecutar nada.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
