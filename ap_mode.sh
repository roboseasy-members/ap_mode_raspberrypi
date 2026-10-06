#!/usr/bin/env bash
# ============================================================
# ap_mode.sh — 라즈베리파이 와이파이 AP(핫스팟) 모드 전환 도구
# ============================================================
# Ubuntu Server(netplan) 라즈베리파이의 wlan0을 AP 모드로 바꾸거나
# 일반 와이파이(클라이언트)로 되돌린다. 인자 없이 실행하면 텍스트 UI,
# 인자를 주면 비대화식으로 동작한다.
#
#   ./ap_mode.sh  (또는 bash ap_mode.sh)      # 텍스트 UI — sudo 자동
#   sudo ./ap_mode.sh                         # 텍스트 UI (whiptail)
#   sudo ./ap_mode.sh start --ssid S --password P [--band 2.4GHz|5GHz]
#        [--channel N] [--address 192.168.4.1/24] [--no-autostart]
#   sudo ./ap_mode.sh stop [--ssid S --password P]
#   sudo ./ap_mode.sh status
#   sudo ./ap_mode.sh install                 # 필요 패키지만 설치
#
# 동작 원리:
#   - netplan이 단일 출처다. AP는 wlan0만 NetworkManager 렌더러 +
#     `mode: ap`로 선언하고, eth0은 networkd DHCP를 유지한다(유선 복구용).
#   - 부팅 시 자동 시작 = /etc/netplan/50-cloud-init.yaml에 AP 설정.
#     이번 부팅만 = /run/netplan/50-cloud-init.yaml(같은 이름이 /etc를
#     가리고, /run은 재부팅 시 비워짐)에 AP 설정.
#   - 적용·검증·원복은 systemd 서비스로 분리 실행한다 - 와이파이 SSH로
#     실행 중이어도 세션이 끊기는 순간 스크립트가 같이 죽지 않게 한다.
#     AP(또는 일반 와이파이)가 제한 시간 안에 안 뜨면 직전 설정으로
#     자동 원복한다.

# `sh ap_mode.sh`처럼 bash가 아닌 셸로 실행되면 bash로 다시 실행한다
# (이 블록은 dash도 해석할 수 있는 POSIX 문법만 쓴다).
if [ -z "${BASH_VERSION:-}" ]; then
	exec bash "$0" "$@"
fi
set -u

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
readonly WIFI_INTERFACE='wlan0'
readonly NETPLAN_FILE='/etc/netplan/50-cloud-init.yaml'
readonly RUNTIME_NETPLAN_DIR='/run/netplan'
readonly RUNTIME_NETPLAN_FILE="${RUNTIME_NETPLAN_DIR}/50-cloud-init.yaml"
readonly STATE_DIR='/etc/ap_mode_raspberrypi'
readonly CLIENT_BACKUP_FILE="${STATE_DIR}/client_netplan.yaml"
readonly RUN_DIR='/run/ap_mode_raspberrypi'
readonly JOB_FILE="${RUN_DIR}/job.env"
readonly RESULT_FILE="${RUN_DIR}/result"
readonly PREVIOUS_ETC_FILE="${RUN_DIR}/previous_etc.yaml"
readonly PREVIOUS_RUNTIME_FILE="${RUN_DIR}/previous_runtime.yaml"
readonly LOG_FILE='/var/log/ap_mode_raspberrypi.log'
readonly CLOUD_INIT_LOCK_FILE='/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg'
readonly DEFAULT_AP_ADDRESS='192.168.4.1/24'
readonly DEFAULT_BAND='2.4GHz'
readonly DEFAULT_CHANNEL_2G=6
readonly DEFAULT_CHANNEL_5G=36
readonly VERIFY_TIMEOUT_S=30
readonly RESULT_WAIT_S=100
readonly TUI_TITLE='Raspberry Pi AP Mode'

# ------------------------------------------------------------
# 공통 유틸
# ------------------------------------------------------------
log() {
	printf '[ap_mode] %s\n' "$*"
	printf '%s [ap_mode] %s\n' "$(date '+%F %T')" "$*" >>"${LOG_FILE}" 2>/dev/null || true
}

die() {
	printf '[ap_mode] error: %s\n' "$*" >&2
	exit 1
}

has_command() {
	command -v "$1" >/dev/null 2>&1
}

require_root() {
	if [ "${EUID}" -ne 0 ]; then
		exec sudo bash "${SCRIPT_PATH}" "$@"
	fi
}

