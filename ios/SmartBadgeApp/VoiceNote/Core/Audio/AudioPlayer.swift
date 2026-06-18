import AVFoundation
import Combine
import Foundation

/// 音频播放器 — 播放已录制的 WAV 文件
/// 对齐 Android: AudioPlayer.kt (MediaPlayer 封装)
final class AudioPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isReady = false

    private var player: AVAudioPlayer?
    private var timer: AnyCancellable?

    /// 加载音频文件
    func load(url: URL) {
        stop()
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            duration = player?.duration ?? 0
            isReady = true
        } catch {
            print("[AudioPlayer] load failed: \(error)")
            isReady = false
        }
    }

    /// 播放/暂停切换
    func togglePlayPause() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    /// 跳转到指定时间
    func seek(to time: TimeInterval) {
        player?.currentTime = max(0, min(time, duration))
        currentTime = player?.currentTime ?? 0
    }

    /// 停止播放
    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        isReady = false
        currentTime = 0
        duration = 0
        stopTimer()
    }

    // MARK: - 内部

    private func startTimer() {
        timer = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    self.stopTimer()
                }
            }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}
