# SSH 키 생성 버튼 (Ed25519) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 키가 없는 기기(macOS/iOS 앱)에서 버튼 한 번으로 Ed25519 SSH 키페어를 생성하고 공개키를 복사/공유할 수 있게 한다.

**Architecture:** 공유 서비스 `SSHKeyGenerator`(CryptoKit Curve25519 + openssh-key-v1 직렬화)를 mac/iOS 양 타깃이 공유한다. macOS는 `DeviceListView` 공개키 행에서 `~/.ssh/id_ed25519` 파일로 설치, iOS는 `KeyImportScreen`에서 Keychain(`CredentialStore`)에 저장한다. 서버 자동 등록은 범위 외 — 복사/공유만.

**Tech Stack:** Swift 5 모드(SPM tools 6.0), CryptoKit, XCTest. macOS 앱 = SPM 실행 타깃(`Hydra/` 디렉터리에서 `swift build`/`swift test`), iOS 앱 = xcodegen `HydraiOS` 타깃.

## Global Constraints

- 키 타입은 Ed25519 고정, 포맷은 openssh-key-v1 비암호화 (`-----BEGIN OPENSSH PRIVATE KEY-----`)
- 패스프레이즈 없음
- 개인키는 생성한 기기를 떠나지 않는다 (네트워크 전송 금지)
- 기존 키 파일 덮어쓰기 금지 (macOS), iOS는 교체 확인 다이얼로그 필수
- 새 파일은 `Hydra/Hydra/Services/`에 두면 iOS 타깃에 자동 포함됨 (project.yml이 디렉터리 단위 포함, 단 **xcodegen 재생성 필요**)
- 모든 명령의 작업 디렉터리: `/Users/dave/iWorks/hydra/Hydra`
- 커밋 메시지는 한국어 + conventional commit 접두사 (기존 히스토리 관례), `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` 트레일러 포함

---

### Task 1: `SSHKeyGenerator` 공유 서비스 (openssh-key-v1 직렬화)

**Files:**
- Create: `Hydra/Hydra/Services/SSHKeyGenerator.swift`
- Test: `Hydra/Tests/HydraTests/SSHKeyGeneratorTests.swift`

**Interfaces:**
- Consumes: 없음 (CryptoKit만 사용)
- Produces: `SSHKeyGenerator.generate(comment: String) -> SSHKeyGenerator.GeneratedKey`
  - `GeneratedKey.privateKeyOpenSSH: String` — `-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----\n`
  - `GeneratedKey.publicKeyLine: String` — `ssh-ed25519 <base64> <comment>` (개행 없음)

- [ ] **Step 1: 실패하는 테스트 작성**

`Hydra/Tests/HydraTests/SSHKeyGeneratorTests.swift`:

