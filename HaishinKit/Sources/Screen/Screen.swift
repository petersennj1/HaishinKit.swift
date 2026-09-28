import AVFoundation
import Foundation

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

/// An interface a screen uses to inform its delegate.
public protocol ScreenDelegate: AnyObject {
    /// Tells the receiver to screen object layout phase.
    func screen(_ screen: Screen, willLayout time: CMTime)
}

/// An object that manages offscreen rendering a foundation.
public final class Screen: ScreenObjectContainerConvertible {
    /// The default screen size.
    public static let size = CGSize(width: 1280, height: 720)

    private static let lockFlags = CVPixelBufferLockFlags(rawValue: 0)
    private static let preferredTimescale: CMTimeScale = 1000000000

    /// The total of child counts.
    public var childCounts: Int {
        return root.childCounts
    }

    /// Specifies the delegate object.
    public weak var delegate: (any ScreenDelegate)?

    /// Specifies the video size to use when output a video.
    public var size: CGSize = Screen.size {
        didSet {
            guard size != oldValue else {
                return
            }
            renderer.bounds = .init(origin: .zero, size: size)
            CVPixelBufferPoolCreate(nil, nil, dynamicRangeMode.makePixelBufferAttributes(size), &pixelBufferPool)
        }
    }

    /// Specifies the gpu rendering enabled.
    @available(*, deprecated)
    public var isGPURendererEnabled = false {
        didSet {
            guard isGPURendererEnabled != oldValue else {
                return
            }
            if isGPURendererEnabled {
                renderer = ScreenRendererByGPU(dynamicRangeMode: dynamicRangeMode)
            } else {
                renderer = ScreenRendererByCPU(dynamicRangeMode: dynamicRangeMode)
            }
        }
    }

    #if os(macOS)
    /// Specifies the background color.
    public var backgroundColor: CGColor = NSColor.black.cgColor {
        didSet {
            guard backgroundColor != oldValue else {
                return
            }
            renderer.backgroundColor = backgroundColor
        }
    }
    #else
    /// Specifies the background color.
    public var backgroundColor: CGColor = UIColor.black.cgColor {
        didSet {
            guard backgroundColor != oldValue else {
                return
            }
            renderer.backgroundColor = backgroundColor
        }
    }
    #endif

    var synchronizationClock: CMClock? {
        get {
            return renderer.synchronizationClock
        }
        set {
            renderer.synchronizationClock = newValue
        }
    }
    var dynamicRangeMode: DynamicRangeMode = .sdr {
        didSet {
            guard dynamicRangeMode != oldValue else {
                return
            }
            if isGPURendererEnabled {
                renderer = ScreenRendererByGPU(dynamicRangeMode: dynamicRangeMode)
            } else {
                renderer = ScreenRendererByCPU(dynamicRangeMode: dynamicRangeMode)
            }
            CVPixelBufferPoolCreate(nil, nil, dynamicRangeMode.makePixelBufferAttributes(size), &pixelBufferPool)
        }
    }
    private(set) var renderer: (any ScreenRenderer) = ScreenRendererByCPU(dynamicRangeMode: .sdr) {
        didSet {
            renderer.bounds = oldValue.bounds
            renderer.backgroundColor = oldValue.backgroundColor
            renderer.synchronizationClock = oldValue.synchronizationClock
        }
    }
    private(set) var targetTimestamp: TimeInterval = 0.0
    private(set) var videoTrackScreenObject = VideoTrackScreenObject()
    private var videoCaptureLatency: TimeInterval = 0.0
    private var root: ScreenObjectContainer = .init()
    private var outputFormat: CMFormatDescription?
    private var pixelBufferPool: CVPixelBufferPool? {
        didSet {
            outputFormat = nil
        }
    }
    private var presentationTimeStamp: CMTime = .zero

    /// Creates a screen object.
    public init() {
        videoTrackScreenObject.pacing = sourcePacing
        try? addChild(videoTrackScreenObject)
        CVPixelBufferPoolCreate(nil, nil, dynamicRangeMode.makePixelBufferAttributes(size), &pixelBufferPool)
    }

    /// Adds the specified screen object as a child of the current screen object container.
    public func addChild(_ child: ScreenObject?) throws {
        try root.addChild(child)
    }

    /// Removes the specified screen object as a child of the current screen object container.
    public func removeChild(_ child: ScreenObject?) {
        root.removeChild(child)
    }

    /// Registers a video effect.
    public func registerVideoEffect(_ effect: some VideoEffect) -> Bool {
        return videoTrackScreenObject.registerVideoEffect(effect)
    }

    /// Unregisters a video effect.
    public func unregisterVideoEffect(_ effect: some VideoEffect) -> Bool {
        return videoTrackScreenObject.unregisterVideoEffect(effect)
    }

