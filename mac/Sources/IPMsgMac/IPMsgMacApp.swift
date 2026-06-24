//  IPMsgMacApp.swift
//  SwiftUI entry point for the macOS IP Messenger client.

import SwiftUI
import IPMsgCore

@main
struct IPMsgMacApp: App {
    @StateObject private var engine = IPMessenger()

    var body: some Scene {
        WindowGroup("IP Messenger") {
            ContentView()
                .environmentObject(engine)
                .frame(minWidth: 720, minHeight: 460)
                .onAppear {
                    do { try engine.start() }
                    catch { NSLog("IPMsg start failed: \(error)") }
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Refresh Member List") { engine.announceEntry() }
                    .keyboardShortcut("r")
            }
        }
    }
}