```swift
import XCTest
@testable import Hydra

final class SSHKeyGeneratorTests: XCTestCase {

    func testPrivateKeyFormatAndIOSStorageValidation() {
        let key = SSHKeyGenerator.generate(comment: "test@hydra")
        XCTAssertTrue(key.privateKeyOpenSSH.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        XCTAssertTrue(key.privateKeyOpenSSH.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
        // iOS KeyImportScreen.save()의 저장 검증과 동일한 조건
        XCTAssertTrue(key.privateKeyOpenSSH.contains("PRIVATE KEY-----"))
        XCTAssertTrue(key.publicKeyLine.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(key.publicKeyLine.hasSuffix(" test@hydra"))
        XCTAssertFalse(key.publicKeyLine.contains("\n"))
    }

    /// OpenSSH 자체를 오라클로 사용: ssh-keygen -y가 개인키를 파싱해
    /// 낸 공개키가 우리가 만든 publicKeyLine과 일치해야 한다.
    func testSSHKeygenOracleAcceptsGeneratedKey() throws {
        let key = SSHKeyGenerator.generate(comment: "oracle@hydra")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshkeygen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let privURL = dir.appendingPathComponent("id_ed25519")
        try key.privateKeyOpenSSH.write(to: privURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: privURL.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        proc.arguments = ["-y", "-f", privURL.path]
        let stdout = Pipe(); let stderr = Pipe()
        proc.standardOutput = stdout; proc.standardError = stderr
        try proc.run(); proc.waitUntilExit()

        let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        XCTAssertEqual(proc.terminationStatus, 0, "ssh-keygen -y 실패: \(errText)")

        let derived = String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
        // ssh-keygen -y는 comment를 생략할 수 있으므로 타입+base64만 비교
        let expected = key.publicKeyLine.split(separator: " ").prefix(2).joined(separator: " ")
        let got = derived.split(separator: " ").prefix(2).joined(separator: " ")
        XCTAssertEqual(got, expected)
    }

    func testGeneratedKeysAreUnique() {
        let a = SSHKeyGenerator.generate(comment: "c")
        let b = SSHKeyGenerator.generate(comment: "c")
        XCTAssertNotEqual(a.publicKeyLine, b.publicKeyLine)
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter SSHKeyGeneratorTests 2>&1 | tail -5`
Expected: 컴파일 에러 `cannot find 'SSHKeyGenerator' in scope`

- [ ] **Step 3: 최소 구현 작성**

`Hydra/Hydra/Services/SSHKeyGenerator.swift`:

```swift
import Foundation
import CryptoKit

/// Ed25519 SSH 키페어를 생성해 OpenSSH 포맷(openssh-key-v1, 비암호화)으로
/// 직렬화한다. macOS(libssh2)와 iOS(Citadel) 양쪽 백엔드가 읽는 포맷.
enum SSHKeyGenerator {
    struct GeneratedKey {
        /// "-----BEGIN OPENSSH PRIVATE KEY-----" PEM 전체 (끝 개행 포함)
        let privateKeyOpenSSH: String
        /// "ssh-ed25519 <base64> <comment>" — authorized_keys 한 줄
        let publicKeyLine: String
    }

    static func generate(comment: String) -> GeneratedKey {
        let key = Curve25519.Signing.PrivateKey()
        return serialize(seed: key.rawRepresentation,
                         publicKey: key.publicKey.rawRepresentation,
                         comment: comment)
    }

    /// 결정적 입력을 받는 순수 직렬화 — 테스트에서 직접 호출 가능하도록 분리.
    static func serialize(seed: Data, publicKey: Data, comment: String) -> GeneratedKey {
        let keyType = Data("ssh-ed25519".utf8)

        // 공개키 blob: string type || string pub(32B)
        var pubBlob = Data()
        pubBlob.appendSSHString(keyType)
        pubBlob.appendSSHString(publicKey)

        // 개인키 섹션: check쌍, type, pub, seed||pub(64B), comment, 1..n 패딩
        let check = UInt32.random(in: .min ... .max)
        var privSection = Data()
        privSection.appendUInt32(check)
        privSection.appendUInt32(check)
        privSection.appendSSHString(keyType)
        privSection.appendSSHString(publicKey)
        privSection.appendSSHString(seed + publicKey)
        privSection.appendSSHString(Data(comment.utf8))
        var pad: UInt8 = 1
        while privSection.count % 8 != 0 { privSection.append(pad); pad += 1 }

        var blob = Data("openssh-key-v1\0".utf8)
        blob.appendSSHString(Data("none".utf8))   // ciphername
        blob.appendSSHString(Data("none".utf8))   // kdfname
        blob.appendSSHString(Data())              // kdfoptions
        blob.appendUInt32(1)                      // key count
        blob.appendSSHString(pubBlob)
        blob.appendSSHString(privSection)

        let body = blob.base64EncodedString().chunked(into: 70).joined(separator: "\n")
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n\(body)\n-----END OPENSSH PRIVATE KEY-----\n"
        let publicLine = "ssh-ed25519 \(pubBlob.base64EncodedString()) \(comment)"
        return GeneratedKey(privateKeyOpenSSH: pem, publicKeyLine: publicLine)
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var be = value.bigEndian
        append(Data(bytes: &be, count: 4))
    }
    /// SSH wire format string: uint32 길이 + 바이트
    mutating func appendSSHString(_ data: Data) {
        appendUInt32(UInt32(data.count))
        append(data)
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        var result: [String] = []
        var idx = startIndex
        while idx < endIndex {
            let end = index(idx, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[idx..<end]))
            idx = end
        }
        return result
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter SSHKeyGeneratorTests 2>&1 | tail -5`
Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 5: 커밋**

