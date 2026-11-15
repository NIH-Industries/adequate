import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject var spaces: SpaceStore

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { spaces.sidebarShown ? .all : .detailOnly },
            set: { spaces.sidebarShown = $0 != .detailOnly }
        )) {
            Sidebar(spaces: spaces, state: spaces.current)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            SpaceDetail(state: spaces.current)
                .id(spaces.selected)
        }
        // No title bar or toolbar: ⌘S shows and hides the sidebar.
        .toolbar(.hidden, for: .windowToolbar)
        .overlay(alignment: .bottom) {
            if let toast = spaces.toast {
                Text(toast)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: spaces.toast)
        .sheet(item: $spaces.prompt) { prompt in
            SpacePromptSheet(spaces: spaces, prompt: prompt)
        }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @ObservedObject var spaces: SpaceStore
    @ObservedObject var state: SpaceState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(state.space.symbol)
                Text(state.space.name).font(.headline).lineLimit(1)
                Spacer()
                Menu {
                    SpaceMenuItems(spaces: spaces, id: state.space.id)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Button { state.newTab() } label: {
                Label("New Tab", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List(selection: $state.selectedTabID) {
                ForEach(state.tabs) { tab in
                    TabRow(tab: tab, close: { state.close(tab.id) },
                           popOut: { spaces.openInNewWindow(tab.id, from: state) })
                        .tag(tab.id)
                }
            }

            Divider()
            SpaceSwitcher(spaces: spaces)
        }
        // A wash of the Space's colour, so you can tell at a glance where you are.
        .background(state.space.tint.opacity(0.12))
        .tint(state.space.tint)
    }
}

/// Edit, reorder and delete, shared by the header menu and each switcher dot.
struct SpaceMenuItems: View {
    @ObservedObject var spaces: SpaceStore
    let id: Space.ID

    var body: some View {
        let index = spaces.states.firstIndex { $0.space.id == id } ?? 0
        Button("Edit Space…") { spaces.prompt = .edit(id) }
        Button("Move Left") { spaces.move(id, by: -1) }.disabled(index == 0)
        Button("Move Right") { spaces.move(id, by: 1) }.disabled(index == spaces.states.count - 1)
        Divider()
        Button("Delete Space…", role: .destructive) { spaces.prompt = .delete(id) }
            .disabled(spaces.states.count < 2)
        Divider()
        Button("New Space…") { spaces.prompt = .new }
    }
}

/// One dot per Space along the bottom of the sidebar, like Arc's.
struct SpaceSwitcher: View {
    @ObservedObject var spaces: SpaceStore

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(spaces.states.enumerated()), id: \.element.space.id) { index, state in
                        SpaceDot(state: state, number: index + 1, selected: state.space.id == spaces.selected) {
                            spaces.select(state.space.id)
                        }
                        .contextMenu { SpaceMenuItems(spaces: spaces, id: state.space.id) }
                    }
                }
                .padding(.vertical, 2)
            }
            Button { spaces.prompt = .new } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("New Space (⇧⌘N)")
        }
        .padding(10)
    }
}

struct SpaceDot: View {
    @ObservedObject var state: SpaceState
    let number: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(state.space.symbol)
                .font(.system(size: 14))
                .frame(width: 26, height: 26)
                .background(Circle().fill(state.space.tint.opacity(selected ? 0.9 : 0.3)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.6 : 0), lineWidth: 1.5)
                    .padding(-3))
                .overlay(alignment: .topTrailing) {
                    if !state.audibleTabs.isEmpty {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 7, weight: .bold))
                            .padding(2.5)
                            .background(Circle().fill(.background))
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(number <= 9 ? "\(state.space.name) (⌃\(number))" : state.space.name)
    }
}

struct TabRow: View {
    @ObservedObject var tab: Tab
    let close: () -> Void
    let popOut: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let favicon = tab.favicon {
                    Image(nsImage: favicon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            Text(tab.displayTitle).lineLimit(1)
                .help(tab.address)
            Spacer()
            if tab.isPlayingAudio || tab.isMuted {
                Button(action: tab.toggleMute) {
                    Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(tab.isMuted ? "Unmute Tab" : "Mute Tab")
            }
            if hovering {
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.address, forType: .string)
            }
            .disabled(tab.address.isEmpty)
            Button(tab.isMuted ? "Unmute Tab" : "Mute Tab", action: tab.toggleMute)
            Button("Pause Media", action: tab.pauseMedia).disabled(!tab.isPlayingAudio)
            Divider()
            Button("Open in New Window", action: popOut)
            Button("Close Tab", action: close)
        }
    }
}

// MARK: Space dialogs

