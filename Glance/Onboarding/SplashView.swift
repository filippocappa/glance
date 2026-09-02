// SplashView.swift
// Glance
//
// First-run onboarding, sharing Hum's design vocabulary: an ambient accent
// glow behind a glyph, a rounded wordmark, stacked dark-glass cards, and a
// full-width pill action with a specular sheen.
//
// The entrance is staged rather than simultaneous — glow, then wordmark, then
// each card in turn — so the eye is led down the window.

import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin

// MARK: - SplashView

struct SplashView: View {
    var onDismiss: () -> Void

    /// Live Screen Recording status. Re-read whenever the app is reactivated —
    /// macOS grants the permission out-of-process and never notifies us.
    @State private var hasScreenRecording = Permissions.hasScreenRecordingAccess()

    @State private var glowIn = false
    @State private var titleIn = false
    @State private var cardsIn = 0
    @State private var actionIn = false
    @State private var hoveredCard: Int?

    /// The splash is achromatic — see Theme.mono. The cyan accent is reserved
    /// for surfaces that sit over the user's own content.
    private var accent: Color { Theme.mono }

    private static let spring = Animation.spring(response: 0.6, dampingFraction: 0.75)
    private static let cardSpring = Animation.spring(response: 0.55, dampingFraction: 0.8)

    var body: some View {
        ZStack {
            backdrop

            VStack(spacing: 0) {
                header
                cards.padding(.top, 16)
                Spacer(minLength: 10)
                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 18)
        }
        .frame(
            width: SplashWindowController.size.width,
            height: SplashWindowController.size.height
        )
        .preferredColorScheme(.dark)
        .tint(Theme.monoTint)
        .onAppear(perform: runEntrance)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            hasScreenRecording = Permissions.hasScreenRecordingAccess()
        }
    }

    // MARK: Backdrop

    private var backdrop: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)

            // Darkens the vibrancy so light text keeps its contrast.
            Color.black.opacity(Theme.scrim)

            // Ambient accent glow, settling in behind the glyph.
            // Diffuse silver ambience rather than a saturated bloom: a wide,
            // low-alpha falloff reads as light in the room, not a colour wash.
            RadialGradient(
                colors: [
                    accent.opacity(glowIn ? 0.13 : 0),
                    accent.opacity(glowIn ? 0.05 : 0),
                    .clear
                ],
                center: .init(x: 0.5, y: 0.26),
                startRadius: 10,
                endRadius: 340
            )
        }
        .ignoresSafeArea()
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            PulsingGlyph(accent: accent, size: 24, glowRadius: 60)
                .frame(height: 44)
                .scaleEffect(glowIn ? 1 : 0.8)
                .opacity(glowIn ? 1 : 0)

            Text("Glance")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .tracking(0.5)

            Text("Universal Picture-in-Picture for macOS, built natively with Swift.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .offset(y: titleIn ? 0 : -8)
        .opacity(titleIn ? 1 : 0)
    }

    // MARK: Cards

    private var cards: some View {
        VStack(spacing: 7) {
            card(index: 0,
                 symbol: hasScreenRecording ? "checkmark.shield.fill" : "lock.shield",
                 title: "Screen Recording",
                 detail: hasScreenRecording
                    ? "Granted. Glance can capture any window on your Mac."
                    : "Required. Glance cannot capture anything without it.") {
                if hasScreenRecording {
                    Text("Allowed")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Grant") {
                        // Shows the system consent dialog. If the user has
                        // already answered once macOS will not show it again,
                        // so fall through to System Settings.
                        if !Permissions.requestScreenRecordingAccess() {
                            Permissions.openScreenRecordingSettings()
                        }
                        hasScreenRecording = Permissions.hasScreenRecordingAccess()
                    }
                    .controlSize(.small)
                }
            }

            card(index: 1, symbol: "power",
                 title: "Open at login",
                 detail: "Keep Glance ready in your menu bar when your Mac starts up.") {
                LaunchAtLogin.Toggle { EmptyView() }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Theme.monoTint)
                    .accessibilityLabel("Launch at Login")
            }

            shortcutsCard(index: 2)
        }
    }

    /// Both hotkeys in one card, split by internal hairlines.
    ///
    /// They were previously two free-standing rows, which read as unrelated
    /// containers and cost two full card heights.
    private func shortcutsCard(index: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "command")
                    .font(.system(size: 14))
                    .foregroundStyle(accent)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Global shortcuts")
                        .font(.callout.weight(.medium))
                    Text("Work from any app, even when Glance isn't focused.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 9)

            Divider().overlay(Theme.cardStroke)
            shortcutRow("New capture", .newCapture)
            Divider().overlay(Theme.cardStroke).padding(.leading, 14)
            shortcutRow("Ghost Mode", .toggleGhostMode)
        }
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .fill(hoveredCard == index ? Theme.cardFillHover : Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(Theme.cardStroke, lineWidth: 1))
        .onHover { hoveredCard = $0 ? index : nil }
        .animation(.easeOut(duration: 0.15), value: hoveredCard)
        .opacity(cardsIn > index ? 1 : 0)
        .offset(y: cardsIn > index ? 0 : 20)
    }

    private func shortcutRow(_ label: String, _ name: KeyboardShortcuts.Name) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            KeyboardShortcuts.Recorder(for: name)
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func card(index: Int, symbol: String, title: String, detail: String?,
                      @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .fill(hoveredCard == index ? Theme.cardFillHover : Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(Theme.cardStroke, lineWidth: 1))
        .onHover { hoveredCard = $0 ? index : nil }
        .animation(.easeOut(duration: 0.15), value: hoveredCard)
        .opacity(cardsIn > index ? 1 : 0)
        .offset(y: cardsIn > index ? 0 : 20)
    }

    // MARK: Footer

    private var footer: some View {
        StartButton(accent: accent, action: onDismiss)
            .opacity(actionIn ? 1 : 0)
            .offset(y: actionIn ? 0 : 10)
    }

    // MARK: Entrance

    /// 0.0 glow · 0.1 title · 0.2–0.4 cards · 0.5 action.
    private func runEntrance() {
        withAnimation(Self.spring) { glowIn = true }
        withAnimation(Self.cardSpring.delay(0.1)) { titleIn = true }
        for i in 1...3 {
            withAnimation(Self.cardSpring.delay(0.2 + Double(i - 1) * 0.1)) { cardsIn = i }
        }
        withAnimation(Self.cardSpring.delay(0.5)) { actionIn = true }
    }
}

