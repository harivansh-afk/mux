import AppKit

extension AppDelegate {
    func stopAudioSharing() {
        audioGeneration = UUID()
        audioSharing?.terminate()
        audioSharing = nil
    }

    @objc func toggleAudioSharing(_: Any?) {
        if audioSharing != nil {
            stopAudioSharing()
            return
        }
        guard let pane = controller?.activeSession?.focusedPane,
              let host = pane.daemon
        else { return }
        let generation = UUID()
        audioGeneration = generation
        audioStatus = "Could not start the bundled audio driver."
        audioSharing = Subprocess.Stream(
            Muxd.daemonBinary, ["audio", "\(host):\(pane.id.uuidString)"],
            onLine: { [weak self] line in
                guard let self, audioGeneration == generation else { return }
                audioStatus = String(line)
                AppLog.log("audio: \(line)")
            },
            onExit: { [weak self] in
                guard let self, audioGeneration == generation else { return }
                audioSharing = nil
                guard !isTerminating else { return }
                let alert = NSAlert()
                alert.messageText = "Audio sharing stopped"
                alert.informativeText = audioStatus
                alert.runModal()
            }
        )
        if audioSharing == nil {
            let alert = NSAlert()
            alert.messageText = "Audio sharing could not start"
            alert.informativeText = audioStatus
            alert.runModal()
        }
    }
}
