import Combine
import Foundation

final class PresenceController: ObservableObject {
    @Published var discordToken: String {
        didSet {
            if discordToken.isEmpty {
                KeychainHelper.deleteToken()
            } else {
                _ = KeychainHelper.save(token: discordToken)
            }
        }
    }

    @Published var applicationId: String {
        didSet {
            if applicationId.isEmpty {
                UserDefaults.standard.removeObject(forKey: "discord_app_id")
            } else {
                UserDefaults.standard.set(applicationId, forKey: "discord_app_id")
            }
        }
    }

    let musicManager = MusicManager()
    let discordManager = DiscordGatewayManager()

    private var cancellables = Set<AnyCancellable>()

    init() {
        discordToken = KeychainHelper.loadToken() ?? ""
        applicationId = UserDefaults.standard.string(forKey: "discord_app_id") ?? ""

        musicManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        discordManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        musicManager.$currentSongTitle
            .dropFirst()
            .sink { [weak self] _ in
                self?.connectIfMusicStarted()
                self?.sendPresenceIfConnected(force: true)
            }
            .store(in: &cancellables)

        musicManager.$isPlaying
            .dropFirst()
            .sink { [weak self] _ in
                self?.connectIfMusicStarted()
                self?.sendPresenceIfConnected(force: true)
            }
            .store(in: &cancellables)

        Publishers.Merge3(
            musicManager.$currentArtworkURL.map { _ in },
            musicManager.$currentAppleMusicURL.map { _ in },
            musicManager.$playbackDuration.map { _ in }
        )
        .dropFirst()
        .sink { [weak self] _ in
            self?.sendPresenceIfConnected(force: true)
        }
        .store(in: &cancellables)

        discordManager.$connectionStatus
            .dropFirst()
            .sink { [weak self] status in
                if status == "Connected" {
                    self?.sendPresenceIfConnected(force: true)
                }
            }
            .store(in: &cancellables)

        connectIfMusicStarted()
    }

    func connect() {
        discordManager.connect(with: discordToken, applicationId: applicationId)
    }

    func disconnect() {
        discordManager.disconnect()
    }

    func clearToken() {
        discordToken = ""
    }

    func clearApplicationId() {
        applicationId = ""
    }

    func sendPresenceIfConnected(force: Bool = false) {
        guard discordManager.connectionStatus == "Connected" else { return }
        discordManager.updatePresence(
            songTitle: musicManager.currentSongTitle,
            artist: musicManager.currentArtist,
            albumTitle: musicManager.currentAlbumTitle,
            artworkURL: musicManager.currentArtworkURL,
            appleMusicURL: musicManager.currentAppleMusicURL,
            playbackDuration: musicManager.playbackDuration,
            currentPlaybackTime: musicManager.currentPlaybackTime,
            isPlaying: musicManager.isPlaying,
            force: force
        )
    }

    private func connectIfMusicStarted() {
        guard musicManager.isPlaying,
              !discordToken.isEmpty,
              discordManager.connectionStatus == "Disconnected" else { return }

        connect()
    }
}