check_wifi_interface() {
	[ -d "/sys/class/net/${WIFI_INTERFACE}" ] \
		|| die "${WIFI_INTERFACE} not found - this device has no Wi-Fi interface."
}

# YAML 큰따옴표 문자열 안에서 깨지지 않도록 \ 와 " 를 이스케이프한다.
yaml_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# ------------------------------------------------------------
# 의존성 / 하드웨어 점검
# ------------------------------------------------------------
missing_packages() {
	local missing=()
	has_command iw || missing+=('iw')
	has_command nmcli || missing+=('network-manager')
	dpkg -s dnsmasq-base >/dev/null 2>&1 || missing+=('dnsmasq-base')
	# 빈 배열을 printf하면 빈 줄 1개가 항목으로 읽히므로 있을 때만 출력한다.
	if [ "${#missing[@]}" -gt 0 ]; then
		printf '%s\n' "${missing[@]}"
	fi
}

# 순정 Ubuntu raspi 이미지는 apt 소스에 <codename>-updates가 빠져 있어
# 의존성 설치가 'held broken packages'로 실패할 수 있다 - 보정한다.
fix_apt_sources() {
	local sources_file='/etc/apt/sources.list.d/ubuntu.sources'
	local codename
	[ -f "${sources_file}" ] || return 0
	codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
	[ -n "${codename}" ] || return 0
	if grep -qE "^Suites: ${codename}\$" "${sources_file}"; then
		sed -i "s/^Suites: ${codename}\$/Suites: ${codename} ${codename}-updates/" "${sources_file}"
		log "apt sources: added ${codename}-updates"
	fi
}

install_dependencies() {
	local packages
	mapfile -t packages < <(missing_packages)
	if [ "${#packages[@]}" -eq 0 ]; then
		log 'dependencies already installed'
		return 0
	fi
	log "installing: ${packages[*]} (internet required)"
	fix_apt_sources
	apt-get update -qq || die 'apt-get update failed - connect to the internet (Wi-Fi or Ethernet) first.'
	DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
		"${packages[@]}" wpasupplicant \
		|| die "package install failed: ${packages[*]}"
	log 'dependencies installed'
}

has_ap_support() {
	iw list 2>/dev/null | grep -qE '^[[:space:]]+\* AP$'
}

# ------------------------------------------------------------
# 입력 검증
# ------------------------------------------------------------
validate_ssid() {
	local byte_count
	byte_count="$(printf '%s' "$1" | wc -c)"
	[ "${byte_count}" -ge 1 ] && [ "${byte_count}" -le 32 ]
}

# WPA2 패스프레이즈: 출력 가능한 ASCII 8~63자.
validate_password() {
	local non_ascii_count
	[ "${#1}" -ge 8 ] && [ "${#1}" -le 63 ] || return 1
	non_ascii_count="$(printf '%s' "$1" | LC_ALL=C tr -d '\040-\176' | wc -c)"
	[ "${non_ascii_count}" -eq 0 ]
}

validate_band() {
	[ "$1" = '2.4GHz' ] || [ "$1" = '5GHz' ]
}

# 한국(KR) 기준: 2.4GHz 1~13, 5GHz는 DFS가 없는 채널만 허용.
validate_channel() {
	local band="$1" channel="$2"
	[[ "${channel}" =~ ^[0-9]+$ ]] || return 1
	if [ "${band}" = '2.4GHz' ]; then
		[ "${channel}" -ge 1 ] && [ "${channel}" -le 13 ]
	else
		case "${channel}" in
			36|40|44|48|149|153|157|161) return 0 ;;
			*) return 1 ;;
		esac
	fi
}

