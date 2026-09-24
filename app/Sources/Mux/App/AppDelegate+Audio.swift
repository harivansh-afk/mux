import AppKit

extension AppDelegate {
    func stopAudioSharing() {
        automaticAudio.stop()
    }

    @objc func toggleAudioSharing(_: Any?) {
        automaticAudio.enabled.toggle()
    }
}
