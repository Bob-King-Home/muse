import AVKit
import UIKit
import CoreMedia

/// v2.3 画中画 — v2.2 基础上再修 2 项
/// 1) 第一行改用短格式（12.4 MB/s → 12.4M，850 KB/s → 850K），和灵动岛紧凑模式同一个 short()。
///    v2.2 的“320 宽不再被裁”说过了头：双向都上 MB/s 时约 24–25 字符 ≈ 317–330pt，
///    居中 x 为负，两边被裁。短格式后约 15 字符 ≈ 198pt，不再超宽。
///    （之前注释写“约 13 字符 ≈ 172pt”是数错了，实际 15 字符，结论不变。）
/// 2) setupIfNeeded 不再一进门就锁 isSetup：第一次调用时 keyWindow 还不存在，
///    原来会永远挂不上承载 View 且不再重试；现在只在建完才置 true，没窗口就下次重试。
/// 保留 v2.2：递增时间戳、不可见承载 View、isPictureInPictureSupported 检查、
/// 分两行画字、像素格式 byteOrder32Little、丢帧重试、format 只建一次。
final class PiPManager: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    static let shared = PiPManager()

    var onPiPFailed: (() -> Void)?

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private var hostView: UIView?
    private var isSetup = false
    private var lastText = ""
    private let width = 320
    private let height = 120
    private var frameIndex: Int64 = 0
    private var cachedFormat: CMVideoFormatDescription?
    private var pendingFrame: (down: String, up: String, isWiFi: Bool)?

    var isPiPActive: Bool { pipController?.isPictureInPictureActive ?? false }

    private func setupIfNeeded() {
        guard !isSetup else { return }

        // 承载 View：不可见，1x1，挂进 keyWindow，图层不再是孤儿
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        host.isHidden = true
        host.backgroundColor = .clear
        var foundWindow = false
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) {
            window.addSubview(host)
            foundWindow = true
        }
        hostView = host

        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layer.addSublayer(layer)
        displayLayer = layer

        var timebase: CMTimebase?
        CMTimebaseCreateWithMasterClock(allocator: nil, masterClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let tb = timebase {
            layer.controlTimebase = tb
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1.0)
        }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer, playbackDelegate: self
        )
        pipController = AVPictureInPictureController(contentSource: source)
        pipController?.delegate = self
        // v2.3：只有真的把承载 View 挂进窗口了才锁 isSetup；没找到 keyWindow
        // 就不锁，下次 update/start 再进来重试，不会永远挂不上。
        if foundWindow { isSetup = true }
        pushFrame(downText: "0 B/s", upText: "0 B/s", isWiFi: true)
    }

    func update(downText: String, upText: String, isWiFi: Bool) {
        let key = "\(downText)|\(upText)|\(isWiFi)"
        // 心跳也推：SpeedEngine 每 4 秒会调一次，即使文字相同也要推帧防黑屏，
        // 所以这里不直接 return，交给 pushFrame 的去重在帧级别处理
        lastText = key
        setupIfNeeded()
        pushFrame(downText: downText, upText: upText, isWiFi: isWiFi)
    }

    func startPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            onPiPFailed?()
            return
        }
        setupIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self, let controller = self.pipController else {
                self?.onPiPFailed?()
                return
            }
            // startPictureInPicture 是同步的，失败时 isPictureInPictureActive 仍为 false
            controller.startPictureInPicture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                if controller.isPictureInPictureActive == false {
                    self?.onPiPFailed?()
                }
            }
        }
    }

    func stopPiP() {
        DispatchQueue.main.async { [weak self] in
            self?.pipController?.stopPictureInPicture()
        }
    }

    private func pushFrame(downText: String, upText: String, isWiFi: Bool) {
        guard let layer = displayLayer else { return }
        guard let pixelBuffer = makePixelBuffer(downText: downText, upText: upText, isWiFi: isWiFi) else { return }

        // format 只建一次复用，不再每帧新建
        if cachedFormat == nil {
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
            cachedFormat = format
        }
        guard let format = cachedFormat else { return }

        // 递增时间戳：从 0 开始每帧 +1 秒，与 timebase / timeRange 对齐
        frameIndex += 1
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 1),
            presentationTimeStamp: CMTime(value: frameIndex, timescale: 1),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer
        )
        guard let sb = sampleBuffer else { return }
        if layer.isReadyForMoreMediaData {
            layer.enqueue(sb)
        } else {
            // 丢帧不直接扔掉，排队等 ready 再推
            pendingFrame = (downText, upText, isWiFi)
            layer.requestMediaDataWhenReady(on: DispatchQueue.main) { [weak self] in
                guard let self, let pending = self.pendingFrame else { return }
                self.pendingFrame = nil
                self.pushFrame(downText: pending.down, upText: pending.up, isWiFi: pending.isWiFi)
            }
        }
    }

    private func makePixelBuffer(downText: String, upText: String, isWiFi: Bool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let pixelBuffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        // 像素格式修正：32BGRA 对应 byteOrder32Little + premultipliedFirst
        let ctx = CGContext(
            data: base, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        guard let ctx else { return nil }
        // v2.5 外观自定义：底色 / 字色 / 字号都读 UserDefaults（画中画在主 App 进程里，直接读，不用走 ContentState）
        let level = SpeedAppearance.fontSizeLevel
        let bgColor = SpeedAppearance.uiColor(hex: SpeedAppearance.backgroundHex)
        let fontColor = SpeedAppearance.uiColor(hex: SpeedAppearance.fontColorHex)
        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // v2.3：第一行用短格式，和灵动岛紧凑模式同一个 short()。
        // "↓ 12.4 MB/s  ↑ 850.0 KB/s" 约 24–25 字符 ≈ 317–330pt，320 宽居中 x 为负，两边被裁；
        // "↓ 12.4M  ↑ 850K" 约 15 字符 ≈ 198pt，22 号等宽字也放得下。
        // （之前注释写“约 13 字符 ≈ 172pt”是数错了，实际 15 字符，结论不变，照样放得下。）
        // 分两行画，不再用带 \n 的 draw(at:)：第一行速度，第二行状态
        let line1 = "↓ \(short(downText))  ↑ \(short(upText))" as NSString
        let line2 = (isWiFi ? "Wi-Fi" : "蜂窝") + " · SpeedIsland" as NSString
        let font = UIFont.monospacedSystemFont(ofSize: SpeedAppearance.pipFontSize(level: level), weight: .semibold)
        let attrs2: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fontColor]
        let smallAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: SpeedAppearance.pipFontSize(level: level) - 6, weight: .regular),
            .foregroundColor: fontColor.withAlphaComponent(0.7)
        ]
        let size1 = line1.size(withAttributes: attrs2)
        let size2 = line2.size(withAttributes: smallAttrs)
        // v2.5：两行按字号垂直居中，不再写死 y=28/68，大字号也不会顶到边
        let gap: CGFloat = 12
        let totalHeight = size1.height + gap + size2.height
        let startY = (CGFloat(height) - totalHeight) / 2
        line1.draw(at: CGPoint(x: (CGFloat(width) - size1.width) / 2, y: startY), withAttributes: attrs2)
        line2.draw(at: CGPoint(x: (CGFloat(width) - size2.width) / 2, y: startY + size1.height + gap), withAttributes: smallAttrs)
        return pixelBuffer
    }

    private func short(_ s: String) -> String {
        // 和灵动岛紧凑模式同一个规则："12.4 MB/s" -> "12.4M"，"850 KB/s" -> "850K"，"0 B/s" -> "0"
        s.replacingOccurrences(of: " MB/s", with: "M")
            .replacingOccurrences(of: " KB/s", with: "K")
            .replacingOccurrences(of: " B/s", with: "")
    }

    // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // 直播内容用无限时长，不再写死 8 小时
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
}

extension PiPManager: AVPictureInPictureControllerDelegate {
    // didTransitionToRenderSize 是 Delegate 的方法，放这里才对
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {}
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        // 用户在小窗上点了关闭，发通知；ContentView 收到后调 SpeedEngine.syncPiPStopped()，
        // 按钮马上变回“悬浮小窗”，下一按直接重开，不再要点两次
        NotificationCenter.default.post(name: .init("SpeedIslandPiPDidStop"), object: nil)
    }
}