validate_address() {
	local ip_part prefix octet
	[[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] || return 1
	ip_part="${1%/*}"
	prefix="${1#*/}"
	[ "${prefix}" -ge 8 ] && [ "${prefix}" -le 30 ] || return 1
	for octet in ${ip_part//./ }; do
		[ "${octet}" -le 255 ] || return 1
	done
}

ip_to_int() {
	local first second third fourth
	IFS=. read -r first second third fourth <<<"$1"
	printf '%s' "$(( (first << 24) | (second << 16) | (third << 8) | fourth ))"
}

# 두 CIDR이 겹치면 0을 반환한다 (짧은 prefix 기준 네트워크 비교).
is_subnet_overlap() {
	local prefix_a="${1#*/}" prefix_b="${2#*/}" prefix mask
	prefix=$(( prefix_a < prefix_b ? prefix_a : prefix_b ))
	mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
	[ $(( $(ip_to_int "${1%/*}") & mask )) -eq $(( $(ip_to_int "${2%/*}") & mask )) ]
}

# AP 대역이 다른 인터페이스(예: 노트북 유선 공유 10.42.0.x)와 겹치면
# 라우팅이 꼬이므로 거부한다.
check_address_conflict() {
	local address="$1" interface_name other_cidr
	while read -r interface_name other_cidr; do
		if is_subnet_overlap "${address}" "${other_cidr}"; then
			die "AP subnet ${address} overlaps ${interface_name} (${other_cidr}). Use another --address."
		fi
	done < <(ip -4 -o addr show | awk -v wifi="${WIFI_INTERFACE}" '$2 != "lo" && $2 != wifi {print $2, $4}')
}

# ------------------------------------------------------------
# netplan 설정 읽기/쓰기
# ------------------------------------------------------------
is_ap_config() {
	[ -f "$1" ] && grep -qE '^[[:space:]]+mode:[[:space:]]*ap[[:space:]]*$' "$1"
}

# 설정 파일의 첫 번째 access-point SSID (표시용, 이스케이프 미해제).
ssid_from_config() {
	[ -f "$1" ] || return 0
	grep -A1 'access-points:' "$1" | tail -1 \
		| sed -E 's/^[[:space:]]*"?(.*[^"])"?:[[:space:]]*$/\1/'
}

current_mode() {
	if is_ap_config "${RUNTIME_NETPLAN_FILE}"; then
		printf 'temporary'
	elif is_ap_config "${NETPLAN_FILE}"; then
		printf 'autostart'
	else
		printf 'client'
	fi
}

mode_description() {
	case "$1" in
		temporary) printf 'AP mode (until next reboot)' ;;
		autostart) printf 'AP mode (starts on every boot)' ;;
		*) printf 'Normal Wi-Fi (client)' ;;
	esac
}

# 보안은 WPA2 전용(RSN/CCMP)으로 고정한다 - 지정하지 않으면 NM이 brcmfmac
# AP를 WPA1(TKIP)로 광고해 최신 기기가 접속을 거부한다(실측). PMF는
# brcmfmac AP 호환을 위해 끈다(pmf=1).
write_ap_netplan() {
	local target_file="$1" ssid="$2" password="$3" band="$4" channel="$5" address="$6"
	local ssid_yaml password_yaml
	ssid_yaml="$(yaml_escape "${ssid}")"
	password_yaml="$(yaml_escape "${password}")"
	mkdir -p "$(dirname "${target_file}")"
	(
		umask 077
		printf '%s\n' \
			'# Generated by ap_mode_raspberrypi (Wi-Fi access point mode)' \
			'network:' \
			'  version: 2' \
			'  ethernets:' \
			'    eth0:' \
			'      optional: true' \
			'      dhcp4: true' \
			'  wifis:' \
			"    ${WIFI_INTERFACE}:" \
			'      renderer: NetworkManager' \
			'      optional: true' \
			"      addresses: [${address}]" \
			'      regulatory-domain: "KR"' \
			'      access-points:' \
			"        \"${ssid_yaml}\":" \
			'          mode: ap' \
			"          password: \"${password_yaml}\"" \
			"          band: ${band}" \
			"          channel: ${channel}" \
			'          networkmanager:' \
			'            passthrough:' \
			'              wifi-security.proto: "rsn"' \
			'              wifi-security.pairwise: "ccmp"' \
			'              wifi-security.group: "ccmp"' \
			'              wifi-security.pmf: "1"' \
			>"${target_file}"
	)
	chmod 600 "${target_file}"
}

write_client_netplan() {
	local target_file="$1" ssid="$2" password="$3"
	local ssid_yaml password_yaml
	ssid_yaml="$(yaml_escape "${ssid}")"
	password_yaml="$(yaml_escape "${password}")"
	(
		umask 077
		printf '%s\n' \
			'# Generated by ap_mode_raspberrypi (normal Wi-Fi client, DHCP)' \
			'network:' \
			'  version: 2' \
			'  ethernets:' \
			'    eth0:' \
			'      optional: true' \
			'      dhcp4: true' \
			'  wifis:' \
			"    ${WIFI_INTERFACE}:" \
			'      optional: true' \
			'      dhcp4: true' \
			'      regulatory-domain: "KR"' \
			'      access-points:' \
			"        \"${ssid_yaml}\":" \
			"          password: \"${password_yaml}\"" \
			>"${target_file}"
	)
	chmod 600 "${target_file}"
}

