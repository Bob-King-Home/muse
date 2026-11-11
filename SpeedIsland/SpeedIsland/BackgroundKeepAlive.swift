import AVFoundation
import Foundation

/// v2.2 保活 — 修 P1-3
/// 1) 显式 volume=0 + memset 清零，不再靠“buffer 默认全 0”赌运气
/// 2) 监听打断通知，来电 / Siri / 别的 App 抢占后自动重开
/// 3) start 失败时把 isRunning 复位，不再假装在跑；stop 只在自己独占时才 deactivate，不打断用户音乐
/// 低耗电：8000Hz 单声道静音（原来 44100Hz），循环 buffer 只要 0.5 秒，CPU 更低
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var isRunning = false
    private var interruptionObserver: NSObjectProtocol?
    private var didActivateSession = false

    func start() {
        guard !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            didActivateSession = true
        } catch {
            print("音频会话失败: \(error)")
            isRunning = false
            return
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        player.volume = 0 // 显式静音
        engine.attach(player)
        // 8000Hz 足够保活，比 44100Hz 省 CPU
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1) else {
            isRunning = false
            return
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let frameCount = AVAudioFrameCount(8000 * 0.5)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            isRunning = false
            return
        }
        buffer.frameLength = frameCount
        // 显式清零，不赌新内存就是 0
        if let ptr = buffer.floatChannelData?[0] {
            memset(ptr, 0, Int(frameCount) * MemoryLayout<Float>.size)
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        do {
            try engine.start()
            player.play()
            self.engine = engine
            self.player = player
            isRunning = true
        } catch {
            print("保活引擎启动失败: \(error)")
            isRunning = false
            return
        }

        // 打断恢复：来电挂断 / Siri 结束自动重开
        if interruptionObserver == nil {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil, queue: nil
            ) { [weak self] note in
                guard let self, self.isRunning else { return }
                guard let userInfo = note.userInfo,
                      let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
                if type == .ended {
                    // 先停干净再重开，避免重复引擎
                    self.player?.stop()
                    self.engine?.stop()
                    self.engine = nil; self.player = nil
                    self.isRunning = false
                    self.start()
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let token = interruptionObserver {
            NotificationCenter.default.removeObserver(token)
            interruptionObserver = nil
        }
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        // 只在自己激活过时才 deactivate，不打断用户正在放的音乐
        if didActivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            didActivateSession = false
        }
    }
}