```bash
git add Hydra/Services/SSHKeyGenerator.swift ../Hydra/Tests/HydraTests/SSHKeyGeneratorTests.swift
git commit -m "feat: SSHKeyGenerator — Ed25519 openssh-key-v1 생성기 (ssh-keygen 오라클 테스트)"
```
(리포 루트 기준 경로는 `Hydra/Hydra/Services/...`, `Hydra/Tests/...` — git add는 리포 루트에서 실행해도 됨)

---

### Task 2: macOS 설치 함수 + `DeviceListView` "키 생성" 버튼

**Files:**
- Modify: `Hydra/Hydra/Services/SSHKeyGenerator.swift` (macOS 전용 extension 추가)
- Modify: `Hydra/Hydra/Views/Devices/DeviceListView.swift:651-718` (`publicKeyCopyRow`/`copyPublicKey` 부근)
- Test: `Hydra/Tests/HydraTests/SSHKeyGeneratorTests.swift` (설치 테스트 추가)

**Interfaces:**
- Consumes: Task 1의 `SSHKeyGenerator.generate(comment:)`, 기존 `SSHKeyLocator.orderedKeyPairs(in:)` / `LocateError.noKeysFound`
- Produces: `SSHKeyGenerator.generateAndInstall(comment: String, sshDir: URL) throws -> SSHKeyLocator.Located` (macOS 전용; 기본 sshDir = `~/.ssh`)

- [ ] **Step 1: 실패하는 테스트 작성** — `SSHKeyGeneratorTests.swift`에 추가:

```swift
    #if os(macOS)
    func testInstallWritesKeyPairWithPermissionsAndRefusesOverwrite() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshinstall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 디렉터리가 없어도 0700으로 만들어야 함
        let located = try SSHKeyGenerator.generateAndInstall(comment: "install@test", sshDir: dir)
        XCTAssertEqual(located.filename, "id_ed25519.pub")

        let fm = FileManager.default
        let privPath = dir.appendingPathComponent("id_ed25519").path
        let pubPath = dir.appendingPathComponent("id_ed25519.pub").path
        func perms(_ p: String) throws -> Int {
            (try fm.attributesOfItem(atPath: p)[.posixPermissions] as! NSNumber).intValue
        }
        XCTAssertEqual(try perms(dir.path), 0o700)
        XCTAssertEqual(try perms(privPath), 0o600)
        XCTAssertEqual(try perms(pubPath), 0o644)

        // SSHKeyLocator가 인식해야 함
        let pairs = try SSHKeyLocator.orderedKeyPairs(in: dir)
        XCTAssertEqual(pairs.first?.privatePath, privPath)
        XCTAssertEqual(pairs.first?.algorithmName, "ed25519")

        // 이미 존재하면 덮어쓰지 않고 실패해야 함
        XCTAssertThrowsError(try SSHKeyGenerator.generateAndInstall(comment: "x", sshDir: dir))
    }
    #endif
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter SSHKeyGeneratorTests 2>&1 | tail -5`
Expected: 컴파일 에러 `type 'SSHKeyGenerator' has no member 'generateAndInstall'`

- [ ] **Step 3: 설치 함수 구현** — `SSHKeyGenerator.swift` 하단에 추가:

