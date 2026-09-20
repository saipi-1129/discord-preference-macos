import SwiftUI
import Network
#if os(macOS)
import AppKit

private typealias PlatformColor = NSColor
private typealias PlatformImage = NSImage

private extension Color {
    static var appGroupedBackground: Color { Color(nsColor: .windowBackgroundColor) }
    static var appSecondaryGroupedBackground: Color { Color(nsColor: .controlBackgroundColor) }
    static var appTertiaryGroupedBackground: Color { Color(nsColor: .separatorColor).opacity(0.18) }
}
#else
import UIKit

private typealias PlatformColor = UIColor
private typealias PlatformImage = UIImage

private extension Color {
    static var appGroupedBackground: Color { Color(.systemGroupedBackground) }
    static var appSecondaryGroupedBackground: Color { Color(.secondarySystemGroupedBackground) }
    static var appTertiaryGroupedBackground: Color { Color(.tertiarySystemGroupedBackground) }
}
#endif

struct ContentView: View {
    @ObservedObject var controller: PresenceController
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingTokenInput: Bool = false

    var body: some View {
        ZStack {
            Color.appGroupedBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                connectionBanner
                ScrollView {
                    VStack(spacing: 20) {
                        nowPlayingCard
                        discordSection
                        if let error = controller.discordManager.lastError {
                            errorBanner(error)
                        }
                        diagnosticSection
                        disclaimerText
                    }
                    .padding()
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                controller.sendPresenceIfConnected(force: true)
            }
        }
        .onAppear {
            #if os(macOS)
            controller.musicManager.loadCurrentArtworkIfNeeded()
            #endif
        }
    }

    // MARK: - Connection Banner