# 현재 /etc 설정이 일반 와이파이면 AP 끄기 때 되돌릴 수 있게 저장한다.
backup_client_config() {
	if [ -f "${NETPLAN_FILE}" ] && ! is_ap_config "${NETPLAN_FILE}"; then
		mkdir -p "${STATE_DIR}"
		chmod 700 "${STATE_DIR}"
		cp "${NETPLAN_FILE}" "${CLIENT_BACKUP_FILE}"
		chmod 600 "${CLIENT_BACKUP_FILE}"
	fi
}

# cloud-init이 재부팅 시 50-cloud-init.yaml을 다시 쓰지 못하게 잠근다.
lock_cloud_init_network() {
	if [ -d /etc/cloud/cloud.cfg.d ] && [ ! -f "${CLOUD_INIT_LOCK_FILE}" ]; then
		printf '%s\n' 'network: {config: disabled}' >"${CLOUD_INIT_LOCK_FILE}"
		log 'cloud-init network config locked'
	fi
}

# ------------------------------------------------------------
# 상태 확인
# ------------------------------------------------------------
wifi_ipv4() {
	ip -4 -o addr show "${WIFI_INTERFACE}" 2>/dev/null | awk '{print $4}' | head -1
}

is_ap_running() {
	local ssid="$1" address="$2" live_info
	live_info="$(iw dev "${WIFI_INTERFACE}" info 2>/dev/null)"
	grep -q 'type AP' <<<"${live_info}" || return 1
	[ "$(sed -n 's/^[[:space:]]*ssid //p' <<<"${live_info}")" = "${ssid}" ] || return 1
	ip -4 -o addr show "${WIFI_INTERFACE}" | grep -q " ${address%/*}/"
}

# 원복 후 확인용: AP든 클라이언트든 와이파이가 다시 동작하면 0.
is_wifi_restored() {
	iw dev "${WIFI_INTERFACE}" info 2>/dev/null | grep -q 'type AP' \
		&& [ -n "$(wifi_ipv4)" ] && return 0
	is_client_connected
}

is_client_connected() {
	iw dev "${WIFI_INTERFACE}" link 2>/dev/null | grep -q '^Connected' \
		&& [ -n "$(wifi_ipv4)" ]
}

status_text() {
	local mode live_info live_type live_ssid station_count eth_address
	mode="$(current_mode)"
	live_info="$(iw dev "${WIFI_INTERFACE}" info 2>/dev/null)"
	live_type="$(sed -n 's/^[[:space:]]*type //p' <<<"${live_info}")"
	live_ssid="$(sed -n 's/^[[:space:]]*ssid //p' <<<"${live_info}")"
	eth_address="$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | head -1)"
	printf 'Configured : %s\n' "$(mode_description "${mode}")"
	printf 'Wi-Fi now  : type=%s ssid=%s\n' "${live_type:-?}" "${live_ssid:-(none)}"
	printf 'wlan0 IPv4 : %s\n' "$(wifi_ipv4)"
	if [ "${live_type}" = 'AP' ]; then
		station_count="$(iw dev "${WIFI_INTERFACE}" station dump 2>/dev/null | grep -c '^Station')"
		printf 'Clients    : %s connected\n' "${station_count}"
	fi
	printf 'eth0 IPv4  : %s\n' "${eth_address:-(not connected)}"
	if [ -f "${CLIENT_BACKUP_FILE}" ]; then
		printf 'Saved Wi-Fi: %s\n' "$(ssid_from_config "${CLIENT_BACKUP_FILE}")"
	fi
}

# ------------------------------------------------------------
# 적용 워커 (systemd 서비스로 분리 실행)
# ------------------------------------------------------------
write_result() {
	printf '%s\n%s\n' "$1" "$2" >"${RESULT_FILE}"
	log "result: $1 - $2"
}

snapshot_previous_config() {
	rm -f "${PREVIOUS_ETC_FILE}" "${PREVIOUS_RUNTIME_FILE}"
	[ -f "${NETPLAN_FILE}" ] && cp -p "${NETPLAN_FILE}" "${PREVIOUS_ETC_FILE}"
	[ -f "${RUNTIME_NETPLAN_FILE}" ] && cp -p "${RUNTIME_NETPLAN_FILE}" "${PREVIOUS_RUNTIME_FILE}"
	return 0
}

