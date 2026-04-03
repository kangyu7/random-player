import SwiftUI
import AppKit
import VLCKitSPM

// MARK: - VLC NSView Wrapper

/// VLCMediaPlayer의 drawable로 사용할 NSView를 SwiftUI에 래핑
private struct VLCVideoViewRepresentable: NSViewRepresentable {
    let player: VLCMediaPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        player.drawable = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if player.drawable as? NSView !== nsView {
            player.drawable = nsView
        }
    }
}

// MARK: - VLC Player Observer

/// VLCMediaPlayer 상태를 SwiftUI로 전달하기 위한 ObservableObject
class VLCPlayerObserver: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isFailed = false
    @Published var isBuffering = false

    private var scrollMonitor: Any?
    private var keyMonitor: Any?

    func attach(to player: VLCMediaPlayer) {
        player.delegate = self
    }

    // MARK: VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        DispatchQueue.main.async {
            switch player.state {
            case .playing:
                self.isPlaying = true
                self.isBuffering = false
                self.isFailed = false
            case .paused:
                self.isPlaying = false
            case .stopped:
                self.isPlaying = false
            case .error:
                self.isFailed = true
                self.isBuffering = false
                self.isPlaying = false
            case .buffering:
                break  // VLC는 재생 중에도 빈번하게 buffering 상태 전환 — 표시하지 않음
            case .ended:
                self.isPlaying = false
            default:
                break
            }
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        DispatchQueue.main.async {
            let time = player.time
            if let ms = time.value {
                self.currentTime = Double(truncating: ms) / 1000.0
            }
            if let media = player.media, let dur = media.length.value {
                self.duration = Double(truncating: dur) / 1000.0
            }
        }
    }

    // MARK: - Scroll & Key Monitors (동일 패턴)

    func startScrollMonitor(onScroll: @escaping (Double) -> Void) {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let delta: Double
            if event.hasPreciseScrollingDeltas {
                delta = Double(event.scrollingDeltaY) / 300.0
            } else {
                delta = Double(event.deltaY) * 0.05
            }
            if abs(delta) > 0.001 {
                DispatchQueue.main.async { onScroll(delta) }
                return nil
            }
            return event
        }
    }

    func startKeyMonitor(
        onLeft: @escaping () -> Void,
        onRight: @escaping () -> Void,
        onSpace: (() -> Void)? = nil,
        onEsc: (() -> Void)? = nil,
        onFullscreen: (() -> Void)? = nil
    ) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53:  // Esc
                if let onEsc { DispatchQueue.main.async { onEsc() } }
                return nil
            case 3:   // F
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [] {
                    if let onFullscreen { DispatchQueue.main.async { onFullscreen() } }
                    return nil
                }
                return event
            case 49:  // Space
                if let onSpace { DispatchQueue.main.async { onSpace() } }
                return nil
            case 123: // ←
                DispatchQueue.main.async { onLeft() }
                return nil
            case 124: // →
                DispatchQueue.main.async { onRight() }
                return nil
            default:
                return event
            }
        }
    }

    func stop() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

// MARK: - Internal VLC Player View

struct InternalVLCPlayerView: View {
    let fileURL: URL
    let title: String
    var onNextRandom: (() -> Void)?
    var onOpenExternal: (() -> Void)?
    var onClose: (() -> Void)?

    @AppStorage("playerVolume") private var savedVolume: Double = 1.0
    @AppStorage("seekSeconds") private var seekSeconds: Int = 1

    @StateObject private var observer = VLCPlayerObserver()
    @State private var player = VLCMediaPlayer()

    @State private var displayVolume: Double = 1.0
    @State private var showVolumeHUD = false
    @State private var hudDismissTask: Task<Void, Never>?
    @State private var videoInfo: VideoInfo?
    @State private var isFullscreen = false

    private var isKo: Bool {
        Locale.current.language.languageCode?.identifier == "ko"
    }

    private func volumeIcon(for volume: Double) -> String {
        if volume <= 0 { return "speaker.slash.fill" }
        if volume < 0.33 { return "speaker.fill" }
        if volume < 0.66 { return "speaker.wave.1.fill" }
        return "speaker.wave.3.fill"
    }

