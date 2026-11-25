import SwiftUI

/// Tools hub (Paket B, Fase 4): every tool in one place, grouped by area.
///
/// Presentation rule: views that carry their own NavigationStack + Close
/// button (Video Grabber, Torrent, AdBlock & Extensions) open as sheets —
/// their native presentation. Stack-friendly views (API Tester, DevTools,
/// Passwords, Settings) open through NavigationLinks in the hub's own
/// NavigationStack. The hub itself is the Tools tab root on iPhone and the
/// detail column on iPad.
struct ToolsHubView: View {
    @EnvironmentObject var store: DownloadStore
    @State private var query = ""
    @State private var showingGrabber = false
    @State private var showingTorrent = false
    @State private var showingAdBlock = false

    private enum HubSheet { case grabber, torrent, adBlock }
    private enum HubDestination: Hashable { case apiTester, devTools, passwords, settings }

    private struct HubCard: Identifiable {
        var id: String { title }
        let icon: String
        let accent: Color
        let title: String
        let subtitle: String
        let destination: HubDestination?
        let sheet: HubSheet?
        let disabled: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MDMSpacing.section) {
                Text("All tools in one place.")
                    .font(.subheadline)
                    .foregroundStyle(Color.mdmMuted)
                MDMSearchField(text: $query, placeholder: "Search tools")
                if !visible(unduhanCards).isEmpty {
                    hubSection(title: "Downloads", cards: unduhanCards)
                }
                if !visible(developerCards).isEmpty {
                    hubSection(title: "Developer", cards: developerCards)
                }
                if !visible(privacyCards).isEmpty {
                    hubSection(title: "Privacy", cards: privacyCards)
                }
                if !visible(networkCards).isEmpty {
                    hubSection(title: "Network", cards: networkCards)
                }
                Text("Torrent and Debrid are experimental. Network Monitor, Activity Center, and Command Palette arrive in Phase 7.")
                    .font(.caption)
                    .foregroundStyle(Color.mdmMuted)
            }
            .padding()
        }
        .background(Color.mdmBackground)
        .navigationTitle("Tools")
        .navigationDestination(for: HubDestination.self) { destination in
            switch destination {
            case .apiTester:
                ApiTesterView()
            case .devTools:
                if let session = store.browserSession {
                    DevToolsView(session: session)
                } else {
                    MDMEmptyState(icon: "chevron.left.forwardslash.chevron.right", title: "DevTools", message: "Open the Browser tab first, then come back here.")
                }
            case .passwords:
                PasswordsView()
            case .settings:
                SettingsView(showsDoneButton: false)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: HubDestination.settings) {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showingGrabber) { VideoGrabberView() }
        .sheet(isPresented: $showingTorrent) { TorrentAddView() }
        .sheet(isPresented: $showingAdBlock) { AdBlockPanelView() }
    }

    // MARK: - Cards

    private var unduhanCards: [HubCard] {
        let storedDebrid = DebridService.allCases.filter { MDMSecrets.hasDebridKey(for: $0) }.count
        return [
            HubCard(icon: "play.rectangle", accent: .mdmAccent, title: "Video Grabber", subtitle: "Find direct media links in a page's HTML", destination: nil, sheet: .grabber, disabled: false),
            HubCard(icon: "magnet", accent: .mdmWarning, title: "Add Torrent", subtitle: ".torrent metadata + experimental peer download", destination: nil, sheet: .torrent, disabled: false),
            HubCard(icon: "key.fill", accent: .mdmSuccess, title: "Debrid", subtitle: "\(storedDebrid) of 5 keys saved in Keychain", destination: .settings, sheet: nil, disabled: false),
            HubCard(icon: "wifi", accent: .mdmAccent2, title: "Remote Control", subtitle: store.settings.remoteControlEnabled ? "On — \(store.remoteAddress ?? "")" : "Off — set up in Settings", destination: .settings, sheet: nil, disabled: false),
        ]
    }

    private var developerCards: [HubCard] {
        let hasSession = store.browserSession != nil
        return [
            HubCard(icon: "bolt.horizontal.circle", accent: .mdmAccent, title: "API Tester", subtitle: "Compose, send, and re-run HTTP requests", destination: .apiTester, sheet: nil, disabled: false),
            HubCard(icon: "chevron.left.forwardslash.chevron.right", accent: .mdmAccent2, title: "DevTools", subtitle: hasSession ? "Console, Elements, Network, Storage" : "Open the Browser tab first", destination: .devTools, sheet: nil, disabled: !hasSession),
        ]
    }

    private var privacyCards: [HubCard] {
        [
            HubCard(icon: "shield", accent: .mdmSuccess, title: "AdBlock & Extensions", subtitle: "Ghostery lists, custom filters, userscripts", destination: nil, sheet: .adBlock, disabled: false),
            HubCard(icon: "key", accent: .mdmAccent, title: "Passwords", subtitle: "Saved logins — Face ID gated, Keychain only", destination: .passwords, sheet: nil, disabled: false),
        ]
    }

    private var networkCards: [HubCard] {
        [
            HubCard(icon: "network", accent: .mdmAccent2, title: "Proxy & DNS", subtitle: "In Settings — Network", destination: .settings, sheet: nil, disabled: false),
        ]
    }

    private func visible(_ cards: [HubCard]) -> [HubCard] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return cards }
        return cards.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q)
        }
    }

    @ViewBuilder
    private func hubSection(title: String, cards: [HubCard]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MDMSectionHeader(title: title)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(visible(cards)) { card in
                    cardView(card)
                }
            }
        }
    }

    @ViewBuilder
    private func cardView(_ card: HubCard) -> some View {
        let label = HubCardLabel(icon: card.icon, accent: card.accent, title: card.title, subtitle: card.subtitle)
        if let destination = card.destination {
            NavigationLink(value: destination) { label }
                .buttonStyle(.plain)
                .disabled(card.disabled)
                .opacity(card.disabled ? 0.55 : 1)
        } else if let sheet = card.sheet {
            Button { openSheet(sheet) } label: { label }
                .buttonStyle(.plain)
        }
    }

    private func openSheet(_ sheet: HubSheet) {
        MDMHaptics.tap()
        switch sheet {
        case .grabber: showingGrabber = true
        case .torrent: showingTorrent = true
        case .adBlock: showingAdBlock = true
        }
    }
}

/// The card visuals shared by the hub's link and sheet cards. Kept
/// separate from MDMToolCard (which is a Button) so the same label can
/// sit inside a NavigationLink without a nested button.
private struct HubCardLabel: View {
    var icon: String
    var accent: Color
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(accent.opacity(0.16))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .foregroundStyle(accent)
                    .font(.system(size: 19, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Color.primary)
                Text(subtitle).font(.caption).foregroundStyle(Color.mdmMuted).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.mdmSurface, in: RoundedRectangle(cornerRadius: MDMRadius.card))
        .overlay(RoundedRectangle(cornerRadius: MDMRadius.card).stroke(Color.mdmBorder, lineWidth: 1))
    }
}
