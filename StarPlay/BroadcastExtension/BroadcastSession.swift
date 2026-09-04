import CoreMedia
import Foundation
import ReplayKit
import UIKit

final class BroadcastSession {
    var onHostStopRequested: (() -> Void)?
    var onFatalError: ((Error) -> Void)?

    private let session: VideoStreamSession
    private var stopObserver: UnsafeMutableRawPointer?

    init() {
        let name = UIDevice.current.name
        session = VideoStreamSession(deviceName: name)
        session.onStopRequested = { [weak self] in
            self?.onHostStopRequested?()
        }
        session.onFatalError = { [weak self] error in
            self?.onFatalError?(error)
        }
        installStopObserver()
    }

    deinit {
        removeStopObserver()
        session.stop()
    }

    func start() {
        session.start()
    }

    func pause() {
        session.pause()
    }

    func resume() {
        session.resume()
    }

    func stop() {
        session.stop()
    }

    func processVideo(_ sampleBuffer: CMSampleBuffer) {
        session.processVideo(sampleBuffer)
    }

    func processAudio(_ sampleBuffer: CMSampleBuffer) {
        session.processAudio(sampleBuffer)
    }

    private func installStopObserver() {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        stopObserver = pointer
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            pointer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let session = Unmanaged<BroadcastSession>.fromOpaque(observer).takeUnretainedValue()
                session.onHostStopRequested?()
            },
            BroadcastControlChannel.stopNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func removeStopObserver() {
        guard let stopObserver else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            stopObserver,
            CFNotificationName(rawValue: BroadcastControlChannel.stopNotification as CFString),
            nil
        )
        self.stopObserver = nil
    }
}
