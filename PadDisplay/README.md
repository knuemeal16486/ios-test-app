# PadDisplay — iPad Pro를 Mac mini의 주 모니터로

Mac mini (M4, 16GB) + iPad Pro 13" (M4) 전용으로 설계한 저지연 원격 디스플레이.
Mac에 **실제 가상 디스플레이**를 만들고, 그 화면을 HEVC로 인코딩해 iPad로 보내며, iPad의 터치·펜슬·트랙패드·키보드 입력을 Mac으로 되돌려 보낸다.

```
┌──────────── Mac mini (PadDisplayHost, 메뉴 막대 앱) ─────────────┐        ┌──────── iPad Pro (PadDisplay) ────────┐
│ CGVirtualDisplay 1376×1032pt HiDPI (=2752×2064px) → 주 디스플레이 │        │                                        │
│   └ ScreenCaptureKit (420v, 60/120Hz)                            │  TCP   │ AVSampleBufferDisplayLayer (HW 디코드, │
│       └ VideoToolbox HEVC 저지연 RC, B프레임 없음 ───────────────┼──────▶ │   DisplayImmediately)                  │
│ CGEvent 주입 (마우스·스크롤·키보드) ◀────────────────────────────┼─────── │ 제스처/HID 키 → InputEvent             │
└──────────────────────────────────────────────────────────────────┘  USB-C (usbmuxd) 또는 Wi-Fi (Bonjour)  └──────┘
```

## 구성

| 경로 | 내용 |
|---|---|
| `Shared/` | 와이어 프로토콜(`[type:u8][len:u32][payload]`), Network.framework 프레이밍 |
| `MacHost/` | 가상 디스플레이(비공개 API), 주 디스플레이 지정, 캡처, HEVC 인코더, 입력 주입, 메뉴 막대 UI |
| `PadClient/` | Bonjour 검색·자동 연결, HEVC 표시, 제스처/키보드 전달, 회전 대응 |

## 빌드