    private var connectionBanner: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(controller.discordManager.connectionStatus)
                .font(.caption)
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(statusColor.opacity(0.15))
    }

    private var statusColor: Color {
        switch controller.discordManager.connectionStatus {
        case "Connected":
            return .green
        case let s where s.contains("Reconnecting"):
            return .yellow
        case "Connecting...":
            return .orange
        default:
            return .red
        }
    }

    // MARK: - Now Playing Card

    private var nowPlayingCard: some View {
        VStack(spacing: 0) {
            // Album Artwork
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.appSecondaryGroupedBackground)

                if let artwork = controller.musicManager.currentArtwork {
                    #if os(macOS)
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    #else
                    Image(uiImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    #endif
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        Text("No Song Playing")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(height: 300)
                }
            }

            // Song Info
            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(controller.musicManager.currentSongTitle)
                            .font(.title3)
                            .fontWeight(.bold)
                            .lineLimit(1)

                        Text(controller.musicManager.currentArtist)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        if !controller.musicManager.currentAlbumTitle.isEmpty {
                            Text(controller.musicManager.currentAlbumTitle)
                                .font(.caption)
                                .foregroundColor(.secondary.opacity(0.7))
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if controller.musicManager.isPlaying {
                        Image(systemName: "waveform")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                            .symbolEffect(.variableColor.iterative)
                    }
                }

                // Progress Bar
                if controller.musicManager.playbackDuration > 0 {
                    VStack(spacing: 4) {
                        ProgressView(value: controller.musicManager.currentPlaybackTime, total: controller.musicManager.playbackDuration)
                            .tint(.accentColor)

                        HStack {
                            Text(formatTime(controller.musicManager.currentPlaybackTime))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatTime(controller.musicManager.playbackDuration))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color.appSecondaryGroupedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }

    // MARK: - Discord Section

    private var discordSection: some View {
        VStack(spacing: 12) {
            // Token Input
            HStack {
                SecureField("Discord User Token", text: $controller.discordToken)
                    .textFieldStyle(.roundedBorder)

                if !controller.discordToken.isEmpty {
                    Button {
                        controller.clearToken()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Application ID Input (for artwork display)
            HStack {
                TextField("Discord Application ID (optional)", text: $controller.applicationId)
                    .textFieldStyle(.roundedBorder)
                    #if !os(macOS)
                    .keyboardType(.numberPad)
                    #endif

                if !controller.applicationId.isEmpty {
                    Button {
                        controller.clearApplicationId()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }

            Text("Application IDを設定するとアルバムアートが表示されます。discord.com/developers で無料作成できます。")
                .font(.caption2)
                .foregroundColor(.secondary)

            // Connect / Disconnect Button
            Button {
                if controller.discordManager.connectionStatus == "Connected" {
                    controller.disconnect()
                } else {
                    controller.connect()
                }
            } label: {
                HStack {
                    Image(systemName: controller.discordManager.connectionStatus == "Connected" ? "wifi.slash" : "wifi")
                    Text(controller.discordManager.connectionStatus == "Connected" ? "Disconnect" : "Connect to Discord")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(controller.discordManager.connectionStatus == "Connected" ? Color.red : Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .fontWeight(.semibold)
            }
            .disabled(controller.discordToken.isEmpty && controller.discordManager.connectionStatus != "Connected")

            // Manual Update Button
            if controller.discordManager.connectionStatus == "Connected" {
                Button {
                    controller.sendPresenceIfConnected(force: true)
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Update Presence Now")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.appTertiaryGroupedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .font(.subheadline)
                }
            }
        }
        .padding()
        .background(Color.appSecondaryGroupedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Disclaimer

    private var disclaimerText: some View {
        VStack(spacing: 4) {
            Text("This app requires foreground to maintain Discord connection.")
                .font(.caption2)
                .foregroundColor(.secondary)
                #if os(macOS)
                .hidden()
                #endif
            Text("User token usage may violate Discord ToS. Use at your own risk.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.top, 8)
    }

    // MARK: - Diagnostic Section

    @State private var diagResults: [String] = []
    @State private var isDiagRunning = false

    private var diagnosticSection: some View {
        VStack(spacing: 8) {
            Button {
                runDiagnostics()
            } label: {
                HStack {
                    Image(systemName: "stethoscope")
                    Text(isDiagRunning ? "Testing..." : "Network Diagnostics")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.orange)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .font(.subheadline)
                .fontWeight(.semibold)
            }
            .disabled(isDiagRunning)

            ForEach(diagResults, id: \.self) { result in
                Text(result)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(Color.appSecondaryGroupedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func runDiagnostics() {
        isDiagRunning = true
        diagResults = ["Running diagnostics..."]

        // Test 1: HTTPS to discord.com
        let url1 = URL(string: "https://discord.com/api/v10/gateway")!
        URLSession.shared.dataTask(with: url1) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    diagResults.append("1. HTTPS discord.com: FAIL - \(error.localizedDescription)")
                } else if let http = response as? HTTPURLResponse {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    diagResults.append("1. HTTPS discord.com: OK (HTTP \(http.statusCode)) \(body.prefix(80))")
                }
            }
        }.resume()

        // Test 2: DNS resolution
        DispatchQueue.global().async {
            let host = CFHostCreateWithName(nil, "gateway.discord.gg" as CFString).takeRetainedValue()
            var resolved = DarwinBoolean(false)
            CFHostStartInfoResolution(host, .addresses, nil)
            if let addresses = CFHostGetAddressing(host, &resolved)?.takeUnretainedValue() as? [Data], !addresses.isEmpty {
                let count = addresses.count
                DispatchQueue.main.async {
                    diagResults.append("2. DNS gateway.discord.gg: OK (\(count) addresses)")
                }
            } else {
                DispatchQueue.main.async {
                    diagResults.append("2. DNS gateway.discord.gg: FAIL - cannot resolve")
                }
            }
        }

        // Test 3: TCP connection to gateway.discord.gg:443
        DispatchQueue.global().async {
            let conn = NWConnection(host: "gateway.discord.gg", port: 443, using: .tls)
            let semaphore = DispatchSemaphore(value: 0)
            var result = ""
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    result = "3. TCP+TLS gateway.discord.gg:443: OK"
                    conn.cancel()
                    semaphore.signal()
                case .failed(let error):
                    result = "3. TCP+TLS gateway.discord.gg:443: FAIL - \(error)"
                    semaphore.signal()
                case .waiting(let error):
                    result = "3. TCP+TLS gateway.discord.gg:443: WAITING - \(error)"
                default:
                    break
                }
            }
            conn.start(queue: .global())
            _ = semaphore.wait(timeout: .now() + 10)
            if result.isEmpty {
                result = "3. TCP+TLS gateway.discord.gg:443: TIMEOUT"
            }
            conn.cancel()
            DispatchQueue.main.async {
                diagResults.append(result)
            }
        }

        // Test 4: WebSocket via URLSession
        DispatchQueue.global().async {
            let ws = URLSession.shared.webSocketTask(with: URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!)
            ws.resume()
            let semaphore = DispatchSemaphore(value: 0)
            var result = ""
            ws.receive { res in
                switch res {
                case .success(let msg):
                    switch msg {
                    case .string(let text):
                        result = "4. WebSocket: OK - \(text.prefix(60))"
                    case .data(let data):
                        result = "4. WebSocket: OK - \(data.count) bytes"
                    @unknown default:
                        result = "4. WebSocket: OK - unknown message type"
                    }
                case .failure(let error):
                    result = "4. WebSocket: FAIL - \(error)"
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 10)
            if result.isEmpty {
                result = "4. WebSocket: TIMEOUT"
            }
            ws.cancel(with: .normalClosure, reason: nil)
            DispatchQueue.main.async {
                diagResults.append(result)
                isDiagRunning = false
            }
        }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
