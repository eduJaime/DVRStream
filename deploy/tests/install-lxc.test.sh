#!/usr/bin/env bash
#
# install-lxc.test.sh -- Tests sin dependencias de deploy/install-lxc.sh.
#
# Uso:
#   bash deploy/tests/install-lxc.test.sh
#
# Sólo usa bash + coreutils (mktemp, chmod, stat, find). No requiere root.
# Cubre: helpers puros (urlencode, parse_route_src), validadores, lectura
# segura de la contraseña, renderer del YAML y el camino --dry-run completo.
# Corta en el primer fallo (exit 1) para mantener la salida legible.

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${TEST_DIR}/../install-lxc.sh"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/install-lxc.test.XXXXXX")"
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

assert_not_contains() { # <label> <texto> <substring>
  [[ "$2" != *"$3"* ]] || fail "$1: NO debía contener [$3]"
  ok
}

predicate_status() { # <fn> <arg> -> imprime 0 si acepta, != 0 si rechaza
  if "$1" "$2"; then printf '0'; else printf '%s' "$?"; fi
}

assert_accepts() { # <label> <fn> <arg>
  local st
  st="$(predicate_status "$2" "$3")"
  [[ "$st" == "0" ]] || fail "$1: se esperaba que acepte [$3] (status $st)"
  ok
}

