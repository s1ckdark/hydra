#if DEBUG
import SwiftUI
import KnownHosts

/// Local filesystem-only diagnostic. No SSH credentials or host records are logged.
struct SSHTrustStorageDiagnosticScreen: View {
    @State private var summary = "저장소 확인 중…"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("서버 접속 없이 이 기기의 파일 저장만 확인합니다.")
                Text(summary).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }.padding()
        }
        .navigationTitle("신뢰 기록 저장소 점검")
        .task { runProbe() }
    }

    @MainActor private func runProbe() {
        var results: [[String: Any]] = []
        func record(_ stage: String, action: () throws -> Void) {
            do {
                try action()
                results.append(["stage": stage, "status": "ok"])
            } catch {
                var reasons: [[String: Any]] = []
                var next: NSError? = error as NSError
                for _ in 0..<3 {
                    guard let reason = next else { break }
                    reasons.append(["domain": reason.domain, "code": reason.code])
                    next = reason.userInfo[NSUnderlyingErrorKey] as? NSError
                }
                results.append(["stage": stage, "status": "error", "reasons": reasons])
            }
        }
        record("legacy-app-root-create") {
            let scratch = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".hydra-storage-probe-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            try FileManager.default.removeItem(at: scratch)
        }
        let entry = KnownHostsEntry(hostPattern: "storage-probe.invalid", keyType: "ssh-ed25519", publicKey: "AAAA")
        record("production-store-read") {
            _ = try SSHKnownHostsStorage.makeStore().check(entry)
        }
        record("application-support-write-append-read") {
            let scratch = SSHKnownHostsStorage.defaultURL.deletingLastPathComponent()
                .appendingPathComponent("qa-\(UUID().uuidString).known_hosts")
            defer { try? FileManager.default.removeItem(at: scratch) }
            let store = KnownHostsStore(fileURL: scratch)
            try store.trust(entry)
            try store.trust(.init(hostPattern: "second-probe.invalid", keyType: "ssh-ed25519", publicKey: "BBBB"))
            guard try KnownHostsStore(fileURL: scratch).check(entry) == .match else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        let report: [String: Any] = ["protectedDataAvailable": UIApplication.shared.isProtectedDataAvailable,
            "storage": "Library/Application Support/Hydra/SSH/known_hosts", "checks": results]
        do {
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            let reportURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ssh-trust-storage-diagnostic.json")
            try bytes.write(to: reportURL, options: .atomic)
            summary = String(decoding: bytes, as: UTF8.self)
        } catch {
            let reason = error as NSError
            summary = "진단 보고서 저장 실패: \(reason.domain) \(reason.code)"
        }
    }
}
#endif