# 직전 설정으로 되돌리고 와이파이가 다시 동작하는지 확인한다.
# 결과 문구를 출력한다 (실패 메시지에 덧붙이는 용도).
restore_previous_config() {
	if [ -f "${PREVIOUS_ETC_FILE}" ]; then
		cp -p "${PREVIOUS_ETC_FILE}" "${NETPLAN_FILE}"
	fi
	if [ -f "${PREVIOUS_RUNTIME_FILE}" ]; then
		mkdir -p "${RUNTIME_NETPLAN_DIR}"
		cp -p "${PREVIOUS_RUNTIME_FILE}" "${RUNTIME_NETPLAN_FILE}"
	else
		rm -f "${RUNTIME_NETPLAN_FILE}"
	fi
	netplan apply
	if wait_until is_wifi_restored; then
		printf 'restored previous config (%s, wlan0 %s)' \
			"$(mode_description "$(current_mode)")" "$(wifi_ipv4)"
	else
		printf 'restored previous config, but Wi-Fi is still down - use Ethernet to recover'
	fi
}

wait_until() {
	local check_name="$1" seconds
	shift
	for (( seconds = 0; seconds < VERIFY_TIMEOUT_S; seconds++ )); do
		if "${check_name}" "$@"; then
			return 0
		fi
		sleep 1
	done
	return 1
}

run_worker() {
	# shellcheck source=/dev/null
	. "${JOB_FILE}"
	rm -f "${JOB_FILE}"
	snapshot_previous_config

	case "${JOB_ACTION}" in
		start)
			backup_client_config
			if [ "${JOB_IS_AUTOSTART}" = 'true' ]; then
				rm -f "${RUNTIME_NETPLAN_FILE}"
				write_ap_netplan "${NETPLAN_FILE}" "${JOB_SSID}" "${JOB_PASSWORD}" \
					"${JOB_BAND}" "${JOB_CHANNEL}" "${JOB_ADDRESS}"
				lock_cloud_init_network
			else
				write_ap_netplan "${RUNTIME_NETPLAN_FILE}" "${JOB_SSID}" "${JOB_PASSWORD}" \
					"${JOB_BAND}" "${JOB_CHANNEL}" "${JOB_ADDRESS}"
			fi
			if ! netplan generate; then
				write_result FAIL "netplan rejected the AP config - $(restore_previous_config)."
				return 1
			fi
			netplan apply
			if wait_until is_ap_running "${JOB_SSID}" "${JOB_ADDRESS}"; then
				write_result OK "AP '${JOB_SSID}' is up. Connect and use ${JOB_ADDRESS%/*}"
			else
				write_result FAIL "AP did not come up within ${VERIFY_TIMEOUT_S}s - $(restore_previous_config)."
				return 1
			fi
			;;
		stop)
			rm -f "${RUNTIME_NETPLAN_FILE}"
			if [ -n "${JOB_SSID}" ]; then
				write_client_netplan "${NETPLAN_FILE}" "${JOB_SSID}" "${JOB_PASSWORD}"
			elif is_ap_config "${NETPLAN_FILE}"; then
				if [ -f "${CLIENT_BACKUP_FILE}" ]; then
					cp -p "${CLIENT_BACKUP_FILE}" "${NETPLAN_FILE}"
				else
					write_result FAIL "No saved Wi-Fi config - give --ssid and --password ($(restore_previous_config))."
					return 1
				fi
			fi
			netplan apply
			if wait_until is_client_connected; then
				write_result OK "Connected as Wi-Fi client. wlan0 address: $(wifi_ipv4)"
			else
				write_result FAIL "Wi-Fi did not connect within ${VERIFY_TIMEOUT_S}s (check SSID/password) - $(restore_previous_config)."
				return 1
			fi
			;;
		*)
			write_result FAIL "unknown job action: ${JOB_ACTION}"
			return 1
			;;
	esac
}