assert_rejects() { # <label> <fn> <arg>
  local st
  st="$(predicate_status "$2" "$3")"
  [[ "$st" != "0" ]] || fail "$1: se esperaba que rechace [$3]"
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

if [[ ! -f "${INSTALLER}" ]]; then
  printf 'FAIL: no existe %s\n' "${INSTALLER}" >&2
  exit 1
fi

# D20: el script debe poder sourcearse sin ejecutar nada.
# shellcheck source=../install-lxc.sh
source "${INSTALLER}"

if ! declare -F urlencode >/dev/null; then
  printf 'FAIL: install-lxc.sh no expone urlencode() al sourcearlo (falta el guard D20)\n' >&2
  exit 1
fi

printf '\n== helpers puros (D1) ==\n'

begin "urlencode: string vacío"
assert_eq "vacío -> vacío" "" "$(urlencode '')"

begin "urlencode: unreserved pasa intacto"
assert_eq "A-Za-z0-9-._~" "Abc019-._~" "$(urlencode 'Abc019-._~')"

begin "urlencode: credenciales con @ y espacio"
assert_eq "p@ss word" "p%40ss%20word" "$(urlencode 'p@ss word')"

begin "urlencode: reservados de URL"
assert_eq "@:/#?&%" "%40%3A%2F%23%3F%26%25" "$(urlencode '@:/#?&%')"

begin "urlencode: UTF-8 byte a byte (ñ)"
assert_eq "ñ" "%C3%B1" "$(urlencode 'ñ')"

begin "urlencode: comilla doble (no puede escapar el YAML)"
assert_eq '"' "%22" "$(urlencode '"')"

printf '\n== parse_route_src (D2) ==\n'

begin "parse_route_src: línea típica de ip route get"
assert_eq "src 192.168.1.50" "192.168.1.50" \
  "$(parse_route_src '1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.50 uid 0')"

begin "parse_route_src: src al final de la línea"
assert_eq "src 10.0.0.7" "10.0.0.7" \
  "$(parse_route_src '1.1.1.1 dev eth0 src 10.0.0.7 uid 1000 cache')"

begin "parse_route_src: sin src -> vacío"
assert_eq "sin src" "" "$(parse_route_src '1.1.1.1 dev eth0 uid 0')"

printf '\n== validadores (D2) ==\n'

begin "is_ipv4 acepta IPv4 válidas"
assert_accepts "192.168.1.50" is_ipv4 '192.168.1.50'
assert_accepts "0.0.0.0" is_ipv4 '0.0.0.0'
assert_accepts "255.255.255.255" is_ipv4 '255.255.255.255'

begin "is_ipv4 rechaza inválidas"
assert_rejects "256.1.1.1" is_ipv4 '256.1.1.1'
assert_rejects "1.2.3" is_ipv4 '1.2.3'
assert_rejects "1.2.3.4.5" is_ipv4 '1.2.3.4.5'
assert_rejects "1.2.3.4:554" is_ipv4 '1.2.3.4:554'
assert_rejects "vacío" is_ipv4 ''
assert_rejects "1.2.3.4/24" is_ipv4 '1.2.3.4/24'

begin "is_valid_dvr_host acepta IP o hostname"
assert_accepts "10.0.0.5" is_valid_dvr_host '10.0.0.5'
assert_accepts "dvr.local" is_valid_dvr_host 'dvr.local'
assert_accepts "hikvision-dvr-1" is_valid_dvr_host 'hikvision-dvr-1'

begin "is_valid_dvr_host rechaza scheme/puerto/ruta/@/espacio"
assert_rejects "rtsp://10.0.0.5" is_valid_dvr_host 'rtsp://10.0.0.5'
assert_rejects "10.0.0.5:554" is_valid_dvr_host '10.0.0.5:554'
assert_rejects "10.0.0.5/cam" is_valid_dvr_host '10.0.0.5/cam'
assert_rejects "user@10.0.0.5" is_valid_dvr_host 'user@10.0.0.5'
assert_rejects "host con espacio" is_valid_dvr_host 'host con espacio'
assert_rejects "vacío" is_valid_dvr_host ''

begin "is_valid_user acepta 1..64 sin control chars"
assert_accepts "admin" is_valid_user 'admin'
assert_accepts "64 chars" is_valid_user "$(printf 'a%.0s' {1..64})"

begin "is_valid_user rechaza vacío, >64 y control chars"
assert_rejects "vacío" is_valid_user ''
assert_rejects "65 chars" is_valid_user "$(printf 'a%.0s' {1..65})"
assert_rejects "tab" is_valid_user "$(printf 'a\tb')"

begin "is_valid_channel_path acepta rutas del DVR"
assert_accepts "/Streaming/Channels/101" is_valid_channel_path '/Streaming/Channels/101'
assert_accepts "con %25 pre-encodeado" is_valid_channel_path '/a%b'
assert_accepts "raíz" is_valid_channel_path '/'
assert_accepts "128 chars" is_valid_channel_path "/$(printf 'a%.0s' {1..127})"

begin "is_valid_channel_path rechaza sin /, espacio, '?' y >128"
assert_rejects "sin slash inicial" is_valid_channel_path 'Streaming/Channels/101'
assert_rejects "con espacio" is_valid_channel_path '/a b'
assert_rejects "con ?" is_valid_channel_path '/a?b'
assert_rejects "129 chars" is_valid_channel_path "/$(printf 'a%.0s' {1..128})"

printf '\n== archivo de contraseña (D2) ==\n'

PWFILE="${WORK_DIR}/dvr.pw"
printf '%s\n' 'p@ss ñ#"&%' > "${PWFILE}"
chmod 600 "${PWFILE}"

begin "password_file_error: 0600 regular es válido"
assert_eq "sin error" "" "$(password_file_error "${PWFILE}")"

begin "password_file_error: 0644 se rechaza"
cp -- "${PWFILE}" "${WORK_DIR}/perm644.pw"
chmod 644 "${WORK_DIR}/perm644.pw"
assert_contains "modo 0600" "$(password_file_error "${WORK_DIR}/perm644.pw")" '0600'

begin "password_file_error: 0400 se rechaza"
cp -- "${PWFILE}" "${WORK_DIR}/perm400.pw"
chmod 400 "${WORK_DIR}/perm400.pw"
assert_contains "modo 0600" "$(password_file_error "${WORK_DIR}/perm400.pw")" '0600'

begin "password_file_error: symlink se rechaza"
ln -s -- "${PWFILE}" "${WORK_DIR}/link.pw"
assert_contains "enlace simbólico" "$(password_file_error "${WORK_DIR}/link.pw")" 'enlace'

begin "password_file_error: inexistente se rechaza"
assert_contains "no existe" "$(password_file_error "${WORK_DIR}/nope.pw")" 'no existe'

printf '\n== composición de la URL RTSP (D5) ==\n'

begin "build_rtsp_url codifica usuario y contraseña, no la ruta"
DVR_USER='op@r'
DVR_PASSWORD='p@ss ñ#"&%'
DVR_HOST='10.0.0.5'
assert_eq "URL codificada" \
  'rtsp://op%40r:p%40ss%20%C3%B1%23%22%26%25@10.0.0.5:554/Streaming/Channels/101' \
  "$(build_rtsp_url '/Streaming/Channels/101')"

begin "build_rtsp_url_masked oculta la contraseña"
assert_eq "URL enmascarada" \
  'rtsp://op%40r:****@10.0.0.5:554/Streaming/Channels/201' \
  "$(build_rtsp_url_masked '/Streaming/Channels/201')"

printf '\n== renderer + sanity del YAML (D5/D6) ==\n'

begin "render_config compone el YAML completo"
rendered="$(render_config '10.0.0.9' \
  'rtsp://u:p@h:554/a' 'rtsp://u:p@h:554/b' 'rtsp://u:p@h:554/c' 'rtsp://u:p@h:554/d')"
assert_contains "api.listen" "${rendered}" 'listen: ":1984"'
assert_contains "api.static_dir" "${rendered}" 'static_dir: "/opt/visor-camaras/www"'
assert_contains "rtsp.listen vacío" "${rendered}" 'rtsp:
  listen: ""'
assert_contains "webrtc.candidates" "${rendered}" '- 10.0.0.9:8555'
assert_contains "cam1" "${rendered}" 'cam1: "rtsp://u:p@h:554/a"'
assert_contains "cam4" "${rendered}" 'cam4: "rtsp://u:p@h:554/d"'
assert_contains "log.level" "${rendered}" 'level: info'
assert_contains "cabecera de archivo generado" "${rendered}" 'generado por deploy/install-lxc.sh'
assert_eq "4 streams" "4" "$(printf '%s\n' "${rendered}" | grep -cE '^  cam[1-4]: ' || true)"

begin "config_error: config rendereada es válida"
GOOD_CFG="${WORK_DIR}/good.yaml"
printf '%s\n' "${rendered}" > "${GOOD_CFG}"
assert_eq "sin error" "" "$(config_error "${GOOD_CFG}")"

begin "config_error: acepta credenciales que contienen USUARIO/PASSWORD (S2)"
printf 'streams:\n  cam1: "rtsp://USUARIO:PASSWORD@10.0.0.5:554/x"\n  cam2: "x"\n  cam3: "x"\n  cam4: "x"\n' \
  > "${WORK_DIR}/legit-tokens.yaml"
assert_eq "sin error" "" "$(config_error "${WORK_DIR}/legit-tokens.yaml")"

begin "config_error: acepta una ruta con %s dentro de la URL (S2)"
printf 'streams:\n  cam1: "rtsp://u:p@h:554/a%%sb"\n  cam2: "x"\n  cam3: "x"\n  cam4: "x"\n' \
  > "${WORK_DIR}/legit-percent.yaml"
assert_eq "sin error" "" "$(config_error "${WORK_DIR}/legit-percent.yaml")"

begin "config_error: detecta un placeholder estructural sin reemplazar"
printf 'webrtc:\n  candidates:\n    - IP_LXC:8555\nstreams:\n  cam1: "x"\n  cam2: "x"\n  cam3: "x"\n  cam4: "x"\n' \
  > "${WORK_DIR}/structural-placeholder.yaml"
assert_contains "placeholder" "$(config_error "${WORK_DIR}/structural-placeholder.yaml")" 'placeholder'

begin "config_error: detecta la plantilla sin sustituir"
cat > "${WORK_DIR}/raw-template.yaml" <<'EOF'
streams:
  cam1: "%s"
  cam2: "%s"
  cam3: "%s"
  cam4: "%s"
EOF
assert_contains "sin reemplazar" "$(config_error "${WORK_DIR}/raw-template.yaml")" 'sin reemplazar'

begin "config_error: detecta stream vacío"
printf 'streams:\n  cam1: ""\n  cam2: "x"\n  cam3: "x"\n  cam4: "x"\n' > "${WORK_DIR}/empty-cam.yaml"
assert_contains "stream sin URL" "$(config_error "${WORK_DIR}/empty-cam.yaml")" 'sin URL'

begin "config_error: detecta cantidad incorrecta de streams"
printf 'streams:\n  cam1: "x"\n' > "${WORK_DIR}/one-cam.yaml"
assert_contains "4 streams" "$(config_error "${WORK_DIR}/one-cam.yaml")" '4 streams'

printf '\n== CLI: --print-encoded, rechazos y ayuda (D3/D9) ==\n'

begin "--print-encoded lee una línea de stdin"
set +e
OUT="$(printf 'p@ss word\n' | bash "${INSTALLER}" --print-encoded 2>"${WORK_DIR}/stderr")"
RC=$?
set -e
ERR="$(<"${WORK_DIR}/stderr")"
assert_eq "exit 0" "0" "${RC}"
assert_eq "encoding" "p%40ss%20word" "${OUT}"

begin "--print-encoded no acepta argumentos"
run_capture bash "${INSTALLER}" --print-encoded 'p@ss'
assert_eq "exit 2 (no argv)" "2" "${RC}"
assert_contains "error de uso" "${ERR}" 'inesperado'

begin "--password por argv se rechaza sin escribir"
run_capture bash "${INSTALLER}" --dry-run --password 'secreto'
assert_eq "exit 2" "2" "${RC}"
assert_contains "mensaje" "${ERR}" 'no se acepta por línea de comandos'
assert_eq "no imprimió config" "" "${OUT}"

begin "-p (corto) también se rechaza"
run_capture bash "${INSTALLER}" -p 'secreto'
assert_eq "exit 2" "2" "${RC}"
assert_contains "mensaje" "${ERR}" 'no se acepta por línea de comandos'

begin "--password=... (forma con =) también se rechaza"
run_capture bash "${INSTALLER}" --dry-run --password=secreto
assert_eq "exit 2" "2" "${RC}"
assert_contains "mensaje" "${ERR}" 'no se acepta por línea de comandos'

begin "--password-file=PATH (forma con =) se acepta (S1)"
run_capture bash "${INSTALLER}" --dry-run --yes \
  --address '10.0.0.9' --dvr-host '10.0.0.5' --dvr-user 'admin' \
  "--password-file=${PWFILE}"
assert_eq "exit 0" "0" "${RC}"
assert_contains "URL enmascarada" "${OUT}" 'rtsp://admin:****@10.0.0.5:554/Streaming/Channels/101'

begin "--password-file= (vacío) se rechaza con mensaje preciso (S1)"
run_capture bash "${INSTALLER}" --dry-run --yes \
  --address '10.0.0.9' --dvr-host '10.0.0.5' --dvr-user 'admin' \
  '--password-file='
assert_eq "exit 2" "2" "${RC}"
assert_contains "falta el valor" "${ERR}" 'falta el valor de --password-file'
assert_not_contains "no confunde con argv" "${ERR}" 'no se acepta por línea de comandos'

begin "--help funciona sin root"
run_capture bash "${INSTALLER}" --help
assert_eq "exit 0" "0" "${RC}"
assert_contains "uso" "${OUT}" 'Uso:'

begin "--flag desconocido se rechaza"
run_capture bash "${INSTALLER}" --nope
assert_eq "exit 2" "2" "${RC}"

begin "--password-file - lee la contraseña de stdin"
set +e
OUT="$(printf 'stdin secret\n' | bash "${INSTALLER}" --dry-run --yes \
  --address '10.0.0.9' --dvr-host '10.0.0.5' --dvr-user 'admin' \
  --password-file - 2>"${WORK_DIR}/stderr")"
RC=$?
set -e
ERR="$(<"${WORK_DIR}/stderr")"
assert_eq "exit 0" "0" "${RC}"
assert_contains "URL enmascarada" "${OUT}" 'rtsp://admin:****@10.0.0.5:554/Streaming/Channels/101'
assert_not_contains "secreto raw ausente de la salida" "${OUT}${ERR}" 'stdin secret'
assert_not_contains "secreto encodeado ausente de la salida" "${OUT}${ERR}" 'stdin%20secret'

begin "--dry-run sin --yes y sin TTY no inventa confirmación"
run_capture bash "${INSTALLER}" --dry-run \
  --address '10.0.0.9' --dvr-host '10.0.0.5' --dvr-user 'admin' \
  --password-file "${PWFILE}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "falta --yes" "${ERR}" 'falta --yes'

printf '\n== versión de go2rtc fijada (pin) ==\n'

begin "el pin es v1.9.14 y la URL usa el tag, no latest"
assert_eq "tag fijado" "v1.9.14" "${GO2RTC_VERSION_PINNED}"
default_version="$(env -u GO2RTC_VERSION bash -c 'source "$1"; printf "%s" "${GO2RTC_VERSION}"' _ "${INSTALLER}")"
assert_eq "GO2RTC_VERSION por defecto" "${GO2RTC_VERSION_PINNED}" "${default_version}"
assert_eq "URL del asset fijado" \
  'https://github.com/AlexxIT/go2rtc/releases/download/v1.9.14/go2rtc_linux_amd64' \
  "$(go2rtc_download_url "${GO2RTC_VERSION_PINNED}" 'go2rtc_linux_amd64')"
assert_not_contains "sin /latest/ en la URL" \
  "$(go2rtc_download_url "${GO2RTC_VERSION_PINNED}" 'go2rtc_linux_arm64')" '/latest/'

begin "--go2rtc-version pisa el tag fijado y viaja a la URL"
flag_version="$( ( parse_args --go2rtc-version 'v1.9.15'; printf '%s' "${GO2RTC_VERSION}" ) )"
assert_eq "tag por flag" "v1.9.15" "${flag_version}"
flag_url="$( ( parse_args --go2rtc-version 'v1.9.15'; go2rtc_download_url "${GO2RTC_VERSION}" 'go2rtc_linux_arm64' ) )"
assert_eq "URL del tag override" \
  'https://github.com/AlexxIT/go2rtc/releases/download/v1.9.15/go2rtc_linux_arm64' \
  "${flag_url}"

begin "GO2RTC_VERSION del entorno pisa el tag fijado"
env_version="$(
  export GO2RTC_VERSION='v1.9.16'
  source "${INSTALLER}"
  printf '%s' "${GO2RTC_VERSION}"
)"
assert_eq "tag por entorno" "v1.9.16" "${env_version}"

