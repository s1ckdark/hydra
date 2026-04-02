import Foundation

/// Stores per-device display preferences: custom order and visibility.
/// Persisted in UserDefaults as a lightweight JSON array.
final class DevicePreferences: ObservableObject {
    static let shared = DevicePreferences()

    @Published private(set) var entries: [Entry] = []

    struct Entry: Codable, Identifiable {
        let deviceId: String
        var visible: Bool
        var sortOrder: Int

        var id: String { deviceId }
    }

    private let key = "devicePreferences"

    private init() {
        load()
    }

    // MARK: - Public API

    /// Merge server devices with stored preferences.
    /// New devices get appended at the end as visible.
    func merge(deviceIds: [String]) {
        let existing = Dictionary(uniqueKeysWithValues: entries.map { ($0.deviceId, $0) })
        var merged: [Entry] = []
        var order = 0

        // Preserve stored order for known devices
        for entry in entries {
            if deviceIds.contains(entry.deviceId) {
                var e = entry
                e.sortOrder = order
                merged.append(e)
                order += 1
            }
        }

        // Append new devices
        for id in deviceIds where existing[id] == nil {
            merged.append(Entry(deviceId: id, visible: true, sortOrder: order))
            order += 1
        }

        entries = merged
        save()
    }

    /// Apply ordering and filtering to a device list.
    func apply<T: Identifiable>(to devices: [T], id keyPath: KeyPath<T, String>) -> [T] {
        let orderMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.deviceId, $0) })
        let hiddenIds = Set(entries.filter { !$0.visible }.map(\.deviceId))

        return devices
            .filter { !hiddenIds.contains($0[keyPath: keyPath]) }
            .sorted { a, b in
                let oa = orderMap[a[keyPath: keyPath]]?.sortOrder ?? Int.max
                let ob = orderMap[b[keyPath: keyPath]]?.sortOrder ?? Int.max
                return oa < ob
            }
    }

    func isVisible(_ deviceId: String) -> Bool {
        entries.first { $0.deviceId == deviceId }?.visible ?? true
    }

    func setVisible(_ deviceId: String, visible: Bool) {
        guard let idx = entries.firstIndex(where: { $0.deviceId == deviceId }) else { return }
        entries[idx].visible = visible
        save()
    }

    func moveUp(_ deviceId: String) {
        guard let idx = entries.firstIndex(where: { $0.deviceId == deviceId }), idx > 0 else { return }
        entries.swapAt(idx, idx - 1)
        reindex()
    }

    func moveDown(_ deviceId: String) {
        guard let idx = entries.firstIndex(where: { $0.deviceId == deviceId }),
              idx < entries.count - 1 else { return }
        entries.swapAt(idx, idx + 1)
        reindex()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var arr = entries
        arr.move(fromOffsets: source, toOffset: destination)
        entries = arr
        reindex()
    }

    // MARK: - Persistence

    private func reindex() {
        for i in entries.indices {
            entries[i].sortOrder = i
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = decoded
    }
}
