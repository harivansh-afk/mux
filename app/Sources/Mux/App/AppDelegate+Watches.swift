import Foundation

extension AppDelegate {
    /// One stream per host for the whole app, independent of window count.
    func watch(_ host: String?) {
        guard GhosttyRuntime.shared != nil else { return }
        if let host {
            automaticAudio.watch(host)
        }
        guard watches[host] == nil else { return }
        watches[host] = Muxd.Watch(host: host) { [weak self] event in
            guard let self, !isTerminating, let id = UUID(uuidString: event.name) else { return }
            var changed = false
            for controller in controllers {
                if event.exited, controller.closedPanes.remove(id, on: host) {
                    changed = true
                }
                controller.pane(id, on: host)?.apply(agent: event.agent, cwd: event.cwd)
            }
            if event.exited {
                for index in closedWindows.indices {
                    let count = closedWindows[index].closedPanes?.count
                    closedWindows[index].closedPanes?.removeAll { $0.id == id && $0.pane.daemon == host }
                    changed = changed || count != closedWindows[index].closedPanes?.count
                }
            }
            if changed {
                saveSnapshot()
            }
        }
    }

    func stopWatches() {
        watches.values.forEach { $0.stop() }
        watches.removeAll()
    }
}
