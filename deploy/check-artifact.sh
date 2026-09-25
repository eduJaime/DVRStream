#!/usr/bin/env bash
#
# check-artifact.sh -- Gate de limpieza para un front listo para publicar.
#
# Uso:
#   bash deploy/check-artifact.sh <directorio>
#
# Falla (exit 1) si el árbol de artefactos contiene:
#   - una URL RTSP con credenciales embebidas (rtsp://usuario:clave@host)
#   - un literal de IP privada: 10/8, 172.16/12 o 192.168/16
#   - la cadena DVR_PASSWORD o go2rtc.yaml
#
# LIMITACIÓN CONOCIDA Y ACEPTADA (honestidad, no adorno): este gate atrapa
# literales de rango privado únicamente. Una IP pública (por ejemplo la IP
# WAN real del hogar) PASA sin ser detectada. El placeholder versionado del
# repo es IP_LXC y el diseño registra esta brecha (P-D23, tensión 5), así que
# se acepta a conciencia: el gate reduce el riesgo de fuga, no lo elimina.
#
# exit 0: limpio · exit 1: hay violaciones · exit 2: uso incorrecto.
# Dependencias: bash + find + grep (coreutils). Sin red, sin root.

set -euo pipefail

PRIVATE_V4_RE='(^|[^0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)'
RTSP_CRED_RE='rtsp://[^[:space:]/@]+:[^[:space:]/@]+@'

usage() {
  printf 'Uso: bash deploy/check-artifact.sh <directorio>\n' >&2
}

main() {
  if [[ $# -ne 1 ]]; then
    usage
    exit 2
  fi

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

  # Se leen TODOS los archivos regulares como texto (-a), binarios incluidos:
  # una IP embebida en un asset binario también es una fuga.
  local violations=0 file rel
  while IFS= read -r -d '' file; do
    rel="${file#"${dir}"/}"
    if grep -aqE "${RTSP_CRED_RE}" "${file}"; then
      printf '[x] %s: URL RTSP con credenciales embebidas\n' "${rel}" >&2
      violations=$((violations + 1))
    fi
    if grep -aqE "${PRIVATE_V4_RE}" "${file}"; then
      printf '[x] %s: literal de IP privada (10/8, 172.16/12 o 192.168/16)\n' "${rel}" >&2
      violations=$((violations + 1))
    fi
    if grep -aqF 'DVR_PASSWORD' "${file}"; then
      printf '[x] %s: cadena DVR_PASSWORD\n' "${rel}" >&2
      violations=$((violations + 1))
    fi
    if grep -aqF 'go2rtc.yaml' "${file}"; then
      printf '[x] %s: cadena go2rtc.yaml\n' "${rel}" >&2
      violations=$((violations + 1))
    fi
  done < <(find "${dir}" -type f -print0)

  if ((violations > 0)); then
    printf '[x] check-artifact: %d violación(es) en %s\n' "${violations}" "${dir}" >&2
    exit 1
  fi

  printf 'OK: sin credenciales ni IPs privadas en %s\n' "${dir}"
}

main "$@"