```swift
#if os(macOS)
extension SSHKeyGenerator {
    enum InstallError: LocalizedError {
        case alreadyExists(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyExists(let path):
                return "이미 키 파일이 있어요: \(path) — 덮어쓰지 않습니다."
            case .writeFailed(let detail):
                return "키 파일 쓰기 실패: \(detail)"
            }
        }
    }

    private static func defaultSSHDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    }

    /// 새 Ed25519 키페어를 생성해 sshDir/id_ed25519(.pub)로 기록한다.
    /// 기존 파일이 있으면 덮어쓰지 않고 실패. 반환값은 복사용 공개키.
    @discardableResult
    static func generateAndInstall(comment: String,
                                   sshDir: URL = defaultSSHDir()) throws -> SSHKeyLocator.Located {
        let fm = FileManager.default
        let privURL = sshDir.appendingPathComponent("id_ed25519")
        let pubURL = sshDir.appendingPathComponent("id_ed25519.pub")
        for url in [privURL, pubURL] where fm.fileExists(atPath: url.path) {
            throw InstallError.alreadyExists(url.path)
        }

        let key = generate(comment: comment)
        do {
            if !fm.fileExists(atPath: sshDir.path) {
                try fm.createDirectory(at: sshDir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            }
            try key.privateKeyOpenSSH.write(to: privURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privURL.path)
            try (key.publicKeyLine + "\n").write(to: pubURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pubURL.path)
        } catch let e as InstallError {
            throw e
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
        return SSHKeyLocator.Located(url: pubURL, contents: key.publicKeyLine)
    }
}
#endif
```

주의: `SSHKeyLocator.Located`의 멤버와이즈 이니셜라이저는 internal이므로 같은 모듈(Hydra)에서 접근 가능. `atomically: true` 쓰기는 임시파일 rename이라 최종 권한을 setAttributes로 덮는 현재 순서가 필요하다.

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter SSHKeyGeneratorTests 2>&1 | tail -5`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 5: DeviceListView에 생성 버튼 추가**

`DeviceListView.swift`의 `publicKeyCopyRow`가 있는 뷰 구조체에 상태 추가 (기존 `keyCopyStatus` 선언 근처):

```swift
    @State private var canGenerateKey = false
```

`publicKeyCopyRow`를 다음으로 교체 (기존 복사 버튼 유지, 생성 버튼 조건부 추가):

```swift
    private var publicKeyCopyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("이 호스트 SSH 공개키")
                    .font(.caption)
                Text(keyCopyStatusMessage)
                    .font(.caption2)
                    .foregroundStyle(keyCopyStatusColor)
                    .lineLimit(1)
            }
            Spacer()
            if canGenerateKey {
                Button(action: generateHostKey) {
                    Label("키 생성", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("~/.ssh에 키가 없어요. Ed25519 키페어를 생성하고 공개키를 복사합니다.")
            }
            Button(action: copyPublicKey) {
                Label(keyCopyButtonTitle, systemImage: keyCopyButtonIcon)
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("디바이스 ~/.ssh/authorized_keys에 등록할 공개키를 클립보드로 복사합니다.")
        }
        .padding(8)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: theme.controlRadius))
        .onAppear { refreshCanGenerateKey() }
    }

    private func refreshCanGenerateKey() {
        // noKeysFound일 때만 생성 버튼 노출 — 기존 키가 있으면 덮어쓰기 위험 차단
        if case .some = try? SSHKeyLocator.orderedKeyPairs().first {
            canGenerateKey = false
        } else {
            canGenerateKey = true
        }
    }

    private func generateHostKey() {
        keyCopyResetTask?.cancel()
        do {
            let host = ProcessInfo.processInfo.hostName
            let located = try SSHKeyGenerator.generateAndInstall(comment: "\(NSUserName())@\(host)")
            SSHKeyLocator.copyToClipboard(located)
            keyCopyStatus = .copied(filename: located.filename)
            canGenerateKey = false
        } catch {
            keyCopyStatus = .failed(message: error.localizedDescription)
        }
        keyCopyResetTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                await MainActor.run { keyCopyStatus = .idle }
            }
        }
    }