# 작업 내용을 파일로 넘기고 워커를 systemd 서비스로 띄운 뒤 결과를 기다린다.
launch_worker() {
	local action="$1" ssid="$2" password="$3" band="$4" channel="$5" address="$6" is_autostart="$7"
	local waited_seconds status_line message_line
	mkdir -p "${RUN_DIR}"
	chmod 700 "${RUN_DIR}"
	rm -f "${RESULT_FILE}"
	(
		umask 077
		{
			printf 'JOB_ACTION=%q\n' "${action}"
			printf 'JOB_SSID=%q\n' "${ssid}"
			printf 'JOB_PASSWORD=%q\n' "${password}"
			printf 'JOB_BAND=%q\n' "${band}"
			printf 'JOB_CHANNEL=%q\n' "${channel}"
			printf 'JOB_ADDRESS=%q\n' "${address}"
			printf 'JOB_IS_AUTOSTART=%q\n' "${is_autostart}"
		} >"${JOB_FILE}"
	)
	systemd-run --quiet --collect --unit "ap_mode_worker_$$" /bin/bash "${SCRIPT_PATH}" __worker \
		|| die 'failed to start the worker service (systemd-run).'

	log 'applying... (if you are on Wi-Fi SSH, the session may drop - this is expected)'
	for (( waited_seconds = 0; waited_seconds < RESULT_WAIT_S; waited_seconds++ )); do
		if [ -f "${RESULT_FILE}" ]; then
			status_line="$(sed -n 1p "${RESULT_FILE}")"
			message_line="$(sed -n 2p "${RESULT_FILE}")"
			LAST_RESULT_MESSAGE="${message_line}"
			[ "${status_line}" = 'OK' ]
			return
		fi
		sleep 1
	done
	LAST_RESULT_MESSAGE="No result after ${RESULT_WAIT_S}s - check: sudo journalctl -u ap_mode_worker_$$ / ${LOG_FILE}"
	return 1
}

# ------------------------------------------------------------
# 동작 (UI/CLI 공용)
# ------------------------------------------------------------
LAST_RESULT_MESSAGE=''

validate_start_inputs() {
	local ssid="$1" password="$2" band="$3" channel="$4" address="$5"
	validate_ssid "${ssid}" || die 'SSID must be 1-32 bytes.'
	validate_password "${password}" || die 'password must be 8-63 printable ASCII characters.'
	validate_band "${band}" || die "band must be 2.4GHz or 5GHz (got: ${band})."
	validate_channel "${band}" "${channel}" || die "invalid channel ${channel} for ${band}."
	validate_address "${address}" || die "invalid --address ${address} (expected e.g. 192.168.4.1/24)."
	check_address_conflict "${address}"
}

do_start() {
	local ssid="$1" password="$2" band="$3" channel="$4" address="$5" is_autostart="$6"
	validate_start_inputs "${ssid}" "${password}" "${band}" "${channel}" "${address}"
	has_ap_support || die "${WIFI_INTERFACE} does not report AP mode support (iw list)."
	launch_worker start "${ssid}" "${password}" "${band}" "${channel}" "${address}" "${is_autostart}"
}

do_stop() {
	local ssid="$1" password="$2"
	if [ -n "${ssid}" ]; then
		validate_ssid "${ssid}" || die 'SSID must be 1-32 bytes.'
		validate_password "${password}" || die 'password must be 8-63 printable ASCII characters.'
	elif [ "$(current_mode)" = 'client' ]; then
		LAST_RESULT_MESSAGE='Already in normal Wi-Fi mode - nothing to do.'
		return 0
	fi
	launch_worker stop "${ssid}" "${password}" '' '' '' 'false'
}

# 전환 직전에 접속 정보를 터미널에 남긴다 - 와이파이 SSH가 끊겨도
# 화면에 남아 있어 새 IP를 알 수 있다.
print_ap_connection_info() {
	local ssid="$1" address="$2" login_user
	login_user="${SUDO_USER:-$(id -un)}"
	printf '\n%s\n' '=================================================='
	printf ' AP mode will start now\n'
	printf '   Wi-Fi name (SSID) : %s\n' "${ssid}"
	printf '   Pi IP address     : %s\n' "${address%/*}"
	printf '   Connect           : join "%s", then\n' "${ssid}"
	printf '                       ssh %s@%s\n' "${login_user}" "${address%/*}"
	printf '%s\n\n' '=================================================='
}

is_ssh_over_wifi() {
	local server_ip
	server_ip="$(awk '{print $3}' <<<"${SSH_CONNECTION:-}")"
	[ -n "${server_ip}" ] && ip -4 -o addr show "${WIFI_INTERFACE}" | grep -q " ${server_ip}/"
}

# ------------------------------------------------------------
# 텍스트 UI (whiptail)
# ------------------------------------------------------------
tui() {
	whiptail --title "${TUI_TITLE}" "$@" 3>&1 1>&2 2>&3
}