begin "go2rtc_version_warning: silencio con el tag fijado"
assert_eq "sin aviso" "" "$(go2rtc_version_warning "${GO2RTC_VERSION_PINNED}")"

begin "go2rtc_version_warning: avisa al mover el tag y apunta a VERSION.txt"
pin_warning="$(go2rtc_version_warning 'v1.9.15')"
assert_contains "tag pedido" "${pin_warning}" 'v1.9.15'
assert_contains "tag vendorizado" "${pin_warning}" "${GO2RTC_VERSION_PINNED}"
assert_contains "ruta de VERSION.txt" "${pin_warning}" 'frontend/public/go2rtc/VERSION.txt'

begin "is_valid_go2rtc_version: acepta tags de release"
assert_accepts "v1.9.14" is_valid_go2rtc_version 'v1.9.14'
assert_accepts "v2.0.0" is_valid_go2rtc_version 'v2.0.0'

begin "is_valid_go2rtc_version: rechaza latest, sin v e inyección de URL"
assert_rejects "latest" is_valid_go2rtc_version 'latest'
assert_rejects "sin v" is_valid_go2rtc_version '1.9.14'
assert_rejects "con ruta" is_valid_go2rtc_version 'v1.9.14/../evil'
assert_rejects "vacío" is_valid_go2rtc_version ''

