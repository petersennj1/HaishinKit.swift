import AVFoundation
import CoreImage

/// An object that manages offscreen rendering a video track source.
public final class VideoTrackScreenObject: ScreenObject, ChromaKeyProcessable {
    static let capacity: Int = 3
    public var chromaKeyColor: CGColor?

    /// Specifies the track number how the displays the visual content.
    public var track: UInt8 = 0 {
        didSet {
            guard track != oldValue else {
                return
            }
            invalidateLayout()
        }
    }

    /// A value that specifies how the video is displayed within a player layer’s bounds.
    public var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet {
            guard videoGravity != oldValue else {
                return
            }
            invalidateLayout()
        }
    }

    /// The frame rate.
    public var frameRate: Int {
        frameTracker.frameRate
    }

    override var blendMode: ScreenObject.BlendMode {
        if 0.0 < cornerRadius || chromaKeyColor != nil {
            return .alpha
        }
        return .normal
    }

    /// How many source frames the input queue will hold.
    ///
    /// Three is enough for a source running at the compositor's own rate, and
    /// tight for one running at twice it: two frames land per composite, so a
    /// single late render is all it takes to present a third and have it
    /// discarded. Configurable so a 60 fps device feeding a 30 fps composite
    /// can be given headroom without changing anything for a source that
    /// never needed it. Depth costs no latency here — frames are dequeued by
    /// presentation time, not by arrival order.
    var inputCapacity: Int = capacity {
        didSet {
            guard inputCapacity != oldValue, inputCapacity > 0 else { return }
            queue = try? TypedBlockQueue(capacity: inputCapacity, handlers: .outputPTSSortedSampleBuffers)
        }
    }

    /// Set by the screen so pacing can be read from outside the actor.
    var pacing: SourcePacingStats?

    private var queue: TypedBlockQueue<CMSampleBuffer>?
    private var effects: [any VideoEffect] = .init()
    private var frameTracker = FrameTracker()
    /// The last frame shown, held so a momentary gap in the queue draws it
    /// again instead of drawing nothing.
    ///
    /// Two gaps exist by construction. Retargeting `track` — a switcher cut —
    /// leaves the queue holding the old track's frames; one render drains
    /// them and the next has nothing until the new track's first frame lands,
    /// which painted the background through the object as a black flash on
    /// every cut. And a producer that pauses (a held replay frame) stops
    /// refilling the queue within three renders. A broadcast surface should
    /// hold the last picture across both; `reset()` still clears it so a
    /// deliberate teardown goes dark rather than freezing.
    private var heldPixelBuffer: CVPixelBuffer?

    /// Create a screen object.
    override public init() {
        super.init()
        do {
            queue = try TypedBlockQueue(capacity: Self.capacity, handlers: .outputPTSSortedSampleBuffers)
        } catch {
            logger.error(error)
        }
        Task {
            horizontalAlignment = .center
        }
    }

    /// Registers a video effect.
    public func registerVideoEffect(_ effect: some VideoEffect) -> Bool {
        if effects.contains(where: { $0 === effect }) {
            return false
        }
        effects.append(effect)
        return true
    }

    /// Unregisters a video effect.
    public func unregisterVideoEffect(_ effect: some VideoEffect) -> Bool {
        if let index = effects.firstIndex(where: { $0 === effect }) {
            effects.remove(at: index)
            return true
        }
        return false
    }

    override public func makeImage(_ renderer: some ScreenRenderer) -> CGImage? {
        guard let image: CIImage = makeImage(renderer) else {
            return nil
        }
        return renderer.context.createCGImage(image, from: videoGravity.region(bounds, image: image.extent))
    }

    override public func makeImage(_ renderer: some ScreenRenderer) -> CIImage? {
        let presentationTimeStamp = renderer.presentationTimeStamp.convertTime(from: CMClockGetHostTimeClock(), to: renderer.synchronizationClock)
        guard let sampleBuffer = queue?.dequeue(presentationTimeStamp),
              let pixelBuffer = sampleBuffer.imageBuffer else {
            // Bridge the gap with the last frame rather than draw nothing.
            guard let heldPixelBuffer else {
                return nil
            }
            return makeImage(from: heldPixelBuffer, renderer)
        }
        heldPixelBuffer = pixelBuffer
        frameTracker.update(sampleBuffer.presentationTimeStamp)
        pacing?.noteUsed(
            presentationTime: sampleBuffer.presentationTimeStamp.seconds,
            at: CMClockGetTime(CMClockGetHostTimeClock()).seconds
        )
        return makeImage(from: pixelBuffer, renderer)
    }

    private func makeImage(from pixelBuffer: CVPixelBuffer, _ renderer: some ScreenRenderer) -> CIImage? {
        // Resizing before applying the filter for performance optimization.
        var image = CIImage(cvPixelBuffer: pixelBuffer, options: renderer.imageOptions).transformed(by: videoGravity.scale(
            bounds.size,
            image: pixelBuffer.size
        ))
        if effects.isEmpty {
            return image
        } else {
            for effect in effects {
                image = effect.execute(image)
            }
            return image
        }
    }

    override public func makeBounds(_ size: CGSize) -> CGRect {
        guard parent != nil, let image = queue?.head?.formatDescription?.dimensions.size else {
            return super.makeBounds(size)
        }
        let bounds = super.makeBounds(size)
        switch videoGravity {
        case .resizeAspect:
            let scale = min(bounds.size.width / image.width, bounds.size.height / image.height)
            let scaleSize = CGSize(width: image.width * scale, height: image.height * scale)
            return super.makeBounds(scaleSize)
        case .resizeAspectFill:
            return bounds
        default:
            return bounds
        }
    }

    override public func draw(_ renderer: some ScreenRenderer) {
        super.draw(renderer)
        if queue?.isEmpty == false {
            invalidateLayout()
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        do {
            try queue?.enqueue(sampleBuffer)
        } catch {
            // A full queue discards the frame. That was silent, and a silently
            // discarded source frame is a hole in the motion that leaves the
            // output frame rate looking perfect.
            pacing?.noteDropped()
        }
        invalidateLayout()
    }

    func reset() {
        frameTracker.clear()
        pacing?.reset()
        heldPixelBuffer = nil
        try? queue?.reset()
        invalidateLayout()
    }
}