    private func applyVolumeDelta(_ delta: Double) {
        let cur = Double(player.audio?.volume ?? 100) / 100.0
        let newVol = max(0.0, min(1.0, cur + delta))
        player.audio?.volume = Int32(newVol * 100)
        savedVolume = newVol
        displayVolume = newVol
        withAnimation(.easeIn(duration: 0.15)) { showVolumeHUD = true }
        hudDismissTask?.cancel()
        hudDismissTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) { showVolumeHUD = false }
            }
        }
    }

    private func toggleFullscreen() {
        if let window = NSApp.keyWindow {
            window.toggleFullScreen(nil)
            isFullscreen.toggle()
        }
    }

    private func handleEsc() {
        if isFullscreen {
            toggleFullscreen()
        } else {
            player.stop()
            onClose?()
        }
    }

    private func seekBy(_ seconds: Int) {
        let ms = Int32(seconds * 1000)
        if ms > 0 {
            player.jumpForward(ms)
        } else {
            player.jumpBackward(-ms)
        }
    }

    private func loadMedia(url: URL) {
        let media = VLCMedia(url: url)
        player.media = media
        player.audio?.volume = Int32(savedVolume * 100)
        player.play()
    }

    private func loadVideoInfo() {
        videoInfo = nil
        guard let media = player.media else { return }
        // VLC 미디어 파싱 후 트랙 정보 추출
        Task {
            media.parse()  // 로컬 파일 파싱
            try? await Task.sleep(for: .seconds(0.5))  // 파싱 대기
            await MainActor.run {
                var codec = "VLC"
                var width: CGFloat = 0
                var height: CGFloat = 0
                var bitrate: Double = 0

                for i in 0..<media.tracksInformation.count {
                    guard let track = media.tracksInformation[i] as? [String: Any] else { continue }
                    if let type = track[VLCMediaTracksInformationType] as? String, type == VLCMediaTracksInformationTypeVideo {
                        if let codecFourCC = track[VLCMediaTracksInformationCodec] as? UInt32 {
                            let b: [UInt8] = [
                                UInt8((codecFourCC >> 24) & 0xFF),
                                UInt8((codecFourCC >> 16) & 0xFF),
                                UInt8((codecFourCC >>  8) & 0xFF),
                                UInt8( codecFourCC        & 0xFF)
                            ]
                            let fourCC = String(bytes: b, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
                            switch fourCC.uppercased() {
                            case "H264", "AVC1": codec = "H.264"
                            case "HEVC", "HVC1": codec = "H.265 (HEVC)"
                            default: codec = fourCC.isEmpty ? "VLC" : fourCC
                            }
                        }
                        if let w = track[VLCMediaTracksInformationVideoWidth] as? Int {
                            width = CGFloat(w)
                        }
                        if let h = track[VLCMediaTracksInformationVideoHeight] as? Int {
                            height = CGFloat(h)
                        }
                        if let br = track[VLCMediaTracksInformationBitrate] as? Int {
                            bitrate = Double(br) / 1_000_000
                        }
                        break
                    }
                }

                videoInfo = VideoInfo(
                    codec: codec,
                    resolution: CGSize(width: width, height: height),
                    frameRate: 0,
                    bitrateMbps: bitrate
                )
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 상단 툴바
            HStack {
                Button {
                    onClose?()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(isKo ? "플레이어" : "Player")
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 400)

                Spacer()

                Button {
                    onNextRandom?()
                } label: {
                    Label(isKo ? "다음 랜덤" : "Next Random", systemImage: "shuffle")
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            // 비디오 영역
            ZStack {
                VLCVideoViewRepresentable(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showVolumeHUD {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: volumeIcon(for: displayVolume))
                                .frame(width: 18)
                            ProgressView(value: displayVolume)
                                .frame(width: 100)
                                .tint(.white)
                            Text("\(Int(displayVolume * 100))%")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(width: 36, alignment: .trailing)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: Capsule())
                        Spacer()
                    }
                    .padding(.top, 12)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                }

                if observer.isBuffering && !observer.isFailed {
                    VStack(spacing: 10) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(1.2)
                        Text(isKo ? "버퍼링 중..." : "Buffering…")
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                    .padding(20)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                    .allowsHitTesting(false)
                }

                if observer.isFailed {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.yellow)
                        Text(isKo ? "재생할 수 없는 파일" : "Cannot Play File")
                            .font(.headline)
                        Text(isKo ? "지원하지 않는 코덱이거나 손상된 파일입니다." : "Unsupported codec or corrupted file.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        if let onOpenExternal {
                            Button {
                                onOpenExternal()
                            } label: {
                                Label(isKo ? "외부 앱으로 열기" : "Open in External App",
                                      systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 4)
                        }
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 하단 컨트롤 바
            VLCPlayerControlBar(
                player: player,
                observer: observer,
                isKo: isKo,
                displayVolume: displayVolume,
                videoInfo: videoInfo
            )
        }
        .animation(.easeInOut(duration: 0.2), value: showVolumeHUD)
        .onAppear {
            displayVolume = savedVolume
            observer.attach(to: player)
            loadMedia(url: fileURL)
            loadVideoInfo()
            observer.startScrollMonitor { delta in
                applyVolumeDelta(delta)
            }
            observer.startKeyMonitor(
                onLeft:  { seekBy(-seekSeconds) },
                onRight: { seekBy(seekSeconds) },
                onSpace: { observer.isPlaying ? player.pause() : player.play() },
                onEsc: { handleEsc() },
                onFullscreen: { toggleFullscreen() }
            )
        }
        .onDisappear {
            hudDismissTask?.cancel()
            player.stop()
            observer.stop()
        }
        .onChange(of: fileURL) { _, newURL in
            loadMedia(url: newURL)
            loadVideoInfo()
        }
    }
}

// MARK: - VLC Control Bar

private struct VLCPlayerControlBar: View {
    let player: VLCMediaPlayer
    @ObservedObject var observer: VLCPlayerObserver
    let isKo: Bool
    let displayVolume: Double
    let videoInfo: VideoInfo?

    @State private var isSeeking = false
    @State private var seekValue: Double = 0

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let t = Int(seconds)
        let h = t / 3600; let m = (t % 3600) / 60; let s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func volumeIcon(for volume: Double) -> String {
        if volume <= 0 { return "speaker.slash.fill" }
        if volume < 0.33 { return "speaker.fill" }
        if volume < 0.66 { return "speaker.wave.1.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                observer.isPlaying ? player.pause() : player.play()
            } label: {
                Image(systemName: observer.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .buttonStyle(.plain)

            Text(formatTime(isSeeking ? seekValue : observer.currentTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(minWidth: 40, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { isSeeking ? seekValue : observer.currentTime },
                    set: { newValue in
                        seekValue = newValue
                        isSeeking = true
                    }
                ),
                in: 0...max(observer.duration, 0.001)
            ) { dragging in
                if !dragging {
                    if observer.duration > 0 {
                        player.position = Float(seekValue / observer.duration)
                    }
                    isSeeking = false
                }
            }

            Text(formatTime(observer.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(minWidth: 40, alignment: .leading)

            Image(systemName: volumeIcon(for: displayVolume))
                .foregroundColor(.secondary)
                .frame(width: 18)

            if let info = videoInfo {
                Divider().frame(height: 14)
                Text(info.summary)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
