import CoreImage
import CoreMedia
import Foundation

protocol VideoMixerDelegate: AnyObject {
    func videoMixer(_ videoMixer: VideoMixer<Self>, track: UInt8, didInput sampleBuffer: CMSampleBuffer)
    func videoMixer(_ videoMixer: VideoMixer<Self>, didOutput sampleBuffer: CMSampleBuffer)
}

private let kVideoMixer_lockFlags = CVPixelBufferLockFlags(rawValue: .zero)

/// Mixes video tracks from every source feeding the session.
///
/// This type is reached from more than one thread and must serialise its own
/// state. Two writers exist and neither is aware of the other:
///
/// * `VideoDeviceUnit.captureOutput(_:didOutput:from:)` calls `append` straight
///   off AVFoundation's capture queue.
/// * `MediaMixer.append(_:track:)` — the public API for external frames — calls
///   it from the `MediaMixer` actor's executor.
///
/// `MediaMixer` being an actor serialises the second path against itself but
/// does nothing about the first, so an app that mixes captured video with
/// appended video has two threads mutating `inputFormats` at once. That
/// corrupts the dictionary, and the next read sends a message to whatever the
/// freed storage now holds: `doesNotRecognizeSelector`, SIGABRT, inside
/// `Dictionary._Variant.setValue(_:forKey:)`. It reproduces within minutes of
/// running a local camera alongside remote sources.
///
/// The lock is not held across the delegate callouts — those hand the buffer
/// to an `AsyncStream` and must not be serialised behind mixer state.
final class VideoMixer<T: VideoMixerDelegate> {
    weak var delegate: T?

    var settings: VideoMixerSettings {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _settings
        }
        set {
            lock.lock()
            _settings = newValue
            lock.unlock()
        }
    }

    var inputFormats: [UInt8: CMFormatDescription] {
        lock.lock()
        defer { lock.unlock() }
        return _inputFormats
    }

    private let lock = NSLock()
    private var _settings: VideoMixerSettings = .default
    private var _inputFormats: [UInt8: CMFormatDescription] = [:]
    private var currentPixelBuffer: CVPixelBuffer?

    func append(_ track: UInt8, sampleBuffer: CMSampleBuffer) {
        lock.lock()
        _inputFormats[track] = sampleBuffer.formatDescription
        let settings = _settings
        lock.unlock()

        delegate?.videoMixer(self, track: track, didInput: sampleBuffer)

        switch settings.mode {
        case .offscreen:
            break
        case .passthrough:
            if settings.mainTrack == track {
                outputSampleBuffer(sampleBuffer, isMuted: settings.isMuted)
            }
        }
    }

    func reset(_ track: UInt8) {
        lock.lock()
        _inputFormats[track] = nil
        lock.unlock()
    }

    /// Only ever reached from `append` on the passthrough path, so
    /// `currentPixelBuffer` is confined to whichever thread is appending the
    /// main track. `isMuted` is passed in from the snapshot taken above rather
    /// than re-read, so one append sees one consistent set of settings.
    @inline(__always)
    private func outputSampleBuffer(_ sampleBuffer: CMSampleBuffer, isMuted: Bool) {
        defer {
            currentPixelBuffer = sampleBuffer.imageBuffer
        }
        guard isMuted else {
            delegate?.videoMixer(self, didOutput: sampleBuffer)
            return
        }
        do {
            try sampleBuffer.imageBuffer?.mutate(kVideoMixer_lockFlags) { imageBuffer in
                try imageBuffer.copy(currentPixelBuffer)
            }
            delegate?.videoMixer(self, didOutput: sampleBuffer)
        } catch {
            logger.warn(error)
        }
    }
}
