import Foundation

/// Availability follows the app; ownership follows an application's device open.
/// The helper reconnects a host provider without opening microphone hardware.
final class AutomaticAudio {
    private let defaults: UserDefaults
    private var hosts: Set<String> = []
    private var streams: [String: Subprocess.Stream] = [:]
    private var generation = UUID()
    private(set) var statuses: [String: String] = [:]
    private static let preference = "automaticRemoteAudio"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Self.preference: true])
    }

    var enabled: Bool {
        get { defaults.bool(forKey: Self.preference) }
        set {
            defaults.set(newValue, forKey: Self.preference)
            stop()
            if newValue {
                for host in hosts {
                    start(host)
                }
            }
        }
    }

    func watch(_ host: String) {
        hosts.insert(host)
        if enabled {
            start(host)
        }
    }

    func stop() {
        generation = UUID()
        streams.values.forEach { $0.terminate() }
        streams.removeAll()
        statuses.removeAll()
    }

    private func start(_ host: String) {
        guard streams[host] == nil else { return }
        let expected = generation
        statuses[host] = "Connecting Mac audio…"
        streams[host] = Subprocess.Stream(
            Muxd.daemonBinary, ["audio-auto", host],
            onLine: { [weak self] line in
                guard let self, generation == expected else { return }
                statuses[host] = String(line)
                AppLog.log("audio \(host): \(line)")
            },
            onExit: { [weak self] in
                guard let self, generation == expected else { return }
                streams[host] = nil
                statuses[host] = "Audio helper stopped; reconnecting…"
                retry(host, generation: expected)
            }
        )
        if streams[host] == nil {
            statuses[host] = "Could not start the bundled audio helper."
            retry(host, generation: expected)
        }
    }

    private func retry(_ host: String, generation expected: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, generation == expected, enabled else { return }
            start(host)
        }
    }
}