```

주의: `keyCopyStatus`/`keyCopyResetTask`/`keyCopyStatusMessage` 등은 이미 이 파일에 존재 — 이름 충돌 없이 위 두 함수와 상태 1개, 뷰 교체만 추가한다. macOS 26 크래시 완화 관례(커밋 77f9b20)에 따라 이 프로젝트는 Button action 패턴을 유지한다 (새 .alert 추가 없음 — 상태 라벨 재사용이라 안전).

- [ ] **Step 6: macOS 빌드 확인**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 7: 커밋**

```bash
git add -A Hydra/ Tests/
git commit -m "feat: macOS 키 없을 때 DeviceListView에 SSH 키 생성 버튼 (~/.ssh/id_ed25519)"
```

---

### Task 3: iOS `KeyImportScreen` 생성/복사/공유 + CredentialStore 슬롯

**Files:**
- Modify: `Hydra/Hydra/Services/CredentialStore.swift:24` (Key 케이스 추가)
- Modify: `Hydra/HydraiOS/Screens/KeyImportScreen.swift` (전체 교체 수준 확장)
- Verify: xcodegen 재생성 + HydraiOS 시뮬레이터 빌드

**Interfaces:**
- Consumes: Task 1의 `SSHKeyGenerator.generate(comment:)`, 기존 `CredentialStore.shared`
- Produces: `CredentialStore.Key.sshPublicKeyOpenSSH` (rawValue `"ssh_public_key_openssh"`)

- [ ] **Step 1: CredentialStore에 공개키 슬롯 추가**

`CredentialStore.swift`의 enum `Key`에 케이스 추가:

```swift
        case sshPrivateKeyPEM = "ssh_private_key_pem"
        case sshPublicKeyOpenSSH = "ssh_public_key_openssh"
```

- [ ] **Step 2: KeyImportScreen 확장** — 파일 전체를 다음으로 교체:

```swift
import SwiftUI
import UniformTypeIdentifiers

struct KeyImportScreen: View {
    @State private var pem: String = CredentialStore.shared.get(.sshPrivateKeyPEM)
    @State private var publicKey: String = CredentialStore.shared.get(.sshPublicKeyOpenSSH)
    @State private var showingImporter = false
    @State private var showingReplaceConfirm = false
    @State private var message: String?

    private var hasKey: Bool { !CredentialStore.shared.get(.sshPrivateKeyPEM).isEmpty }