begin "--go2rtc-version latest se rechaza (exit 2)"
run_capture bash "${INSTALLER}" --dry-run --yes --go2rtc-version 'latest' \
  --address '10.0.0.9' --dvr-host '10.0.0.5' --dvr-user 'admin' \
  --password-file "${PWFILE}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "razón" "${ERR}" 'versión inválida'

begin "--go2rtc-version sin valor se rechaza"
run_capture bash "${INSTALLER}" --go2rtc-version
assert_eq "exit 2" "2" "${RC}"
assert_contains "falta el valor" "${ERR}" 'falta el valor de --go2rtc-version'

printf '\n== --dry-run end-to-end (D7) ==\n'

begin "--dry-run: config válida, enmascarada y sin root"
empty_dir="${WORK_DIR}/cwd"
mkdir -p "${empty_dir}"
etc_before="$(find /etc/go2rtc -type f 2>/dev/null | sort || true)"

set +e
OUT="$(cd "${empty_dir}" && bash "${INSTALLER}" --dry-run --yes \
  --address '10.0.0.9' --dvr-host '10.0.0.5' --dvr-user 'op@r' \
  --password-file "${PWFILE}" </dev/null 2>"${WORK_DIR}/stderr")"
RC=$?
set -e
ERR="$(<"${WORK_DIR}/stderr")"
etc_after="$(find /etc/go2rtc -type f 2>/dev/null | sort || true)"

