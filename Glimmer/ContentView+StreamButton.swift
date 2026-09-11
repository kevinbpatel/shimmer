//
//  ContentView+StreamButton.swift
//
//  The hero's morphing primary action and the material-weighted button style it
//  shares with the other accent CTAs: the six `ButtonRole` states (choose a PC,
//  stream, connecting, back-to-stream, wake, waking) and the two roles that are
//  really CANCELS - `.connecting` and `.waking` both stay enabled, carry a quiet
//  trailing "Cancel", and bind ⎋. Split out of ContentViewSubviews.swift to keep
//  each file under the length limit.
//

import SwiftUI

/// Material-weighted accent button - same gradient + glass tint + soft rim as
/// the hero card. Sized naturally by its label so modal-sheet rows keep their
/// layout (the hero StreamButton applies its own `.frame(maxWidth:)`).
/// Internal so SettingsView's Pair/Stream-now buttons share the treatment.
struct StreamButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(minHeight: 46)
            .background {
                Capsule()
                    .fill(accentSurfaceGradient)
                    .glassEffect(
                        .regular.tint(Color.accentColor.opacity(0.25)),
                        in: .capsule
                    )
                    .overlay {
                        Capsule()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.10),
                                        Color.white.opacity(0.02)
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    }
                    .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
            }
            .opacity(isEnabled ? 1.0 : 0.55)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
