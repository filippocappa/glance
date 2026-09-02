// SplashView.swift
// Glance
//
// First-run onboarding: permission status, launch-at-login, and the two global
// shortcuts. Also reachable later from the menu bar, so every control here has
// to reflect live state rather than a one-shot snapshot.

import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin

// MARK: - SplashView

struct SplashView: View {

    /// Called when the user dismisses onboarding.
    var onFinish: () -> Void

    /// Live Screen Recording status. Re-read whenever the window is shown or
    /// the app is reactivated — macOS grants the permission out-of-process, so
    /// nothing notifies us when it flips.
    @State private var hasScreenRecording = Permissions.hasScreenRecordingAccess()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.15)

            ScrollView {
                VStack(spacing: 12) {
                    permissionCard
                    launchAtLoginCard
                    shortcutsCard
                }
                .padding(20)
            }

            Divider().opacity(0.15)
            footer
        }
        .frame(width: 460, height: 600)
        .background(VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow))
        .preferredColorScheme(.dark)
        // One tint for every button, toggle and recorder in the window.
        .tint(Theme.accent)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            hasScreenRecording = Permissions.hasScreenRecordingAccess()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "pip.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accentGradient)
                .padding(.top, 28)

            Text("Glance")
                .font(.system(size: 30, weight: .semibold, design: .rounded))

            Text("Universal Picture-in-Picture for macOS, built natively with Swift.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 22)
        }
    }

    // MARK: Cards

    private var permissionCard: some View {
        Card(
            icon: "lock.shield",
            title: "Screen Recording",
            subtitle: hasScreenRecording
                ? "Granted — Glance can capture your screen."
                : "Required. Glance cannot capture anything without it."
        ) {
            HStack(spacing: 8) {
                StatusDot(ok: hasScreenRecording)
                Text(hasScreenRecording ? "Allowed" : "Not allowed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hasScreenRecording
                                     ? AnyShapeStyle(Theme.accent)
                                     : AnyShapeStyle(Color.orange))

                Spacer()

                if !hasScreenRecording {
                    Button("Grant Permission") {
                        // Shows the system consent dialog. If the user has
                        // already answered once, macOS will not show it again,
                        // so fall through to System Settings.
                        if !Permissions.requestScreenRecordingAccess() {
                            Permissions.openScreenRecordingSettings()
                        }
                        hasScreenRecording = Permissions.hasScreenRecordingAccess()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }

            if !hasScreenRecording {
                Text("After allowing it in System Settings, quit and reopen Glance — macOS only applies the change to a fresh launch.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var launchAtLoginCard: some View {
        Card(
            icon: "power",
            title: "Launch at Login",
            subtitle: "Start Glance automatically when you log in."
        ) {
            LaunchAtLogin.Toggle {
                Text("Open at login")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var shortcutsCard: some View {
        Card(
            icon: "command",
            title: "Global Shortcuts",
            subtitle: "Work from any app, even when Glance isn't focused."
        ) {
            VStack(spacing: 10) {
                HStack {
                    Text("New capture")
                        .font(.system(size: 12))
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .newCapture)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Toggle Ghost Mode")
                            .font(.system(size: 12))
                        Text("Your way out — Ghost Mode ignores the mouse.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .toggleGhostMode)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("v\(Bundle.main.shortVersion)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer()

            Button("Start Glancing") { onFinish() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - Card

/// A rounded translucent panel: icon + title + subtitle, then arbitrary content.
private struct Card<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Theme.accent.opacity(0.14), lineWidth: 1)
                )
        )
    }
}

private struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Circle()
            .fill(ok ? Color.green : Color.orange)
            .frame(width: 7, height: 7)
    }
}

// MARK: - Bundle

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
