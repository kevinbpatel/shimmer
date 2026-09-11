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
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsField("This Mac") {
                Toggle("Mute this Mac while streaming", isOn: $model.muteMacWhileStreaming)
            }
        }
    }
}
