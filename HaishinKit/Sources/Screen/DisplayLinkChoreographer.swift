import Foundation
import QuartzCore

#if os(macOS)
import CoreVideo

// swiftlint:disable attributes
// CADisplayLink is deprecated, I've given up on making it conform to Sendable.
final class DisplayLink: NSObject, @unchecked Sendable {
    private static let preferredFramesPerSecond = 0

    var isPaused = false {
        didSet {
            guard let displayLink, oldValue != isPaused else {
                return
            }
            if isPaused {
                CVDisplayLinkStop(displayLink)
            } else {
                CVDisplayLinkStart(displayLink)
            }
        }
    }
    var preferredFramesPerSecond = DisplayLink.preferredFramesPerSecond {
        didSet {
            guard preferredFramesPerSecond != oldValue else {
                return
            }
            frameInterval = 1.0 / Double(preferredFramesPerSecond)
        }
    }
    private(set) var duration = 0.0
    private(set) var timestamp: CFTimeInterval = 0
    private(set) var targetTimestamp: CFTimeInterval = 0
    private var selector: Selector?
    private var displayLink: CVDisplayLink?
    private var frameInterval = 0.0
    private weak var delegate: NSObject?

    deinit {
        selector = nil
    }

    init(target: NSObject, selector sel: Selector) {
        super.init()
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink = displayLink else {
            return
        }
        self.delegate = target
        self.selector = sel
        CVDisplayLinkSetOutputHandler(displayLink) { [weak self] _, inNow, _, _, _ -> CVReturn in
            guard let self else {
                return kCVReturnSuccess
            }
            if frameInterval == 0 || frameInterval <= inNow.pointee.timestamp - self.timestamp {
                self.timestamp = Double(inNow.pointee.timestamp)
                self.targetTimestamp = self.timestamp + frameInterval
                _ = self.delegate?.perform(self.selector, with: self)
            }
            return kCVReturnSuccess
        }
    }

    func add(to runloop: RunLoop, forMode mode: RunLoop.Mode) {
        guard let displayLink, !isPaused else {
            return
        }
        CVDisplayLinkStart(displayLink)
    }

    func invalidate() {
        guard let displayLink, isPaused else {
            return
        }
        CVDisplayLinkStop(displayLink)
    }
}

extension CVTimeStamp {
    @inlinable @inline(__always)
    var timestamp: Double {
        Double(self.hostTime) / Double(self.videoTimeScale)
    }
}

// swiftlint:enable attributes

#else
typealias DisplayLink = CADisplayLink
#endif

struct DisplayLinkTime {
    let timestamp: TimeInterval
    let targetTimestamp: TimeInterval
}

final class DisplayLinkChoreographer: NSObject {
    private static let preferredFramesPerSecond = 0

    /// Drive composition from a timer on a dedicated queue instead of a
    /// display link on the main run loop.
    ///
    /// The display link is added to `.main`, so every composited frame is
    /// scheduled behind the app's own UI work — layout, text, meters, a score
    /// bug being redrawn. An app whose interface is quiet never notices; an
    /// operator's desk with a running clock and live meters starves it, and
    /// the output rate falls at random with the device stone cold. Nothing
    /// here is being shown on the display, so there is nothing to synchronise
    /// with: what the encoder wants is an even clock that no view can block.
    ///
    /// Left settable so it can be turned off in the field, and because a
    /// timer only became safe once fast sources were thinned in their own
    /// presentation time — before that, a free clock aliased against them.
    static var usesSteadyClock: Bool {
        get { steadyClockLock.withLock { _usesSteadyClock } }
        set { steadyClockLock.withLock { _usesSteadyClock = newValue } }
    }

    private nonisolated(unsafe) static var _usesSteadyClock = true
    private static let steadyClockLock = NSLock()

    var updateFrames: AsyncStream<DisplayLinkTime> {
        AsyncStream { continuation in
            self.continutation = continuation
        }
    }
    var preferredFramesPerSecond = DisplayLinkChoreographer.preferredFramesPerSecond {
        didSet {
            guard preferredFramesPerSecond != oldValue else {
                return
            }
            displayLink?.preferredFramesPerSecond = preferredFramesPerSecond
            guard timer != nil else { return }
            timer?.cancel()
            timer = nil
            startSteadyClock()
        }
    }
    private(set) var isRunning = false
    private var displayLink: DisplayLink? {
        didSet {
            oldValue?.invalidate()
            displayLink?.preferredFramesPerSecond = preferredFramesPerSecond
            displayLink?.isPaused = false
            displayLink?.add(to: .main, forMode: .common)
        }
    }
    private var continutation: AsyncStream<DisplayLinkTime>.Continuation?
    /// The steady clock, and the queue it beats on. `userInteractive` because
    /// a late frame here is a frame the viewer does not get.
    private var timer: DispatchSourceTimer?
    private let clockQueue = DispatchQueue(
        label: "HaishinKit.SteadyFrameClock", qos: .userInteractive
    )

    @objc
    private func update(displayLink: DisplayLink) {
        continutation?.yield(.init(timestamp: displayLink.timestamp, targetTimestamp: displayLink.targetTimestamp))
    }
}

extension DisplayLinkChoreographer: Runner {
    func startRunning() {
        guard !isRunning else {
            return
        }
        if Self.usesSteadyClock {
            startSteadyClock()
        } else {
            displayLink = DisplayLink(target: self, selector: #selector(self.update(displayLink:)))
        }
        isRunning = true
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        isRunning = false
        timer?.cancel()
        timer = nil
        displayLink = nil
        continutation?.finish()
    }

    /// A frame every interval, on our own queue.
    ///
    /// The timestamps are computed from the schedule rather than read from
    /// the moment the handler happened to run, so a late beat still reports
    /// the time it was due — the composited presentation timestamps stay
    /// evenly spaced even when a beat is delivered late.
    private func startSteadyClock() {
        let rate = preferredFramesPerSecond > 0 ? Double(preferredFramesPerSecond) : 60
        let interval = 1.0 / rate
        let start = CACurrentMediaTime()
        var beat = 0
        let timer = DispatchSource.makeTimerSource(queue: clockQueue)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            beat += 1
            let timestamp = start + Double(beat) * interval
            self.continutation?.yield(
                .init(timestamp: timestamp, targetTimestamp: timestamp + interval)
            )
        }
        self.timer = timer
        timer.resume()
    }
}