# 항상 터미널(/dev/tty)에 그린다 - $( ) 안에서 불리면 화면이 캡처돼
# 안 보인 채 Enter만 기다리는(멈춘 것처럼 보이는) 버그가 있었다.
tui_message() {
	whiptail --title "${TUI_TITLE}" --msgbox "$1" 16 72 >/dev/tty
}

tui_ensure_dependencies() {
	local packages
	mapfile -t packages < <(missing_packages)
	[ "${#packages[@]}" -eq 0 ] && return 0
	tui --yesno "Required packages are missing:\n\n  ${packages[*]}\n\nInstall them now? (internet required)" 12 64 || return 1
	clear
	install_dependencies
}

# 결과는 TUI_PASSWORD에 담는다 (취소하면 1). 잘못 입력하면 경고 후
# 다시 묻는다 - 서브셸 캡처를 쓰지 않아 경고창이 화면에 그대로 뜬다.
TUI_PASSWORD=''
tui_read_password() {
	local first second
	TUI_PASSWORD=''
	while true; do
		first="$(tui --passwordbox "$1\n(8-63 characters)" 10 64)" || return 1
		if ! validate_password "${first}"; then
			tui_message "Invalid password (${#first} characters).\n\nUse 8-63 characters (letters, numbers, symbols).\nPress OK and type it again."
			continue
		fi
		second="$(tui --passwordbox 'Type the password again' 10 64)" || return 1
		if [ "${first}" != "${second}" ]; then
			tui_message 'Passwords do not match.\n\nPress OK and type it again.'
			continue
		fi
		TUI_PASSWORD="${first}"
		return 0
	done
}

tui_start() {
	local ssid password band channel is_autostart autostart_label summary
	tui_ensure_dependencies || return 0
	if ! has_ap_support; then
		tui_message "${WIFI_INTERFACE} does not report AP mode support (iw list)."
		return 0
	fi
	while true; do
		ssid="$(tui --inputbox 'AP Wi-Fi name (SSID)' 10 64 "$(hostname)")" || return 0
		validate_ssid "${ssid}" && break
		tui_message 'SSID must be 1-32 bytes.'
	done
	tui_read_password 'AP Wi-Fi password' || return 0
	password="${TUI_PASSWORD}"
	band="$(tui --menu 'Wi-Fi band' 12 64 2 \
		'2.4GHz' 'most compatible (channel 6)' \
		'5GHz' 'less crowded (channel 36)')" || return 0
	if [ "${band}" = '2.4GHz' ]; then
		channel="${DEFAULT_CHANNEL_2G}"
	else
		channel="${DEFAULT_CHANNEL_5G}"
	fi
	if tui --yesno 'Start the AP automatically on every boot?\n\n  Yes = AP mode survives reboot\n  No  = AP mode only until the next reboot\n        (normal Wi-Fi comes back after reboot)' 13 64; then
		is_autostart='true'
		autostart_label='yes (every boot)'
	else
		is_autostart='false'
		autostart_label='no (until next reboot)'
	fi
	summary="SSID      : ${ssid}\nBand      : ${band} (channel ${channel})\nAP address: ${DEFAULT_AP_ADDRESS%/*}\nAutostart : ${autostart_label}\n\nThe Pi will stop using normal Wi-Fi (no Wi-Fi internet)."
	if is_ssh_over_wifi; then
		summary="${summary}\n\n!! You are connected over Wi-Fi SSH - the session WILL drop.\n   Reconnect: join '${ssid}', then ssh to ${DEFAULT_AP_ADDRESS%/*}"
	fi
	tui --yesno "${summary}\n\nApply now?" 20 72 || return 0
	clear
	print_ap_connection_info "${ssid}" "${DEFAULT_AP_ADDRESS}"
	if do_start "${ssid}" "${password}" "${band}" "${channel}" "${DEFAULT_AP_ADDRESS}" "${is_autostart}"; then
		tui_message "OK: ${LAST_RESULT_MESSAGE}\n\n$(status_text)"
	else
		tui_message "FAIL: ${LAST_RESULT_MESSAGE}"
	fi
}