RAW_PASS='p@ss ñ#"&%'
ENCODED_PASS='p%40ss%20%C3%B1%23%22%26%25'

assert_eq "exit 0 sin root" "0" "${RC}"
assert_eq "4 streams camN" "4" "$(printf '%s\n' "${OUT}" | grep -cE '^  cam[1-4]: ' || true)"
assert_contains "candidate del LXC" "${OUT}" '- 10.0.0.9:8555'
assert_contains "ruta default canal 1" "${OUT}" \
  'cam1: "rtsp://op%40r:****@10.0.0.5:554/Streaming/Channels/101"'
assert_contains "ruta default canal 2" "${OUT}" \
  'cam2: "rtsp://op%40r:****@10.0.0.5:554/Streaming/Channels/201"'
assert_contains "ruta default canal 3" "${OUT}" \
  'cam3: "rtsp://op%40r:****@10.0.0.5:554/Streaming/Channels/301"'
assert_contains "ruta default canal 4" "${OUT}" \
  'cam4: "rtsp://op%40r:****@10.0.0.5:554/Streaming/Channels/401"'
assert_contains "contraseña enmascarada" "${OUT}" ':****@'
assert_not_contains "contraseña raw ausente" "${OUT}${ERR}" "${RAW_PASS}"
assert_not_contains "contraseña encodeada ausente" "${OUT}${ERR}" "${ENCODED_PASS}"
assert_eq "cwd sin archivos nuevos" "" "$(find "${empty_dir}" -mindepth 1 -print -quit)"
assert_eq "/etc/go2rtc intacto" "${etc_before}" "${etc_after}"