struct SpacePromptSheet: View {
    @ObservedObject var spaces: SpaceStore
    let prompt: SpacePrompt
    @State private var name = ""
    @State private var emoji = ""
    @State private var color = SpaceColor.blue

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch prompt {
            case .new:
                nameForm(title: "New Space", action: "Create", except: nil) {
                    spaces.addSpace(named: name, color: color, emoji: emoji)
                }
                .onAppear { (color, emoji) = spaces.freshLook(for: "") }
            case .edit(let id):
                nameForm(title: "Edit Space", action: "Save", except: id) {
                    spaces.edit(id, name: name, color: color, emoji: emoji)
                }
                .onAppear {
                    guard let space = spaces.state(id)?.space else { return }
                    name = space.name
                    emoji = space.symbol
                    color = space.color ?? .blue
                }
            case .delete(let id):
                let spaceName = spaces.state(id)?.space.name ?? "this Space"
                Text("Delete \(spaceName)?").font(.headline)
                Text("Its tabs close, and its cookies, logins and site data are erased. This can't be undone.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { spaces.prompt = nil }.keyboardShortcut(.cancelAction)
                    Button("Delete", role: .destructive) {
                        spaces.prompt = nil
                        spaces.delete(id)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    @ViewBuilder
    private func nameForm(title: String, action: String, except: Space.ID?, commit: @escaping () -> Void) -> some View {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = spaces.isNameTaken(trimmed, except: except)
        Text(title).font(.headline)
        HStack {
            TextField("🙂", text: $emoji)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 40)
                .help("Emoji (⌃⌘Space for the picker)")
                // Keep just the newest character typed or picked.
                .onChange(of: emoji) { _, new in
                    if new.count > 1, let last = new.last { emoji = String(last) }
                }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !trimmed.isEmpty && !taken { spaces.prompt = nil; commit() } }
        }
        HStack(spacing: 6) {
            ForEach(SpaceColor.swatches) { choice in
                Circle()
                    .fill(choice.color)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(Color.primary, lineWidth: choice == color ? 2 : 0).padding(-3))
                    .contentShape(Circle())
                    .onTapGesture { color = choice }
                    .help(choice.rawValue.capitalized)
            }
            // Anything else, from the system colour panel.
            ColorPicker("", selection: Binding(get: { color.color }, set: { color = SpaceColor($0) }),
                        supportsOpacity: false)
                .labelsHidden()
                .overlay(Circle().strokeBorder(Color.primary, lineWidth: color.isCustom ? 2 : 0)
                    .frame(width: 26, height: 26).allowsHitTesting(false))
                .help("Custom colour")
        }
        .padding(.vertical, 2)
        if taken {
            Text("There's already a Space called \(trimmed).").font(.caption).foregroundStyle(.red)
        }
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { spaces.prompt = nil }.keyboardShortcut(.cancelAction)
            Button(action) { spaces.prompt = nil; commit() }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty || taken)
        }
    }
}

// MARK: Page

struct SpaceDetail: View {
    @ObservedObject var state: SpaceState

    var body: some View {
        if let tab = state.selectedTab {
            TabPage(tab: tab).id(tab.id)
        } else {
            VStack(spacing: 12) {
                Text(state.space.symbol).font(.system(size: 64))
                Text(state.space.name).font(.largeTitle)
                Button("New Tab  ⌘T") { state.newTab() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The page fills the whole window, right up under the title bar. The address
/// bar only floats over it while you're using it: ⌘L, or a blank tab.
struct TabPage: View {
    @ObservedObject var tab: Tab
    @State private var draft = ""
    @State private var editing = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        WebViewHost(webView: tab.webView)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                if tab.isLoading {
                    ProgressView(value: max(tab.progress, 0.05))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if editing { addressBar }
            }
            .onAppear {
                draft = tab.address
                // A blank tab wants an address; one opened with a page wants the page.
                if tab.isBlank { edit() } else { tab.focusPage() }
            }
            .onChange(of: tab.address) { _, address in
                if !addressFocused || draft.isEmpty { draft = address }
            }
            .onChange(of: tab.focusRequest) { _, _ in edit() }
            .onChange(of: addressFocused) { _, focused in
                if !focused { finish() }
            }
    }

    private var addressBar: some View {
        HStack(spacing: 6) {
            Button(action: tab.goBack) { Image(systemName: "chevron.left") }
                .disabled(!tab.canGoBack).help("Back (⌘[)")
            Button(action: tab.goForward) { Image(systemName: "chevron.right") }
                .disabled(!tab.canGoForward).help("Forward (⌘])")
            Button(action: tab.reload) { Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise") }
                .help(tab.isLoading ? "Stop" : "Reload (⌘R)")
            // Taking focus selects the whole address, ready to type over.
            TextField("Search or enter address", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($addressFocused)
                .onSubmit {
                    tab.load(draft)
                    finish()
                }
                .onExitCommand {
                    finish()
                    tab.focusPage()
                }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 720)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(radius: 12, y: 4)
        .padding(.horizontal, 24)
        .padding(.top, 10)
    }

    private func edit() {
        draft = tab.address
        editing = true
        // The field has to exist before it can take focus.
        DispatchQueue.main.async { addressFocused = true }
    }

    private func finish() {
        editing = false
        addressFocused = false
        draft = tab.address
    }
}

/// Holds a tab's web view. The web view lives in a container, so when a tab
/// moves to another window, the old place letting go can't pull it back out.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        adopt(into: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) { adopt(into: container) }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func adopt(into container: NSView) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
