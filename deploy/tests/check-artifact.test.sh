#!/usr/bin/env bash
#
# check-artifact.test.sh -- Tests sin dependencias de deploy/check-artifact.sh.
#
# Uso:
#   bash deploy/tests/check-artifact.test.sh
#
# Sólo usa bash + coreutils (mktemp, mkdir, printf). No requiere root.
# Cubre: uso del CLI, árbol limpio, credenciales RTSP embebidas, literales de
# IP privada (con controles de límite), cadenas DVR_PASSWORD / go2rtc.yaml,
# recursión, archivos binarios y la limitación conocida (una IP pública pasa).
# Corta en el primer fallo (exit 1) para mantener la salida legible.

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${TEST_DIR}/../check-artifact.sh"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-artifact.test.XXXXXX")"
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

assert_contains() { # <label> <texto> <substring>
  [[ "$2" == *"$3"* ]] || fail "$1: se esperaba encontrar [$3] en [$2]"
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

make_clean_artifact() { # <dir>: artefacto mínimo realista
  put_text "$1/index.html" \
    '<!doctype html><html><body><app-root></app-root><script src="main-abc.js"></script></body></html>'
  put_text "$1/main-abc.js" 'console.log("visor-camaras");'
}

if [[ ! -f "${CHECK}" ]]; then
  printf 'FAIL: no existe %s\n' "${CHECK}" >&2
  exit 1
fi

printf '\n== uso del CLI ==\n'

begin "sin argumentos -> exit 2 y uso"
run_capture bash "${CHECK}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "mensaje de uso" "${ERR}" 'Uso'

begin "directorio inexistente -> exit 2"
run_capture bash "${CHECK}" "${WORK_DIR}/no-existe"
assert_eq "exit 2" "2" "${RC}"
assert_contains "motivo" "${ERR}" 'No existe'

begin "un archivo en vez de un directorio -> exit 2"
put_text "${WORK_DIR}/solo-archivo.txt" 'contenido'
run_capture bash "${CHECK}" "${WORK_DIR}/solo-archivo.txt"
assert_eq "exit 2" "2" "${RC}"
assert_contains "motivo" "${ERR}" 'No es un directorio'

begin "argumentos de más -> exit 2"
run_capture bash "${CHECK}" "${WORK_DIR}" "${WORK_DIR}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "mensaje de uso" "${ERR}" 'Uso'

printf '\n== árbol limpio ==\n'

begin "artefacto limpio -> exit 0 sin stderr"
clean="$(fixture_dir clean)"
make_clean_artifact "${clean}"
run_capture bash "${CHECK}" "${clean}"
assert_eq "exit 0" "0" "${RC}"
assert_contains "confirma OK" "${OUT}" 'OK'
assert_eq "stderr vacío" "" "${ERR}"

printf '\n== credenciales RTSP embebidas ==\n'

begin "rtsp://usuario:clave@host -> rechaza y nombra el archivo"
rtsp="$(fixture_dir rtsp-cred)"
make_clean_artifact "${rtsp}"
put_text "${rtsp}/config-abc.js" \
  'const src="rtsp://admin:s3cret@192.168.1.50:554/Streaming/Channels/101";'
run_capture bash "${CHECK}" "${rtsp}"
assert_eq "exit 1" "1" "${RC}"
assert_contains "nombra el archivo" "${ERR}" 'config-abc.js'
assert_contains "motivo rtsp" "${ERR}" 'rtsp'

begin "rtsp sin credenciales -> acepta"
rtsp_bare="$(fixture_dir rtsp-bare)"
make_clean_artifact "${rtsp_bare}"
put_text "${rtsp_bare}/config.js" \
  'const src="rtsp://camara.local:554/Streaming/Channels/101";'
run_capture bash "${CHECK}" "${rtsp_bare}"
assert_eq "exit 0" "0" "${RC}"

printf '\n== literales de IP privada ==\n'

begin "10/8 -> rechaza y nombra el archivo"
ten="$(fixture_dir ip-10)"
make_clean_artifact "${ten}"
put_text "${ten}/api-url.js" 'const host="10.0.0.5";'
run_capture bash "${CHECK}" "${ten}"
assert_eq "exit 1" "1" "${RC}"
assert_contains "nombra el archivo" "${ERR}" 'api-url.js'
assert_contains "motivo" "${ERR}" 'IP privada'

begin "172.16/12 -> rechaza los dos extremos"
for octet in 16 31; do
  net="$(fixture_dir "ip-172-${octet}")"
  make_clean_artifact "${net}"
  put_text "${net}/main.js" "const host=\"172.${octet}.0.1\";"
  run_capture bash "${CHECK}" "${net}"
  assert_eq "172.${octet}.0.1 rechazada" "1" "${RC}"
done

begin "192.168/16 -> rechaza"
lan="$(fixture_dir ip-192)"
make_clean_artifact "${lan}"
put_text "${lan}/lan.js" 'const host="192.168.100.200";'
run_capture bash "${CHECK}" "${lan}"
assert_eq "exit 1" "1" "${RC}"

begin "172.15.x y 172.32.x no son privadas -> acepta"
for octet in 15 32; do
  edge="$(fixture_dir "edge-172-${octet}")"
  make_clean_artifact "${edge}"
  put_text "${edge}/main.js" "const host=\"172.${octet}.0.1\";"
  run_capture bash "${CHECK}" "${edge}"
  assert_eq "172.${octet}.0.1 aceptada" "0" "${RC}"
done

begin "192.169.x y 11.x no son privadas -> acepta"
for addr in '192.169.1.1' '11.0.0.1'; do
  edge="$(fixture_dir "edge-${addr}")"
  make_clean_artifact "${edge}"
  put_text "${edge}/main.js" "const host=\"${addr}\";"
  run_capture bash "${CHECK}" "${edge}"
  assert_eq "${addr} aceptada" "0" "${RC}"
done

begin "IP pública -> PASA (limitación conocida y documentada del gate)"
public="$(fixture_dir ip-public)"
make_clean_artifact "${public}"
# 203.0.113.0/24 es TEST-NET-3 (RFC 5737): no es una IP real desplegada.
put_text "${public}/main.js" 'const host="203.0.113.9";'
run_capture bash "${CHECK}" "${public}"
assert_eq "una IP pública no se detecta (brecha conocida)" "0" "${RC}"

printf '\n== cadenas sensibles ==\n'

begin "DVR_PASSWORD -> rechaza"
pw="$(fixture_dir dvr-password)"
make_clean_artifact "${pw}"
put_text "${pw}/main.js" 'const k="DVR_PASSWORD";'
run_capture bash "${CHECK}" "${pw}"
assert_eq "exit 1" "1" "${RC}"
assert_contains "motivo" "${ERR}" 'DVR_PASSWORD'

begin "go2rtc.yaml -> rechaza"
yaml="$(fixture_dir go2rtc-yaml)"
make_clean_artifact "${yaml}"
put_text "${yaml}/main.js" 'const p="/etc/go2rtc/go2rtc.yaml";'
run_capture bash "${CHECK}" "${yaml}"
assert_eq "exit 1" "1" "${RC}"
assert_contains "motivo" "${ERR}" 'go2rtc.yaml'

begin "la palabra password suelta no dispara -> acepta"
loose="$(fixture_dir password-suelta)"
make_clean_artifact "${loose}"
put_text "${loose}/main.js" 'const userPasswordField="x";'
run_capture bash "${CHECK}" "${loose}"
assert_eq "exit 0" "0" "${RC}"

printf '\n== recursión, binarios y acumulación ==\n'

begin "detecta una violación en un subdirectorio profundo"
deep="$(fixture_dir deep)"
make_clean_artifact "${deep}"
put_text "${deep}/assets/chunks/main-def.js" 'const host="192.168.0.10";'
run_capture bash "${CHECK}" "${deep}"
assert_eq "exit 1" "1" "${RC}"
assert_contains "ruta relativa del archivo" "${ERR}" 'assets/chunks/main-def.js'

begin "detecta la IP privada dentro de un archivo binario"
bin="$(fixture_dir binario)"
make_clean_artifact "${bin}"
printf 'BIN\0\0%s\0' '10.1.2.3' > "${bin}/asset.bin"
run_capture bash "${CHECK}" "${bin}"
assert_eq "el binario también se revisa" "1" "${RC}"

begin "acumula varias violaciones en un mismo run"
multi="$(fixture_dir multi)"
make_clean_artifact "${multi}"
put_text "${multi}/a.js" 'const host="10.1.2.3";'
put_text "${multi}/b.js" 'const k="DVR_PASSWORD";'
run_capture bash "${CHECK}" "${multi}"
assert_eq "exit 1" "1" "${RC}"
assert_contains "cuenta 2 violaciones" "${ERR}" '2 violación'

printf '\n\033[1;32mOK\033[0m: %d assertions pasaron.\n' "${CASES}"
