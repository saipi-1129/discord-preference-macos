import Foundation
#if os(macOS)
import AppKit
#else
import MediaPlayer
import MusicKit
import UIKit
#endif
import Combine

class MusicManager: ObservableObject {
    @Published var currentSongTitle: String = "No Song Playing"
    @Published var currentArtist: String = ""
    @Published var currentAlbumTitle: String = ""
    #if os(macOS)
    @Published var currentArtwork: NSImage? = nil
    #else
    @Published var currentArtwork: UIImage? = nil
    #endif
    @Published var currentArtworkURL: String? = nil
    @Published var currentAppleMusicURL: String? = nil
    @Published var isPlaying: Bool = false
    @Published var playbackDuration: TimeInterval = 0
    @Published var currentPlaybackTime: TimeInterval = 0

    #if os(macOS)
    private var refreshTimer: Timer?
    private var playbackTimer: Timer?
    private var lastArtworkLookupKey: String = ""
    private var lastMetadataKey: String = ""

    init() {
        startObserving()
    }

    private func startObserving() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleMusicPlayerInfo),
            name: Notification.Name("com.apple.Music.playerInfo"),
            object: nil
        )

        refreshNowPlayingInfo()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshNowPlayingInfo()
        }
    }

    deinit {
        refreshTimer?.invalidate()
        playbackTimer?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func handleMusicPlayerInfo(_ notification: Notification) {
        applyMusicInfo(notification.userInfo ?? [:])
    }

    private func applyMusicInfo(_ info: [AnyHashable: Any]) {
        let playerState = (info["Player State"] as? String) ?? ""
        isPlaying = playerState == "Playing"

        if let title = info["Name"] as? String, !title.isEmpty {
            currentSongTitle = title
            currentArtist = info["Artist"] as? String ?? "Unknown Artist"
            currentAlbumTitle = info["Album"] as? String ?? "Unknown Album"
            playbackDuration = parseMusicNotificationDuration(info["Total Time"]) ?? playbackDuration
            refreshArtworkURLIfNeeded()
        } else if !isPlaying {
            clearNowPlayingInfo()
        }

        if isPlaying {
            startPlaybackTimer()
        } else {
            stopPlaybackTimer()
        }

        refreshPlaybackPosition()
    }

    private func refreshNowPlayingInfo() {
        let script = """
        tell application "System Events"
            set musicIsRunning to exists process "Music"
        end tell
        if musicIsRunning is false then
            return "stopped|||||0|0"
        end if
        tell application "Music"
            if player state is stopped then
                return "stopped|||||0|0"
            end if
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackAlbum to album of current track
            set trackDuration to duration of current track as real
            set trackPosition to player position as real
            return (player state as string) & "|" & trackName & "|" & trackArtist & "|" & trackAlbum & "|" & trackDuration & "|" & trackPosition
        end tell
        """

        var error: NSDictionary?
        guard let output = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue else {
            return
        }

        let parts = output.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 6 else { return }

        let state = parts[0]
        isPlaying = state == "playing"
        guard isPlaying || state == "paused" else {
            clearNowPlayingInfo()
            return
        }

        currentSongTitle = parts[1].isEmpty ? "Unknown Title" : parts[1]
        currentArtist = parts[2].isEmpty ? "Unknown Artist" : parts[2]
        currentAlbumTitle = parts[3].isEmpty ? "Unknown Album" : parts[3]
        playbackDuration = parseTimeInterval(parts[4]) ?? 0
        currentPlaybackTime = parseTimeInterval(parts[5]) ?? 0
        refreshArtworkURLIfNeeded()

        if isPlaying {
            startPlaybackTimer()
        } else {
            stopPlaybackTimer()
        }
    }

    func loadCurrentArtworkIfNeeded(force: Bool = false) {
        guard force || currentArtwork == nil else { return }
        fetchCurrentArtworkFromMusicApp()
    }

    func unloadCurrentArtwork() {
        currentArtwork = nil
    }

    private func refreshPlaybackPosition() {
        guard isPlaying else { return }

        let script = """
        tell application "System Events"
            set musicIsRunning to exists process "Music"
        end tell
        if musicIsRunning is false then return "0"
        tell application "Music" to return player position
        """

        var error: NSDictionary?
        if let output = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue,
           let position = TimeInterval(output) {
            currentPlaybackTime = position
        }
    }

    private func clearNowPlayingInfo() {
        currentSongTitle = "No Song Playing"
        currentArtist = ""
        currentAlbumTitle = ""
        currentArtwork = nil
        currentArtworkURL = nil
        currentAppleMusicURL = nil
        isPlaying = false
        playbackDuration = 0
        currentPlaybackTime = 0
        stopPlaybackTimer()
    }

    private func fetchArtworkURL(title: String, artist: String) {
        guard !title.isEmpty, title != "No Song Playing" else {
            currentArtworkURL = nil
            currentAppleMusicURL = nil
            return
        }

        let lookupKey = "\(title)|\(artist)|\(currentAlbumTitle)"
        guard lookupKey != lastArtworkLookupKey else { return }
        lastArtworkLookupKey = lookupKey

        let candidates = searchTerms(title: title, artist: artist, album: currentAlbumTitle)
        guard !candidates.isEmpty else {
            currentArtworkURL = nil
            currentAppleMusicURL = nil
            return
        }

        fetchArtworkURLCandidates(candidates, metadataKey: lookupKey, title: title, artist: artist, index: 0)
    }

    private func fetchArtworkURLCandidates(_ candidates: [String], metadataKey: String, title: String, artist: String, index: Int) {
        guard index < candidates.count, let url = makeSearchURL(term: candidates[index]) else {
            currentArtworkURL = nil
            currentAppleMusicURL = nil
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self, let data else {
                    self?.currentArtworkURL = nil
                    self?.currentAppleMusicURL = nil
                    return
                }
                guard self.lastMetadataKey == metadataKey else { return }

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let results = json["results"] as? [[String: Any]],
                   let first = self.bestSearchResult(results, title: title, artist: artist),
                   let artworkUrl = first["artworkUrl100"] as? String {
                    let highRes = artworkUrl.replacingOccurrences(of: "100x100", with: "512x512")
                    self.currentArtworkURL = highRes
                    self.currentAppleMusicURL = first["trackViewUrl"] as? String
                } else {
                    self.currentArtworkURL = nil
                    self.currentAppleMusicURL = nil
                    self.fetchArtworkURLCandidates(candidates, metadataKey: metadataKey, title: title, artist: artist, index: index + 1)
                }
            }
        }.resume()
    }

    private func searchTerms(title: String, artist: String, album: String) -> [String] {
        let cleanTitle = title
            .replacingOccurrences(of: "feat.", with: " ")
            .replacingOccurrences(of: "Feat.", with: " ")
            .replacingOccurrences(of: "featuring", with: " ")
            .replacingOccurrences(of: "Featuring", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let rawTerms = [
            [title, artist, album],
            [title, artist],
            [cleanTitle, artist],
            [title],
            [cleanTitle]
        ].map { parts in
            parts.filter { !$0.isEmpty && !$0.hasPrefix("Unknown") }.joined(separator: " ")
        }

        var seen = Set<String>()
        return rawTerms.filter { term in
            guard !term.isEmpty, !seen.contains(term) else { return false }
            seen.insert(term)
            return true
        }
    }

    private func makeSearchURL(term: String) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: "JP"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10")
        ]
        return components?.url
    }

    private func refreshArtworkURLIfNeeded() {
        let metadataKey = "\(currentSongTitle)|\(currentArtist)|\(currentAlbumTitle)"
        guard metadataKey != lastMetadataKey else { return }
        lastMetadataKey = metadataKey
        currentArtwork = nil
        currentArtworkURL = nil
        currentAppleMusicURL = nil
        fetchArtworkURL(title: currentSongTitle, artist: currentArtist)
    }

    private func fetchCurrentArtworkFromMusicApp() {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("discord_preference_current_artwork")

        let script = """
        tell application "System Events"
            set musicIsRunning to exists process "Music"
        end tell
        if musicIsRunning is false then return "missing"
        tell application "Music"
            if player state is stopped then return "missing"
            if (count of artworks of current track) is 0 then return "missing"
            set artworkData to data of artwork 1 of current track
        end tell
        set outputPath to "\(outputURL.path)"
        set fileRef to open for access (POSIX file outputPath) with write permission
        set eof of fileRef to 0
        write artworkData to fileRef
        close access fileRef
        return outputPath
        """

        var error: NSDictionary?
        guard let path = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue,
              path != "missing",
              let image = NSImage(contentsOfFile: path) else {
            return
        }
        currentArtwork = image
    }

    private func bestSearchResult(_ results: [[String: Any]], title: String, artist: String) -> [String: Any]? {
        let normalizedTitle = normalizeForMatch(title)
        let normalizedArtist = normalizeForMatch(artist)

        return results.first { result in
            let resultTitle = normalizeForMatch(result["trackName"] as? String ?? "")
            let resultArtist = normalizeForMatch(result["artistName"] as? String ?? "")
            return resultTitle == normalizedTitle && (normalizedArtist.isEmpty || resultArtist == normalizedArtist)
        } ?? results.first
    }

    private func normalizeForMatch(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func parseTimeInterval(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let double = value as? Double {
            return double
        }
        if let string = value as? String {
            return TimeInterval(string.replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }

    private func parseMusicNotificationDuration(_ value: Any?) -> TimeInterval? {
        guard let duration = parseTimeInterval(value) else { return nil }
        return duration > 6 * 60 * 60 ? duration / 1000 : duration
    }

    private func fetchArtworkImage(urlString: String) {
        guard let url = URL(string: urlString) else {
            currentArtwork = nil
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                self?.currentArtwork = image
            }
        }.resume()
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.currentPlaybackTime += 1
            if self.playbackDuration > 0 {
                self.currentPlaybackTime = min(self.currentPlaybackTime, self.playbackDuration)
            }
        }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
    #else
    private let musicPlayer = MPMusicPlayerController.systemMusicPlayer
    private var isAuthorized = false
    private var playbackTimer: Timer?

    init() {
        requestAuthorization()
    }

    private func requestAuthorization() {
        Task {
            let status = await MusicAuthorization.request()
            await MainActor.run {
                if status == .authorized {
                    self.isAuthorized = true
                    self.startObserving()
                } else {
                    self.currentSongTitle = "Apple Musicの権限が必要です"
                }
            }
        }
    }

    private func startObserving() {
        musicPlayer.beginGeneratingPlaybackNotifications()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handlePlaybackStateDidChange),
                                               name: .MPMusicPlayerControllerPlaybackStateDidChange,
                                               object: musicPlayer)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleNowPlayingItemDidChange),
                                               name: .MPMusicPlayerControllerNowPlayingItemDidChange,
                                               object: musicPlayer)

        updateNowPlayingInfo()
    }

    deinit {
        playbackTimer?.invalidate()
        musicPlayer.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handlePlaybackStateDidChange() {
        updateNowPlayingInfo()
    }

    @objc private func handleNowPlayingItemDidChange() {
        updateNowPlayingInfo()
    }

    private func updateNowPlayingInfo() {
        DispatchQueue.main.async {
            let wasPlaying = self.isPlaying
            self.isPlaying = self.musicPlayer.playbackState == .playing

            if let nowPlayingItem = self.musicPlayer.nowPlayingItem {
                self.currentSongTitle = nowPlayingItem.title ?? "Unknown Title"
                self.currentArtist = nowPlayingItem.artist ?? "Unknown Artist"
                self.currentAlbumTitle = nowPlayingItem.albumTitle ?? "Unknown Album"
                self.playbackDuration = nowPlayingItem.playbackDuration
                self.currentPlaybackTime = self.musicPlayer.currentPlaybackTime

                if let artwork = nowPlayingItem.artwork {
                    self.currentArtwork = artwork.image(at: CGSize(width: 300, height: 300))
                } else {
                    self.currentArtwork = nil
                }

                // Fetch artwork URL via iTunes Search API for Discord
                self.fetchArtworkURL(for: nowPlayingItem)
            } else {
                self.currentSongTitle = "No Song Playing"
                self.currentArtist = ""
                self.currentAlbumTitle = ""
                self.currentArtwork = nil
                self.currentArtworkURL = nil
                self.isPlaying = false
                self.playbackDuration = 0
                self.currentPlaybackTime = 0
            }

            if self.isPlaying && !wasPlaying {
                self.startPlaybackTimer()
            } else if !self.isPlaying {
                self.stopPlaybackTimer()
            }
        }
    }

    private func fetchArtworkURL(for item: MPMediaItem) {
        let title = item.title ?? ""
        let artist = item.artist ?? ""
        guard !title.isEmpty else {
            self.currentArtworkURL = nil
            return
        }

        let query = "\(title) \(artist)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://itunes.apple.com/search?term=\(query)&media=music&entity=song&limit=1"
        guard let url = URL(string: urlString) else {
            self.currentArtworkURL = nil
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self, let data else {
                    self?.currentArtworkURL = nil
                    return
                }
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let results = json["results"] as? [[String: Any]],
                       let first = results.first,
                       let artworkUrl = first["artworkUrl100"] as? String {
                        // Upgrade to 512x512
                        let highRes = artworkUrl.replacingOccurrences(of: "100x100", with: "512x512")
                        self.currentArtworkURL = highRes
                        print("[Music] Artwork URL: \(highRes)")
                    } else {
                        self.currentArtworkURL = nil
                    }
                } catch {
                    print("[Music] iTunes search failed: \(error)")
                    self.currentArtworkURL = nil
                }
            }
        }.resume()
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.currentPlaybackTime = self.musicPlayer.currentPlaybackTime
        }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
    #endif
}
