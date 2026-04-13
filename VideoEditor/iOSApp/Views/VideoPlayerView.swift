import SwiftUI
import AVKit
import AVFoundation

struct VideoPlayerView: View {
    let videoURL: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .onAppear {
                // Route to speaker + allow playback with the ring/silent switch ON
                // (default is ambient which mutes when silent switch is on).
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try? AVAudioSession.sharedInstance().setActive(true)

                let p = AVPlayer(url: videoURL)
                p.volume = 1.0
                p.play()
                player = p
            }
            .onDisappear { player?.pause() }
    }
}
