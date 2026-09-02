// SplashWindowController.swift
// Glance
//
// Hosts SplashView in a floating dark-glass window.
//
// Glance is an LSUIElement agent, so it is never the active app on its own.
// Showing this window therefore has to activate the app explicitly, otherwise
// it appears behind whatever the user was doing and cannot take keyboard focus
// — which would make the KeyboardShortcuts recorders impossible to use.

import AppKit
import SwiftUI

@MainActor
final class SplashWindowController {

    /// UserDefaults key marking onboarding as completed.
    private static let didCompleteOnboardingKey = "didCompleteOnboarding"

    /// Whether the user has finished onboarding at least once.
    static var didCompleteOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: didCompleteOnboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: didCompleteOnboardingKey) }
    }

    private var window: NSWindow?

    /// Shows the splash, creating it on first use and reusing it thereafter.
    func show() {
        if let window {
            Self.activateApp()
            window.makeKeyAndOrderFront(nil)
            window.center()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: SplashView(onFinish: { [weak self] in
            Self.didCompleteOnboarding = true
            self?.close()
        }))
        window.contentView = hosting

        // Round the glass to match the card aesthetic.
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 12
        window.contentView?.layer?.masksToBounds = true

        window.center()
        self.window = window

        Self.activateApp()
        window.makeKeyAndOrderFront(nil)

        Log.window.info("Splash window shown")
    }

    /// Brings Glance forward so the splash can take keyboard focus.
    ///
    /// `activate(ignoringOtherApps:)` is deprecated on macOS 14+, where the
    /// plain `activate()` already does the right thing for a user-initiated
    /// foreground request.
    private static func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func close() {
        window?.orderOut(nil)
        // Hand focus back; an agent app holding activation is unusual and
        // prevents the user's previous app from regaining key status cleanly.
        NSApp.hide(nil)
    }

    /// Shows the splash only if onboarding has never been completed.
    func showIfFirstRun() {
        guard !Self.didCompleteOnboarding else { return }
        Log.window.info("First run — presenting onboarding")
        show()
    }
}