    /// Smoothed milliseconds from a main-track frame's presentation timestamp
    /// to its arrival at the screen. For feeds whose frames are stamped at
    /// `MediaMixer.append` time this measures the mixer's internal delivery
    /// lag — the async-stream hop between append and compositing, which is
    /// otherwise invisible from outside. Readable from any thread.
    public nonisolated var deliveryLagMs: Double {
        deliveryLagLock.lock()
        defer { deliveryLagLock.unlock() }
        return _deliveryLagMs
    }

    private nonisolated(unsafe) var _deliveryLagMs: Double = 0
    private nonisolated let deliveryLagLock = NSLock()

    /// Frames per second actually composited and handed to the outputs, and
    /// the longest gap between two consecutive ones in the last second.
    ///
    /// A different question from the capture rate or the encoder's expected
    /// rate: this is what the encoder is really fed, and so what a viewer
    /// really watches. It is also the only place the number exists — a feed
    /// teed off the capture device never passes through here, which is why
    /// a recording can be clean while the stream is not. Counted from the
    /// moment the compositor starts, so it reads during preview, before
    /// anything is on air.
    public nonisolated var composedFrameRate: Double {
        frameRateLock.lock()
        defer { frameRateLock.unlock() }
        return _composedFrameRate
    }

    /// Milliseconds between the two most widely separated consecutive frames
    /// of the last second. At a steady 30 fps this sits near 33; a stall
    /// shows here long before the average moves off 30.
    public nonisolated var composedWorstGapMs: Double {
        frameRateLock.lock()
        defer { frameRateLock.unlock() }
        return _composedWorstGapMs
    }

    private nonisolated(unsafe) var _composedFrameRate: Double = 0
    private nonisolated(unsafe) var _composedWorstGapMs: Double = 0
    private nonisolated(unsafe) var frameWindowStart: Double = 0
    private nonisolated(unsafe) var frameWindowCount: Int = 0
    private nonisolated(unsafe) var lastComposedAt: Double = 0
    private nonisolated(unsafe) var windowWorstGapMs: Double = 0
    private nonisolated let frameRateLock = NSLock()

    /// How evenly the compositor advances through its source, and how many
    /// source frames its input queue refuses. Both read from any thread.
    public nonisolated var sourceStepMs: Double { sourcePacing.stepMs }
    public nonisolated var sourceStepSpreadMs: Double { sourcePacing.stepSpreadMs }
    public nonisolated var droppedInputFramesPerSecond: Int { sourcePacing.droppedPerSecond }

    private nonisolated let sourcePacing = SourcePacingStats()

    /// Depth of the main video track's input queue. See
    /// `VideoTrackScreenObject.inputCapacity`.
    public func setInputCapacity(_ capacity: Int) {
        videoTrackScreenObject.inputCapacity = capacity
    }

    /// One frame that will reach the outputs. Counted over a one-second
    /// window rather than smoothed, so the figure is a count of real frames
    /// and not an estimate of one.
    private nonisolated func noteComposedFrame(at timestamp: Double) {
        frameRateLock.lock()
        defer { frameRateLock.unlock() }
        if lastComposedAt > 0 {
            let gapMs = (timestamp - lastComposedAt) * 1000
            if gapMs > windowWorstGapMs { windowWorstGapMs = gapMs }
        }
        lastComposedAt = timestamp
        if frameWindowStart == 0 { frameWindowStart = timestamp }
        frameWindowCount += 1
        let elapsed = timestamp - frameWindowStart
        guard elapsed >= 1 else { return }
        _composedFrameRate = Double(frameWindowCount) / elapsed
        _composedWorstGapMs = windowWorstGapMs
        frameWindowStart = timestamp
        frameWindowCount = 0
        windowWorstGapMs = 0
    }

    func append(_ track: UInt8, buffer: CMSampleBuffer) {
        if track == videoTrackScreenObject.track {
            let lagMs = (CMClockGetTime(CMClockGetHostTimeClock()).seconds
                - buffer.presentationTimeStamp.seconds) * 1000
            if lagMs.isFinite, lagMs > -100, lagMs < 60_000 {
                deliveryLagLock.lock()
                _deliveryLagMs = _deliveryLagMs * 0.9 + lagMs * 0.1
                deliveryLagLock.unlock()
            }
        }
        if !accepts(buffer, on: track) {
            return
        }
        let screens: [VideoTrackScreenObject] = root.getScreenObjects()
        for screen in screens where screen.track == track {
            screen.enqueue(buffer)
        }
    }

