//  ContentView.swift
//  Member list + conversation UI.

import SwiftUI
import UniformTypeIdentifiers
import IPMsgCore

struct ContentView: View {
    @EnvironmentObject var engine: IPMessenger
    @State private var selectedPeerID: String?

    var body: some View {
        NavigationSplitView {
            PeerListView(selectedPeerID: $selectedPeerID)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let id = selectedPeerID, let peer = engine.peers.first(where: { $0.id == id }) {
                ConversationView(peer: peer)
                    .id(id)
            } else {
                ContentUnavailableViewCompat(
                    title: "Select a member",
                    systemImage: "person.2",
                    description: "Members on your LAN appear on the left. Pick one to chat or send files.")
            }
        }
    }
}

// MARK: - Sidebar

struct PeerListView: View {
    @EnvironmentObject var engine: IPMessenger
    @Binding var selectedPeerID: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedPeerID) {
                Section("Members (\(engine.peers.count))") {
                    ForEach(engine.peers) { peer in
                        PeerRow(peer: peer).tag(peer.id)
                    }
                }
            }
            Divider()
            HStack {
                Text(engine.identity.nickName)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { engine.announceEntry() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh member list (broadcast entry)")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }
}

struct PeerRow: View {
    let peer: Peer
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(peer.inAbsence ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.displayName).font(.body)
                Text("\(peer.hostName) · \(peer.address)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Conversation

struct ConversationView: View {
    @EnvironmentObject var engine: IPMessenger
    let peer: Peer

    @State private var draft = ""
    @State private var pendingFiles: [URL] = []
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 0) {
            // Transcript
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(engine.messages(for: peer.id)) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: engine.messages(for: peer.id).count) { _ in
                    if let last = engine.messages(for: peer.id).last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            // Attachment chips
            if !pendingFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(pendingFiles, id: \.self) { url in
                            HStack(spacing: 4) {
                                Image(systemName: "doc")
                                Text(url.lastPathComponent).lineLimit(1)
                                Button { pendingFiles.removeAll { $0 == url } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }.buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                        }
                    }.padding(.horizontal, 12).padding(.top, 6)
                }
            }

            // Composer
            HStack(spacing: 8) {
                Button { showImporter = true } label: { Image(systemName: "paperclip") }
                    .help("Attach files")
                TextField("Message to \(peer.displayName)…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit(sendMessage)
                Button("Send", action: sendMessage)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(draft.isEmpty && pendingFiles.isEmpty)
            }
            .padding(12)
        }
        .navigationTitle(peer.displayName)
        .navigationSubtitleCompat("\(peer.userName)@\(peer.hostName) · \(peer.groupName)")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { pendingFiles.append(contentsOf: urls) }
        }
    }

    private func sendMessage() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingFiles.isEmpty else { return }
        engine.send(text: text, to: peer, files: pendingFiles)
        draft = ""
        pendingFiles = []
    }
}

struct MessageBubble: View {
    @EnvironmentObject var engine: IPMessenger
    let message: ChatMessage

    var isOutgoing: Bool { message.direction == .outgoing }

    var body: some View {
        HStack {
            if isOutgoing { Spacer(minLength: 40) }
            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(isOutgoing ? Color.accentColor.opacity(0.85) : Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(isOutgoing ? .white : .primary)
                }
                ForEach(message.attachments) { file in
                    AttachmentRow(file: file, message: message)
                }
                HStack(spacing: 4) {
                    Text(message.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                    if isOutgoing {
                        Image(systemName: message.delivered ? "checkmark.circle.fill" : "checkmark.circle")
                            .font(.caption2)
                            .foregroundStyle(message.delivered ? .green : .secondary)
                    }
                }
            }
            if !isOutgoing { Spacer(minLength: 40) }
        }
    }
}

struct AttachmentRow: View {
    @EnvironmentObject var engine: IPMessenger
    let file: AttachedFile
    let message: ChatMessage

    var body: some View {
        let state = engine.downloads[file.id] ?? .idle
        HStack(spacing: 8) {
            Image(systemName: file.isDir ? "folder" : "doc.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(1)
                Text(byteString(file.size)).font(.caption2).foregroundStyle(.secondary)
                stateView(state)
            }
            Spacer()
            actionButton(state)
        }
        .padding(8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func stateView(_ state: DownloadState) -> some View {
        switch state {
        case .downloading(let got, let total):
            ProgressView(value: Double(got), total: Double(max(total, 1)))
                .frame(width: 180)
        case .done:
            Text("Saved").font(.caption2).foregroundStyle(.green)
        case .failed(let e):
            Text(e).font(.caption2).foregroundStyle(.red).lineLimit(2)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder private func actionButton(_ state: DownloadState) -> some View {
        switch state {
        case .idle, .failed:
            if message.direction == .incoming {
                Button("Download") { engine.download(file, from: message) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        case .downloading:
            ProgressView().controlSize(.small)
        case .done(let url):
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .controlSize(.small)
        }
    }

    private func byteString(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

// MARK: - Back-compat helpers (so it builds on macOS 13)

struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let description: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 42)).foregroundStyle(.secondary)
            Text(title).font(.title3)
            Text(description).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }
    }
}

extension View {
    @ViewBuilder func navigationSubtitleCompat(_ text: String) -> some View {
        #if os(macOS)
        self.navigationSubtitle(text)
        #else
        self
        #endif
    }
}
