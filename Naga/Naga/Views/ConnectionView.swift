import SwiftUI

struct ConnectionView: View {
    @StateObject private var discovery = ServerDiscovery()
    @State private var connectionState: ConnectionState = .discovering
    @State private var manualURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    @State private var errorMessage: String?

    let onConnected: () -> Void

    enum ConnectionState {
        case discovering
        case connecting
        case manual
        case error(String)
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "server.rack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Naga")
                .font(.largeTitle.bold())

            switch connectionState {
            case .discovering:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("서버를 찾고 있습니다...")
                        .foregroundStyle(.secondary)
                }

                if !discovery.discoveredServers.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(discovery.discoveredServers) { server in
                            Button {
                                connectTo(server.url)
                            } label: {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text(server.name)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Text(server.url)
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 8)
                }

            case .connecting:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("연결 중...")
                        .foregroundStyle(.secondary)
                }

            case .manual:
                VStack(spacing: 12) {
                    Text("서버를 찾을 수 없습니다")
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("서버 URL", text: $manualURL)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS)
                            .autocapitalization(.none)
                            .keyboardType(.URL)
                            #endif

                        Button("연결") {
                            connectTo(manualURL)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manualURL.isEmpty)
                    }
                    .frame(maxWidth: 400)
                }

            case .error(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.orange)
                    Text(msg)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button("다시 시도") {
                            startDiscovery()
                        }
                        Button("직접 입력") {
                            connectionState = .manual
                        }
                    }
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            startDiscovery()
        }
    }

    private func startDiscovery() {
        connectionState = .discovering

        // First try saved URL
        let savedURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        if !savedURL.isEmpty && savedURL != "http://localhost:8080" {
            connectTo(savedURL)
            return
        }

        // Also try localhost
        connectTo("http://localhost:8080")

        // Start Bonjour discovery in parallel
        discovery.startDiscovery()

        // If nothing found after discovery completes, show manual
        Task {
            try? await Task.sleep(for: .seconds(6))
            if case .discovering = connectionState {
                connectionState = .manual
            }
        }
    }

    private func connectTo(_ urlString: String) {
        connectionState = .connecting

        Task {
            do {
                await APIClient.shared.setBaseURL(urlString)
                let response = try await APIClient.shared.authMe()
                if response.authenticated {
                    discovery.stopDiscovery()
                    onConnected()
                } else {
                    connectionState = .error("인증에 실패했습니다")
                }
            } catch {
                // If this was a background attempt, don't show error yet
                if case .connecting = connectionState {
                    connectionState = .manual
                    manualURL = urlString
                }
            }
        }
    }
}