tui_stop() {
	local mode saved_ssid choice ssid='' password=''
	mode="$(current_mode)"
	if [ "${mode}" = 'client' ]; then
		tui_message 'Already in normal Wi-Fi mode.'
		return 0
	fi
	saved_ssid="$(ssid_from_config "${CLIENT_BACKUP_FILE}")"
	if [ "${mode}" = 'temporary' ]; then
		saved_ssid="$(ssid_from_config "${NETPLAN_FILE}")"
	fi
	if [ -n "${saved_ssid}" ]; then
		choice="$(tui --menu 'Return to normal Wi-Fi' 12 72 2 \
			'previous' "reconnect to saved Wi-Fi '${saved_ssid}'" \
			'new' 'enter a different Wi-Fi')" || return 0
	else
		choice='new'
	fi
	if [ "${choice}" = 'new' ]; then
		while true; do
			ssid="$(tui --inputbox 'Wi-Fi name (SSID) to join' 10 64)" || return 0
			validate_ssid "${ssid}" && break
			tui_message 'SSID must be 1-32 bytes.'
		done
		tui_read_password 'Wi-Fi password' || return 0
		password="${TUI_PASSWORD}"
	fi
	tui --yesno 'Turn off AP mode and return to normal Wi-Fi now?\n\nAP clients (and an SSH session over the AP) will disconnect.' 12 68 || return 0
	clear
	if do_stop "${ssid}" "${password}"; then
		tui_message "OK: ${LAST_RESULT_MESSAGE}"
	else
		tui_message "FAIL: ${LAST_RESULT_MESSAGE}"
	fi
}

tui_main() {
	local choice
	has_command whiptail || die 'whiptail not found - install it: sudo apt install whiptail'
	while true; do
		choice="$(tui --menu "Current: $(mode_description "$(current_mode)")\n\nChoose an action:" 16 68 4 \
			'1' 'Start AP mode' \
			'2' 'Stop AP mode (back to normal Wi-Fi)' \
			'3' 'Show status' \
			'4' 'Exit')" || break
		case "${choice}" in
			1) tui_start ;;
			2) tui_stop ;;
			3) tui_message "$(status_text)" ;;
			*) break ;;
		esac
	done
	clear
}

# ------------------------------------------------------------
# CLI
# ------------------------------------------------------------
usage() {
	sed -n '/^#   sudo/,/^#   sudo .* install/p' "${SCRIPT_PATH}" | sed 's/^# \{0,1\}//'
}

cli_start() {
	local ssid='' password='' band="${DEFAULT_BAND}" channel='' address="${DEFAULT_AP_ADDRESS}" is_autostart='true'
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--ssid) ssid="${2:-}"; shift 2 ;;
			--password) password="${2:-}"; shift 2 ;;
			--band) band="${2:-}"; shift 2 ;;
			--channel) channel="${2:-}"; shift 2 ;;
			--address) address="${2:-}"; shift 2 ;;
			--no-autostart) is_autostart='false'; shift ;;
			*) die "unknown option: $1" ;;
		esac
	done
	[ -n "${ssid}" ] && [ -n "${password}" ] || die 'start needs --ssid and --password.'
	if [ -z "${channel}" ]; then
		if [ "${band}" = '5GHz' ]; then
			channel="${DEFAULT_CHANNEL_5G}"
		else
			channel="${DEFAULT_CHANNEL_2G}"
		fi
	fi
	# 설치(인터넷 필요)보다 입력 검증을 먼저 한다.
	validate_start_inputs "${ssid}" "${password}" "${band}" "${channel}" "${address}"
	install_dependencies
	print_ap_connection_info "${ssid}" "${address}"
	if do_start "${ssid}" "${password}" "${band}" "${channel}" "${address}" "${is_autostart}"; then
		log "OK: ${LAST_RESULT_MESSAGE}"
	else
		die "${LAST_RESULT_MESSAGE}"
	fi
}

cli_stop() {
	local ssid='' password=''
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--ssid) ssid="${2:-}"; shift 2 ;;
			--password) password="${2:-}"; shift 2 ;;
			*) die "unknown option: $1" ;;
		esac
	done
	if do_stop "${ssid}" "${password}"; then
		log "OK: ${LAST_RESULT_MESSAGE}"
	else
		die "${LAST_RESULT_MESSAGE}"
	fi
}

main() {
	require_root "$@"
	check_wifi_interface
	case "${1:-}" in
		'') tui_main ;;
		start) shift; cli_start "$@" ;;
		stop) shift; cli_stop "$@" ;;
		status) status_text ;;
		install) install_dependencies ;;
		__worker) run_worker ;;
		-h|--help|help) usage ;;
		*) usage; exit 1 ;;
	esac
}

main "$@"
