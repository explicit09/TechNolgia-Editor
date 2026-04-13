import SwiftUI
import AVKit

struct VideoPlayerView: View {
    let videoURL: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .onAppear {
                let p = AVPlayer(url: videoURL)
                p.isMuted = true
                p.play()
                player = p
            }
            .onDisappear { player?.pause() }
    }
}