begin "--dry-run: --channels pisa las rutas default"
run_capture bash "${INSTALLER}" --dry-run --yes \
  --address '10.0.0.9' --dvr-host '10.0.0.5' --dvr-user 'admin' \
  --password-file "${PWFILE}" --channels '/custom/1,/custom/2,/custom/3,/custom/4'
assert_eq "exit 0" "0" "${RC}"
assert_contains "canal 1 custom" "${OUT}" 'cam1: "rtsp://admin:****@10.0.0.5:554/custom/1"'
assert_contains "canal 4 custom" "${OUT}" 'cam4: "rtsp://admin:****@10.0.0.5:554/custom/4"'
assert_not_contains "sin ruta Hikvision" "${OUT}" 'Streaming/Channels'

begin "--channels con cantidad incorrecta se rechaza"
run_capture bash "${INSTALLER}" --dry-run --yes \
  --address '10.0.0.9' --dvr-host '10.0.0.5' --dvr-user 'admin' \
  --password-file "${PWFILE}" --channels '/a,/b,/c'
assert_eq "exit 2" "2" "${RC}"
assert_contains "4 rutas" "${ERR}" '4 rutas'

begin "validación: dirección IPv4 inválida"
run_capture bash "${INSTALLER}" --dry-run --yes \
  --address '999.1.1.1' --dvr-host '10.0.0.5' --dvr-user 'admin' \
  --password-file "${PWFILE}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "razón" "${ERR}" 'dirección inválida'