    var body: some View {
        Form {
            generateSection
            if !publicKey.isEmpty { publicKeySection }
            Section("SSH 개인키 (PEM)") {
                TextEditor(text: $pem)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 160)
                Button("Files에서 가져오기") { showingImporter = true }
            }
            Section {
                Button("저장") { save() }
                if hasKey {
                    Button("삭제", role: .destructive) {
                        CredentialStore.shared.set(.sshPrivateKeyPEM, value: "")
                        CredentialStore.shared.set(.sshPublicKeyOpenSSH, value: "")
                        pem = ""; publicKey = ""; message = "삭제됨"
                    }
                }
            }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
            Section {
                Text(hasKey ? "키 저장됨 ✓" : "저장된 키 없음")
                    .foregroundStyle(hasKey ? .green : .secondary)
            }
        }
        .navigationTitle("SSH 키")
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.data, .text, UTType.item],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                    pem = text
                } else { message = "파일을 읽을 수 없습니다" }
            case .failure(let e): message = "가져오기 실패: \(e.localizedDescription)"
            }
        }
        .confirmationDialog("기존 키를 새 키로 교체할까요?",
                            isPresented: $showingReplaceConfirm,
                            titleVisibility: .visible) {
            Button("교체", role: .destructive) { generateKey() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("기존 키로 접속하던 서버 연결이 끊깁니다. 새 공개키를 서버에 다시 등록해야 해요.")
        }
    }

    private var generateSection: some View {
        Section("새 키 생성") {
            Button {
                if hasKey { showingReplaceConfirm = true } else { generateKey() }
            } label: {
                Label("새 키 생성 (Ed25519)", systemImage: "key.fill")
            }
            Text("이 기기에서 키를 만들고 개인키는 Keychain에만 보관합니다. 공개키를 서버 ~/.ssh/authorized_keys에 등록하세요.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var publicKeySection: some View {
        Section("공개키 (authorized_keys에 등록)") {
            Text(publicKey)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = publicKey
                message = "공개키 복사됨 ✓"
            } label: {
                Label("복사", systemImage: "doc.on.doc")
            }
            ShareLink(item: publicKey) {
                Label("공유", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func generateKey() {
        let device = UIDevice.current.name
        let sanitized = device.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { acc, ch in
                if ch == "-" && acc.hasSuffix("-") { return }
                acc.append(ch)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let comment = "hydra-\(sanitized.isEmpty ? "ios" : sanitized)"
        let key = SSHKeyGenerator.generate(comment: comment)
        CredentialStore.shared.set(.sshPrivateKeyPEM, value: key.privateKeyOpenSSH)
        CredentialStore.shared.set(.sshPublicKeyOpenSSH, value: key.publicKeyLine)
        pem = key.privateKeyOpenSSH
        publicKey = key.publicKeyLine
        message = "새 키 생성됨 ✓ — 공개키를 서버에 등록하세요"
    }

    private func save() {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("PRIVATE KEY-----") else {
            message = "PEM 개인키 형식이 아닙니다 (-----BEGIN ... PRIVATE KEY----- 필요)"
            return
        }
        let previous = CredentialStore.shared.get(.sshPrivateKeyPEM)
        CredentialStore.shared.set(.sshPrivateKeyPEM, value: trimmed)
        // 수동 붙여넣기로 키가 바뀌면 저장된 공개키는 더 이상 그 키의 짝이 아님
        if trimmed != previous {
            CredentialStore.shared.set(.sshPublicKeyOpenSSH, value: "")
            publicKey = ""
        }
        message = "저장됨 ✓"
    }
}
```

- [ ] **Step 3: xcodegen 재생성 + iOS 빌드 확인** (새 파일 SSHKeyGenerator.swift 포함 확인)

Run: `xcodegen generate 2>&1 | tail -2 && xcodebuild -project Hydra.xcodeproj -target HydraiOS -sdk iphonesimulator -arch arm64 CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED` (스킴이 필요하면 `-target` 대신 `-scheme HydraiOS -destination 'generic/platform=iOS Simulator'` 사용)

- [ ] **Step 4: macOS 리그레션 확인** (CredentialStore 변경이 mac 빌드/테스트에 영향 없는지)

Run: `swift build 2>&1 | tail -2 && swift test 2>&1 | tail -3`
Expected: `Build complete!`, 전체 테스트 `0 failures` (기존 실패가 있다면 이번 변경과 무관한지 확인해 보고)

- [ ] **Step 5: 커밋**

```bash
git add -A
git commit -m "feat(ios): KeyImportScreen에 Ed25519 키 생성 + 공개키 복사/공유"
```

---

## Self-Review 체크 결과

- 스펙 커버리지: 공유 생성기(Task 1), macOS 버튼+설치+덮어쓰기 금지(Task 2), iOS 생성/교체 확인/복사/공유/슬롯 동기화(Task 3), 오라클·권한·Locator 테스트(Task 1·2) — 스펙 전 항목 대응. Linux·자동 등록은 스펙대로 제외.
- 타입 일관성: `GeneratedKey.privateKeyOpenSSH/publicKeyLine`, `generateAndInstall(comment:sshDir:)`, `Key.sshPublicKeyOpenSSH` — 태스크 간 참조 일치 확인.
- 플레이스홀더 없음.
