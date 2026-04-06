import Foundation
import Network

@MainActor
final class ServerDiscovery: ObservableObject {
    @Published var discoveredServers: [DiscoveredServer] = []
    @Published var isSearching = false

    private var browser: NWBrowser?

    struct DiscoveredServer: Identifiable, Hashable {
        let id: String  // endpoint description
        let name: String
        let host: String
        let port: UInt16

        var url: String { "http://\(host):\(port)" }
    }

    func startDiscovery() {
        isSearching = true
        discoveredServers = []

        let params = NWParameters()
        params.includePeerToPeer = true

        browser = NWBrowser(for: .bonjour(type: "_naga._tcp", domain: nil), using: params)

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                // For each result, resolve to get host/port
                for result in results {
                    if case .service(let name, let type, let domain, _) = result.endpoint {
                        self.resolveService(name: name, type: type, domain: domain)
                    }
                }
            }
        }

        browser?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    break
                case .failed(let error):
                    print("Browser failed: \(error)")
                    self?.isSearching = false
                default:
                    break
                }
            }
        }

        browser?.start(queue: .main)

        // Stop searching after 5 seconds timeout
        Task {
            try? await Task.sleep(for: .seconds(5))
            if self.isSearching {
                self.stopDiscovery()
            }
        }
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    private func resolveService(name: String, type: String, domain: String) {
        // Use NWConnection to resolve the endpoint
        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        let connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                if let innerEndpoint = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = innerEndpoint {
                    let hostStr: String
                    switch host {
                    case .ipv4(let addr):
                        hostStr = "\(addr)"
                    case .ipv6(let addr):
                        hostStr = "\(addr)"
                    case .name(let name, _):
                        hostStr = name
                    @unknown default:
                        hostStr = "\(host)"
                    }
                    let server = DiscoveredServer(
                        id: "\(name)-\(hostStr):\(port.rawValue)",
                        name: name,
                        host: hostStr,
                        port: port.rawValue
                    )
                    Task { @MainActor in
                        if self?.discoveredServers.contains(server) == false {
                            self?.discoveredServers.append(server)
                        }
                    }
                }
                connection.cancel()
            }
        }
        connection.start(queue: .main)
    }
}