assert_not_contains "no renderiza" "${OUT}" 'cam1:'

begin "validación: host del DVR con scheme"
run_capture bash "${INSTALLER}" --dry-run --yes \
  --address '10.0.0.9' --dvr-host 'rtsp://10.0.0.5' --dvr-user 'admin' \
  --password-file "${PWFILE}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "razón" "${ERR}" 'host del DVR inválido'

begin "validación: falta --dvr-host sin TTY"
run_capture bash "${INSTALLER}" --dry-run --yes \
  --address '10.0.0.9' --dvr-user 'admin' --password-file "${PWFILE}"
assert_eq "exit 2" "2" "${RC}"
assert_contains "falta --dvr-host" "${ERR}" 'falta --dvr-host'
assert_contains "sin TTY" "${ERR}" 'sin TTY'

begin "validación: archivo de contraseña con modo 0644"
run_capture bash "${INSTALLER}" --dry-run --yes \
  --address '10.0.0.9' --dvr-host '10.0.0.5' --dvr-user 'admin' \
  --password-file "${WORK_DIR}/perm644.pw"
assert_eq "exit 2" "2" "${RC}"
assert_contains "modo 0600" "${ERR}" '0600'

begin "validación: archivo de contraseña symlink"
run_capture bash "${INSTALLER}" --dry-run --yes \
  --address '10.0.0.9' --dvr-host '10.0.0.5' --dvr-user 'admin' \
  --password-file "${WORK_DIR}/link.pw"
assert_eq "exit 2" "2" "${RC}"
assert_contains "enlace" "${ERR}" 'enlace'

begin "DVR_PASSWORD del entorno se avisa y se ignora"
set +e
OUT="$(env DVR_PASSWORD='envsecret123' bash "${INSTALLER}" --dry-run --yes \
  --address '10.0.0.9' --dvr-host '10.0.0.5' --dvr-user 'admin' \
  --password-file "${PWFILE}" </dev/null 2>"${WORK_DIR}/stderr")"
RC=$?
set -e
ERR="$(<"${WORK_DIR}/stderr")"
assert_eq "exit 0" "0" "${RC}"
assert_contains "aviso DVR_PASSWORD" "${ERR}" 'DVR_PASSWORD'
assert_not_contains "valor de entorno no se usó" "${OUT}${ERR}" 'envsecret123'

begin "detect_address usa el src de la ruta por defecto"
route_src="$(parse_route_src "$(ip -4 route get 1.1.1.1 2>/dev/null || true)")"
detected="$(detect_address)"
if [[ -n "${route_src}" ]]; then
  assert_eq "src de ip route" "${route_src}" "${detected}"
else
  assert_contains "fallback hostname -I" "$(hostname -I 2>/dev/null)" "${detected}"
fi

printf '\n== escritura atómica + .prev (D6) ==\n'

begin "write_config_atomic: sandbox con chown stubbeado (no root)"
sandbox="${WORK_DIR}/sandbox"
mkdir -p "${sandbox}"
# Único punto root-only del camino de escritura: se reemplaza por un no-op.
# Todo lo demás (mktemp, chmod, cp, mv) corre de verdad contra el sandbox.
chown() { :; }
CONFIG_DIR="${sandbox}"
CONFIG_PATH="${sandbox}/go2rtc.yaml"
PREV_PATH="${CONFIG_PATH}.prev"
LXC_ADDRESS='10.0.0.9'
DVR_HOST='10.0.0.5'
DVR_USER='admin'
DVR_PASSWORD='p@ss word'
CHANNEL_PATHS=(
  '/Streaming/Channels/101'
  '/Streaming/Channels/201'
  '/Streaming/Channels/301'
  '/Streaming/Channels/401'
)

