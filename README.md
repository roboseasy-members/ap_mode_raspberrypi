# ap_mode_raspberrypi

라즈베리파이(Ubuntu Server 24.04, netplan)의 와이파이를 **AP(핫스팟) 모드**로
바꾸는 도구. 쉘 파일 1개 + 텍스트 UI(whiptail).

검증: Raspberry Pi 4B / Ubuntu 24.04.5 / brcmfmac — 2.4GHz·5GHz, WPA2,
재부팅 동작, 실패 시 자동 원복, 클라이언트 접속(DHCP·SSH) 확인 (2026-10-06).
Pi 5는 같은 칩 계열이지만 미검증.

## 실행

`ap_mode.sh` 파일 하나만 Pi에 있으면 된다 (scp·USB로 복사해도 됨).

```bash
bash ap_mode.sh        # 어디서든 동작 (sh ap_mode.sh, ./ap_mode.sh, sudo ./ap_mode.sh 모두 가능)
```

- sudo는 붙이지 않아도 된다 — 필요하면 스크립트가 스스로 비밀번호를 묻는다
- `./ap_mode.sh`가 `Permission denied`면 실행 권한이 빠진 것 → `bash ap_mode.sh`로 실행
  (또는 `chmod +x ap_mode.sh`)
- 첫 실행 시 `network-manager`·`dnsmasq-base`·`iw`를 자동 설치한다 (인터넷 필요 —
  **AP로 바꾸기 전**, 일반 와이파이나 유선이 연결된 상태에서 실행)

| 메뉴 | 동작 |
|------|------|
| 1 Start AP mode | SSID → 비밀번호(2회) → 대역(2.4/5GHz) → **부팅 시 자동 시작 여부** → 확인 |
| 2 Stop AP mode | 저장된 와이파이로 복귀, 또는 새 와이파이 입력 |
| 3 Show status | 현재 모드·SSID·IP·접속 기기 수 |

접속: 노트북/폰을 AP에 연결 → `ssh roboseasy@192.168.4.1`

## 비대화식

```bash
bash ap_mode.sh start --ssid MyPiAP --password 12345678 [--band 5GHz] [--no-autostart]
bash ap_mode.sh stop [--ssid MyWiFi --password MyWiFiPassword]
bash ap_mode.sh status
bash ap_mode.sh install      # 패키지만 설치
```

옵션: `--channel N`(기본 2.4GHz=6, 5GHz=36), `--address 192.168.4.1/24`.

## 동작 방식

| 자동 시작 | 설정 위치 | 재부팅 후 |
|-----------|-----------|-----------|
| 예 (기본) | `/etc/netplan/50-cloud-init.yaml` | AP 유지 — 메뉴 2로만 해제 |
| 아니오 | `/run/netplan/50-cloud-init.yaml` | 원래 와이파이로 복귀 (`/run`은 재부팅 시 비워짐) |

- wlan0만 NetworkManager가 담당, **eth0은 networkd DHCP 유지** (비상 유선 복구 경로)
- 보안은 WPA2 전용(RSN/CCMP) 고정, PMF off — 미지정 시 NM이 WPA1(TKIP)로 광고함
- 적용은 systemd 서비스로 분리 실행 — 와이파이 SSH가 끊겨도 진행되고,
  30초 안에 AP(또는 와이파이)가 안 뜨면 **직전 설정으로 자동 원복**
- 처음 AP를 켤 때 원래 와이파이 설정을 `/etc/ap_mode_raspberrypi/client_netplan.yaml`에 백업
- cloud-init이 netplan을 덮어쓰지 않게 잠금 (`/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`)

## 주의

- AP 모드 중 Pi는 **와이파이 인터넷 없음** (유선이 있으면 유선으로 나감)
- AP 대역(기본 `192.168.4.0/24`)이 다른 인터페이스 대역과 겹치면 거부한다
  — 특히 노트북 유선 공유(`10.42.0.x`)와 겹치는 주소 금지
- 와이파이 SSH로 실행하면 세션이 끊긴다 → AP에 접속해 `192.168.4.1`로 재접속

## 트러블슈팅

| 증상 | 조치 |
|------|------|
| 와이파이로 전혀 접속 불가 | 유선 직결(노트북 공유 → `nmap -sn 10.42.0.0/24`) 후 `bash ap_mode.sh stop` |
| AP가 안 보임 | `bash ap_mode.sh status`, `iw dev wlan0 info` |
| 원인 확인 | `/var/log/ap_mode_raspberrypi.log`, `journalctl -u NetworkManager` |
| 패키지 설치 실패 | 인터넷 연결 확인 (AP 모드 중이면 먼저 유선 연결) |
