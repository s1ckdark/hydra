# SSH 키 생성 버튼 (Ed25519) — 설계

- 날짜: 2026-07-22
- 상태: 승인됨
- 범위: macOS 앱 + iOS 앱 (Linux는 이번 범위에서 제외)

## 배경 / 목표

다른 기기에서 SSH 접근을 설정하려면 현재는 터미널에서 `ssh-keygen`을 직접 실행해야 한다
(지난 세션에서 iPad용 `hydra_ipad_ed25519` 키를 수동 생성·등록한 과정이 동기).
키가 없는 기기에서 앱 내 버튼 한 번으로 Ed25519 키페어를 생성하고, 공개키를
복사/공유해 대상 서버의 `authorized_keys`에 사용자가 직접 등록할 수 있게 한다.

공개키 서버 자동 등록(ssh-copy-id 유사 기능)은 이번 범위에 포함하지 않는다.

## 결정 사항

| 항목 | 결정 |
|---|---|
| 키 타입 | Ed25519 고정 (iOS Citadel이 rsa-sha2 미지원, 양 백엔드에서 검증된 유일 타입) |
| 키 포맷 | openssh-key-v1 (`-----BEGIN OPENSSH PRIVATE KEY-----`), 비암호화 |
| 생성 위치 | 각 기기 로컬에서 생성 — 개인키는 기기를 떠나지 않음 |
| 구현 방식 | 공유 CryptoKit 생성기 (macOS도 ssh-keygen Process를 쓰지 않음) |
| 패스프레이즈 | 없음 (iOS Keychain / macOS 파일 권한 0600이 보호층) |
| 공개키 등록 | 복사/공유만 제공, 서버 등록은 수동 |

## 컴포넌트

### 1. `SSHKeyGenerator` (신규 공유 서비스)

위치: `Hydra/Hydra/Services/SSHKeyGenerator.swift` (SSHKeyLocator처럼 iOS 타깃에도 포함)

```swift
enum SSHKeyGenerator {
    struct GeneratedKey {
        let privateKeyOpenSSH: String  // "-----BEGIN OPENSSH PRIVATE KEY-----\n..."
        let publicKeyLine: String      // "ssh-ed25519 AAAA... <comment>"
    }
    static func generate(comment: String) -> GeneratedKey
}
```

- CryptoKit `Curve25519.Signing.PrivateKey` 사용, 외부 의존성 없음
- openssh-key-v1 직렬화: 매직 문자열, `none`/`none` cipher/kdf, check bytes(랜덤 1쌍 복제),
  ed25519 공개키 32B + 개인키 64B(seed+pub), comment, 8바이트 블록 패딩, base64 70컬럼 줄바꿈
- comment 규칙: iOS `hydra-<UIDevice.name 정제>`, macOS `<NSUserName()>@<Host hostname>`

### 2. iOS — `KeyImportScreen` 확장

- 키 없음: "새 키 생성 (Ed25519)" 버튼 → 생성 후
  - 개인키 → 기존 Keychain 슬롯 `.sshPrivateKeyPEM`
  - 공개키 → 신규 슬롯 `.sshPublicKeyOpenSSH` (CredentialStore.Key 케이스 추가)
- 생성 후 공개키 표시 + 복사 버튼 + `ShareLink` (AirDrop/메시지 등)
- 키 있음: confirmationDialog로 교체 확인 ("기존 키로 접속하던 서버 연결이 끊깁니다") 후 생성
- 기존 PEM 붙여넣기/파일 가져오기 흐름은 변경 없음
- 수동 붙여넣기로 키를 교체·삭제하면 저장된 공개키 슬롯도 함께 갱신·삭제

### 3. macOS — `DeviceListView` 공개키 행 확장

- 현재: `SSHKeyLocator.defaultPublicKey()` 실패 시 에러 문구만 표시
- 변경: `orderedKeyPairs()`가 `noKeysFound`일 때만 "키 생성" 버튼 노출
  - `~/.ssh` 없으면 0700으로 생성
  - `~/.ssh/id_ed25519` (0600) / `id_ed25519.pub` (0644) 기록 — 기존 파일 존재 시 중단(덮어쓰기 금지)
  - 성공 시 곧바로 공개키를 클립보드에 복사하고 `keyCopyStatus = .copied`로 전환
- 기존 키가 하나라도 있으면 생성 버튼 숨김
- `SSHKeyLocator` 선호 순서상 `id_ed25519`가 최우선이므로 생성 즉시 터미널 연결 후보에 반영

## 에러 처리

- macOS: 파일 쓰기 실패/이미 존재 → `keyCopyStatus = .failed(message:)` 재사용
- iOS: Keychain 저장 실패 등 → 기존 `message` 라벨 재사용
- 생성 자체(CryptoKit)는 실패 경로가 사실상 없음 — 직렬화는 순수 함수

## 테스트

1. **오라클 검증 (macOS 유닛테스트)**: 생성한 개인키를 임시 파일(0600)에 쓰고
   `Process`로 `ssh-keygen -y -f <파일>` 실행 → 출력 공개키가 `publicKeyLine`의
   타입+base64 부분과 일치해야 함. OpenSSH 자체를 오라클로 사용해 포맷 버그 차단.
2. **iOS 저장 호환**: `privateKeyOpenSSH`가 기존 검증(`contains("PRIVATE KEY-----")`)을 통과.
3. **Locator 통합**: 임시 디렉터리에 생성 → `SSHKeyLocator.orderedKeyPairs(in:)`이
   해당 키페어를 인식하고 최우선으로 정렬.
4. 기존 파일 존재 시 생성 거부(덮어쓰기 금지) 동작.

## 리스크

- openssh-key-v1 직렬화 실수 → 테스트 1(ssh-keygen 오라클)로 상쇄
- 백엔드 호환성: 동일 포맷의 `hydra_ipad_ed25519` 키가 libssh2(macOS)·Citadel(iOS)
  양쪽에서 이미 동작 검증됨 — 리스크 낮음
