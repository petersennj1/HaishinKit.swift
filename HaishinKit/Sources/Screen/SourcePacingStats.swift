import Foundation

/// How evenly the compositor is advancing through its source.
///
/// The composed frame rate answers "did a frame go out on time". This answers
/// the other half — "did that frame carry the next picture". They come apart
/// whenever the source runs faster than the compositor: a device capturing at
/// 60 into a display link at 30 can hand out a flawless 30.0 fps whose motion
/// still stutters, because the steps it takes through the source alternate
/// between one frame and three. Even output timing, uneven content. The spread
/// is what shows it, and nothing outside the compositor can see either number.
///
/// Written from the screen actor, read from anywhere.
final class SourcePacingStats: @unchecked Sendable {
    private let lock = NSLock()

    private var lastUsedPresentationTime: Double = 0
    private var windowStart: Double = 0
    private var windowMinStepMs: Double = .greatestFiniteMagnitude
    private var windowMaxStepMs: Double = 0
    private var windowStepTotalMs: Double = 0
    private var windowStepCount: Int = 0
    private var windowDropped: Int = 0

    private var _stepMs: Double = 0
    private var _stepSpreadMs: Double = 0
    private var _droppedPerSecond: Int = 0

    /// Mean milliseconds of source material between consecutive composited
    /// frames over the last second. At 30 fps out this sits near 33 whatever
    /// the source rate is — it is the spread that carries the information.
    var stepMs: Double {
        lock.lock(); defer { lock.unlock() }
        return _stepMs
    }

    /// Widest minus narrowest step in the last second. Near zero is even
    /// motion. A 60 fps source sampled out of phase by a 30 fps compositor
    /// alternates 17 ms and 50 ms steps and reads about 33 here — the
    /// signature of judder that every other counter calls healthy.
    var stepSpreadMs: Double {
        lock.lock(); defer { lock.unlock() }
        return _stepSpreadMs
    }

    /// Source frames refused by the track's input queue in the last second.
    /// The enqueue is a `try?` in the original: a full queue discards the
    /// frame and says nothing, and a discarded frame is a hole in the motion
    /// whether or not the output rate ever moves.
    var droppedPerSecond: Int {
        lock.lock(); defer { lock.unlock() }
        return _droppedPerSecond
    }

    /// A source frame the compositor drew. `presentationTime` is the source's
    /// own timeline, which is the only clock in which "how far did the picture
    /// advance" means anything.
    func noteUsed(presentationTime: Double, at hostTime: Double) {
        guard presentationTime.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        if lastUsedPresentationTime > 0 {
            let stepMs = (presentationTime - lastUsedPresentationTime) * 1000
            // A backwards or absurd step means the source restarted — a cut,
            // a new device, a reset clock. Skip it rather than let one
            // discontinuity define the window.
            if stepMs > 0, stepMs < 1000 {
                windowMinStepMs = min(windowMinStepMs, stepMs)
                windowMaxStepMs = max(windowMaxStepMs, stepMs)
                windowStepTotalMs += stepMs
                windowStepCount += 1
            }
        }
        lastUsedPresentationTime = presentationTime
        if windowStart == 0 { windowStart = hostTime }
        guard hostTime - windowStart >= 1 else { return }
        if windowStepCount > 0 {
            _stepMs = windowStepTotalMs / Double(windowStepCount)
            _stepSpreadMs = windowMaxStepMs - windowMinStepMs
        }
        _droppedPerSecond = windowDropped
        windowStart = hostTime
        windowMinStepMs = .greatestFiniteMagnitude
        windowMaxStepMs = 0
        windowStepTotalMs = 0
        windowStepCount = 0
        windowDropped = 0
    }

    /// A source frame the input queue would not take.
    func noteDropped() {
        lock.lock()
        windowDropped += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        lastUsedPresentationTime = 0
        lock.unlock()
    }
}