    /// Whether a source frame should reach the compositor at all.
    ///
    /// A source running faster than the composite rate has to be thinned
    /// somewhere. Left alone it is thinned by the render itself, which asks
    /// "which frames are due by now" against a clock that is not the source's
    /// — and the boundary between two-frames-due and one-or-three wanders as
    /// the two clocks drift. The output frame rate stays perfect while the
    /// picture advances in steps of one source frame and then three: even
    /// timing, uneven motion.
    ///
    /// Thinning it here instead, in the source's own presentation time, makes
    /// every step the same size. What drift then costs is a repeated or
    /// skipped frame once the two clocks have slipped a whole period apart —
    /// minutes, against several stutters a second.
    ///
    /// A no-op for a source already arriving at the composite rate: its steps
    /// clear the threshold, so nothing is refused.
    private func accepts(_ buffer: CMSampleBuffer, on track: UInt8) -> Bool {
        guard sourcePacingInterval > 0 else { return true }
        let presentationTime = buffer.presentationTimeStamp.seconds
        guard presentationTime.isFinite else { return true }
        if let last = lastAcceptedPresentationTime[track] {
            let step = presentationTime - last
            // Backwards or absurd means a new source — a cut, a reset clock.
            // Take the frame and start the cadence again from it.
            if step > 0, step < sourcePacingInterval * 0.75 {
                return false
            }
        }
        lastAcceptedPresentationTime[track] = presentationTime
        return true
    }

    /// Thin every source down to this rate before compositing. Zero disables
    /// it and restores the render-time selection.
    public func setSourcePacing(frameRate: Double) {
        sourcePacingInterval = frameRate > 0 ? 1 / frameRate : 0
        lastAcceptedPresentationTime.removeAll()
    }

    private var sourcePacingInterval: Double = 0
    private var lastAcceptedPresentationTime: [UInt8: Double] = [:]

    func makeSampleBuffer(_ updateFrame: DisplayLinkTime) -> CMSampleBuffer? {
        defer {
            targetTimestamp = updateFrame.targetTimestamp
        }
        var pixelBuffer: CVPixelBuffer?
        pixelBufferPool?.createPixelBuffer(&pixelBuffer)
        guard let pixelBuffer else {
            return nil
        }
        if outputFormat == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &outputFormat
            )
        }
        guard let outputFormat else {
            return nil
        }
        if let dictionary = CVBufferCopyAttachments(pixelBuffer, .shouldNotPropagate) {
            CVBufferSetAttachments(pixelBuffer, dictionary, .shouldPropagate)
        }
        let presentationTimeStamp = CMTime(seconds: updateFrame.timestamp - videoCaptureLatency, preferredTimescale: Self.preferredTimescale)
        guard self.presentationTimeStamp <= presentationTimeStamp else {
            return nil
        }
        self.presentationTimeStamp = presentationTimeStamp
        // Past every early return above: only a frame that will actually be
        // handed onward is worth counting.
        noteComposedFrame(at: updateFrame.timestamp)
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(seconds: updateFrame.targetTimestamp - updateFrame.timestamp, preferredTimescale: Self.preferredTimescale),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: outputFormat,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        if let sampleBuffer {
            return render(sampleBuffer)
        } else {
            return nil
        }
    }

    func render(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        try? sampleBuffer.imageBuffer?.lockBaseAddress(Self.lockFlags)
        defer {
            try? sampleBuffer.imageBuffer?.unlockBaseAddress(Self.lockFlags)
        }
        renderer.presentationTimeStamp = sampleBuffer.presentationTimeStamp
        renderer.setTarget(sampleBuffer.imageBuffer)
        if let dimensions = sampleBuffer.formatDescription?.dimensions {
            root.size = dimensions.size
        }
        delegate?.screen(self, willLayout: sampleBuffer.presentationTimeStamp)
        root.layout(renderer)
        root.draw(renderer)
        renderer.render()
        return sampleBuffer
    }

    func setVideoCaptureLatency(_ presentationTimeStamp: CMTime) {
        guard 0 < targetTimestamp else {
            return
        }
        let hostPresentationTimeStamp = presentationTimeStamp.convertTime(from: synchronizationClock)
        let diff = ceil((targetTimestamp - hostPresentationTimeStamp.seconds) * 10000) / 10000
        videoCaptureLatency = diff
    }

    func reset() {
        let screens: [VideoTrackScreenObject] = root.getScreenObjects()
        for screen in screens {
            screen.reset()
        }
        // BenchMarks: the timing state goes too, or it outlives the stop.
        //
        // `targetTimestamp` is only updated at the end of a composed frame, so
        // after a stop it still holds the last tick from BEFORE. On a restart
        // the camera's first frame arrives before the display link's first new
        // tick, and `setVideoCaptureLatency` measured it against that stale
        // target: a latency of minus however long the mixer was stopped. That
        // stamps one frame that far in the FUTURE, it is composed, and
        // `presentationTimeStamp` — the never-go-backwards mark — lands that
        // far ahead. Every correct frame after it is then "older" and refused,
        // until real time catches up. Measured on an iPad after an 11 s trip
        // to the background: one frame at return with a 10,878 ms gap, then
        // 318 frames refused and nothing composed for ~11 s, then recovery.
        //
        // Zero target also means `setVideoCaptureLatency` does nothing until a
        // fresh tick has set a real one — so the first latency after a restart
        // is measured against the present, never the past.
        presentationTimeStamp = .zero
        targetTimestamp = 0
        videoCaptureLatency = 0
    }
}