요구: Xcode 16+, macOS 14+, iPadOS 17+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
brew install xcodegen
cd PadDisplay
xcodegen generate
open PadDisplay.xcodeproj
```

1. 두 타깃 모두 **Signing & Capabilities → Team**에 본인 Apple ID(무료 개인 팀 가능)를 지정.
   - Mac 앱은 반드시 동일한 팀으로 서명해야 재빌드 후에도 화면 기록/손쉬운 사용 권한이 유지된다.
2. `PadDisplayHost` → My Mac으로 실행 → 빌드된 앱을 `/Applications`로 복사 권장.
3. `PadDisplayClient` → iPad로 실행 (iPad: 설정 → 개인정보 보호 및 보안 → 개발자 모드 켜기).

## 최초 설정 (모니터가 연결된 상태에서 1회)

1. Mac 메뉴 막대 아이콘 → **화면 기록**, **손쉬운 사용** 허용 (허용 후 앱 재실행).
2. 메뉴에서 **로그인 시 자동 실행** 켜기.
3. iPad 앱 실행 → 로컬 네트워크 허용 → 목록의 Mac 선택. 이후 자동 연결.
4. 헤드리스(모니터 없이) 운용 시: 시스템 설정 → 사용자 및 그룹 → **자동 로그인** 활성화
   (FileVault가 켜져 있으면 자동 로그인 불가 — 아래 제약 참고).

## 유선 연결 (USB-C)

iPad Pro를 Mac mini에 USB-C 케이블로 연결하면 **자동으로 유선 모드**가 된다. 별도 조작 없음.

```
Mac: UsbDeviceMonitor ──/var/run/usbmuxd──(USB)──▶ iPad usbmuxd ──▶ 127.0.0.1:52101 (PadDisplay 앱)
```

- Xcode·Finder가 기기와 통신하는 것과 같은 `usbmuxd` 터널. 네트워크 설정·IP 불필요, Wi-Fi 없이도 동작.
- 최초 1회: 케이블 연결 후 iPad에서 **"이 컴퓨터를 신뢰하겠습니까?" → 신뢰**.
- Mac 앱은 USB iPad를 감지하면 2초 주기로 접속을 시도 → iPad 앱을 열면 즉시 연결.
- **USB 우선**: Wi-Fi로 보는 중 케이블을 꽂으면 USB로 전환, 뽑으면 Wi-Fi로 자동 폴백.
- USB 세션 중에는 Mac이 Wi-Fi 연결을 받지 않아 두 경로가 서로 끊는 일이 없다.
- 유선에서는 비트레이트를 80~150Mbps, 주사율 120Hz까지 올려도 된다.
- Mac 메뉴의 **USB 유선 연결** 토글로 끌 수 있다 (iPad 감지 여부 표시).

## iPad 조작

| 입력 | Mac 동작 |
|---|---|
| 1손가락 / 펜슬 탭 | 클릭 (연속 탭 = 더블클릭) |
| 1손가락 / 펜슬 드래그 | 클릭-드래그 (선택, 창 이동) |
| 2손가락 드래그, 트랙패드 스크롤, 마우스 휠 | 스크롤 (관성 포함) |
| 2손가락 탭, 길게 누르기, 트랙패드 보조 클릭 | 우클릭 |
| Magic Keyboard 트랙패드 이동, 펜슬 호버 | 포인터 이동 |
| 하드웨어 키보드 | HID 코드 그대로 전달 (키 반복 포함) |
| 3손가락 탭 | 상태 HUD (fps / Mbps / RTT, 연결 끊기) |

## 권장 설정 (M4 조합)

| 항목 | 값 | 근거 |
|---|---|---|
| 해상도 | 기본 1376×1032pt (2752×2064px, 1:1 픽셀) | 스케일링 없음 → 텍스트 선명 |
| 주사율 | 60Hz (유선/5GHz 양호 시 120Hz) | 120Hz는 대역폭·인코더 부하 2배 |
| 비트레이트 | 40Mbps (Wi-Fi 6) / 80Mbps+ (유선) | 텍스트 위주 화면은 정지 시 프레임이 거의 없음 |
| 연결 | **USB-C 케이블 직결** (권장) / 같은 AP의 5/6GHz Wi-Fi | 유선: 지터·재전송 없음, 충전 동시 |

## 지연·안정성 설계

- 인코더: HEVC, 저지연 레이트 컨트롤(미지원 시 자동 폴백), 프레임 재정렬 없음, 키프레임은 요청 시에만.
- 혼잡 제어: 전송 대기량이 약 150ms 분량을 넘으면 프레임을 버리고 다음 키프레임까지 P프레임도 폐기 → 오래된 화면이 쌓이지 않음.
- 정지 화면: ScreenCaptureKit은 변화가 없으면 프레임을 보내지 않으므로, 키프레임 요청 시 마지막 프레임을 재인코딩.
- 디코더 오류/백그라운드 복귀: 렌더러 flush → 키프레임 재요청(0.5초 스로틀).
- 연결 끊김: iPad는 1.5초 후 자동 재연결, Mac은 가상 디스플레이를 유지(설정)해 창 배치가 흐트러지지 않음.
- 회전: iPad 크기 변경 → Mac 가상 디스플레이 모드 가로/세로 전환 후 스트림 재시작.

## 제약 사항 (반드시 확인)

- **로그인 이전 화면은 표시 불가**: 사용자 세션 앱이므로 부팅 직후 로그인 창·FileVault 잠금 해제 화면은 iPad에 나오지 않는다.
  헤드리스 운용 = 자동 로그인 필요(FileVault 끄기). FileVault를 유지하려면 부팅 시에만 HDMI 더미 플러그나 모니터를 쓰거나, 다른 기기에서 화면 공유로 로그인.
- **비공개 API(CGVirtualDisplay)** 사용 → App Store 배포 불가, macOS 업데이트로 깨질 수 있음 (DeskPad·BetterDisplay와 동일 방식).
- macOS 15+는 ScreenCaptureKit 사용 앱에 대해 주기적으로 화면 기록 재확인 알림을 띄울 수 있다 → iPad 화면에서 '허용'.
- iPadOS가 선점하는 단축키(⌘Tab, ⌘Space, 지구본 키 조합 등)는 Mac으로 전달되지 않는다.
- Apple 기본 기능 **Sidecar**로도 iPad를 확장 디스플레이로 쓸 수 있으나, 매번 Mac에서 수동 연결해야 하고 헤드리스 주 모니터 운용이 불편하다. 이 앱은 그 공백(자동 연결·주 디스플레이 고정)을 메운다.

## 프로토콜

| type | 방향 | payload |
|---|---|---|
| `0x01` hello / `0x03` resize | iPad→Mac | JSON `ClientHello` (픽셀 크기, ppi, 최대 fps) |
| `0x02` serverInfo | Mac→iPad | JSON `ServerInfo` |
| `0x10` videoFormat | Mac→iPad | `w:u32 h:u32 n:u8 (len:u16 bytes)*n` — HEVC VPS/SPS/PPS |
| `0x11` videoFrame | Mac→iPad | `flags:u8 pts_us:u64 AVCC NAL…` |
| `0x12` requestKeyframe | iPad→Mac | 없음 |
| `0x20` input | iPad→Mac | JSON `InputEvent` (정규화 좌표) |
| `0x30/0x31` ping/pong | 양방향 | `t_us:u64` |