// MARK: - PulsingGlyph

/// The app mark with a slow ambient bloom behind it.
///
/// The breath is deliberately long and shallow: it should register as the
/// window being alive, not as an animation demanding attention.
struct PulsingGlyph: View {
    var accent: Color
    var size: CGFloat
    var glowRadius: CGFloat

    @State private var breathing = false

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [accent.opacity(0.30), accent.opacity(0.0)],
                center: .center,
                startRadius: 0,
                endRadius: glowRadius / 2
            )
            .frame(width: glowRadius, height: glowRadius)
            .scaleEffect(breathing ? 1.12 : 0.88)
            .opacity(breathing ? 1.0 : 0.65)
            .allowsHitTesting(false)

            Image(systemName: "pip.fill")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(accent)
                .shadow(color: accent.opacity(0.35), radius: 14)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}

// MARK: - StartButton

/// Primary action with a specular sheen that brightens under the pointer.
private struct StartButton: View {
    var accent: Color
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Start Glancing")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.onMono)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    // Solid white, with only a whisper of gradient so the
                    // specular rim has something to sit against.
                    Capsule()
                        .fill(LinearGradient(
                            colors: [.white, accent.opacity(hovering ? 1.0 : 0.93)],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .overlay(
                            // Specular top edge, the way light lands on glass.
                            Capsule().stroke(
                                LinearGradient(
                                    colors: [.white.opacity(hovering ? 0.5 : 0.32), .white.opacity(0.06)],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                        )
                )
                .shadow(color: .white.opacity(hovering ? 0.22 : 0.10), radius: hovering ? 16 : 8, y: 3)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.02 : 1)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
    }
}

// MARK: - Bundle

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