write_config_atomic >/dev/null

assert_eq "config creada" "1" "$([[ -f "${CONFIG_PATH}" ]] && echo 1 || echo 0)"
assert_eq "modo 0600" "600" "$(stat -c '%a' -- "${CONFIG_PATH}")"
assert_eq "sin .prev en el primer run" "0" "$([[ -e "${PREV_PATH}" ]] && echo 1 || echo 0)"
assert_contains "usuario encodeado" "$(<"${CONFIG_PATH}")" 'rtsp://admin:p%40ss%20word@10.0.0.5:554/Streaming/Channels/101'
assert_not_contains "contraseña raw ausente del YAML" "$(<"${CONFIG_PATH}")" 'p@ss word'
assert_not_contains "máscara ausente del YAML real" "$(<"${CONFIG_PATH}")" ':****@'
assert_eq "sin temporales huérfanos" "" \
  "$(find "${sandbox}" -maxdepth 1 -name '.go2rtc.yaml.*' -print -quit)"

begin "write_config_atomic: el re-run copia el anterior a .prev"
DVR_PASSWORD='nuevo secreto'
write_config_atomic >/dev/null

assert_eq ".prev creado" "1" "$([[ -f "${PREV_PATH}" ]] && echo 1 || echo 0)"
assert_eq ".prev modo 0600" "600" "$(stat -c '%a' -- "${PREV_PATH}")"
assert_contains ".prev conserva la credencial vieja" "$(<"${PREV_PATH}")" 'p%40ss%20word'
assert_contains "config nueva con la credencial nueva" "$(<"${CONFIG_PATH}")" 'nuevo%20secreto'
assert_not_contains "config nueva ya no tiene la vieja" "$(<"${CONFIG_PATH}")" 'p%40ss%20word'
assert_eq "sin temporales huérfanos tras el re-run" "" \
  "$(find "${sandbox}" -maxdepth 1 -name '.go2rtc.yaml.*' -print -quit)"

begin "restart_and_verify: fallo del servicio -> exit 1 + logs + rollback"
systemctl() { return 1; } # stub: el servicio nunca queda activo
sleep() { :; }
curl() { return 1; }

set +e
OUT="$(restart_and_verify 2>"${WORK_DIR}/stderr")"
RC=$?
set -e
ERR="$(<"${WORK_DIR}/stderr")"
assert_eq "exit 1" "1" "${RC}"
assert_contains "comando de logs" "${ERR}" 'journalctl -u go2rtc -n 50 --no-pager'
assert_contains "comando de rollback" "${ERR}" \
  "cp ${PREV_PATH} ${CONFIG_PATH} && systemctl restart go2rtc"
assert_not_contains "no reporta éxito" "${OUT}" 'Provisioning completo.'

begin "restart_and_verify: éxito -> exit 0 + UI + siguiente paso"
systemctl() { return 0; } # stub: queda activo al primer chequeo
curl() { return 0; }      # stub: la API local responde

set +e
OUT="$(restart_and_verify 2>"${WORK_DIR}/stderr")"
RC=$?
set -e
ERR="$(<"${WORK_DIR}/stderr")"
assert_eq "exit 0" "0" "${RC}"
assert_contains "éxito" "${OUT}" 'Provisioning completo.'
assert_contains "servicio activo" "${OUT}" 'Servicio: go2rtc activo'
assert_contains "UI con la IP publicada" "${OUT}" 'http://10.0.0.9:1984/'
assert_contains "siguiente paso" "${OUT}" './deploy/deploy-frontend.sh 10.0.0.9'
assert_eq "sin ruido de error en stderr" "" "${ERR}"

printf '\n\033[1;32mOK\033[0m: %d assertions pasaron.\n' "${CASES}"
