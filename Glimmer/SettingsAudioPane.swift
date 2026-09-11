//
//  SettingsAudioPane.swift
//
//  The Audio pane: the channel layout asked of the host, and what this Mac does
//  with its own sound while a stream plays.
//

import SwiftUI

struct AudioPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsPageBody {
            SettingsField("Channels") {
                Picker("", selection: $model.audioLayout) {
                    ForEach(AudioLayout.allCases) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
                SettingsNote("This Mac's default output is "
                    + "\(AudioConfig.bestForCurrentOutput().displayLabel.lowercased()) right now. Surround needs "
                    + "the host to have a matching layout; Opus carries it losslessly downmixed otherwise. "
                    + "Applies to the next stream.")
            }

            SettingsField("This Mac") {
                Toggle("Mute this Mac while streaming", isOn: $model.muteMacWhileStreaming)
                SettingsNote("Keeps game audio on the gaming PC's output only; this Mac stays silent for the "
                    + "length of the stream. Takes effect immediately, mid-stream too.")
            }
        }
    }
}
