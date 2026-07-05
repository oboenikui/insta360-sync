import SwiftUI

struct LocationPermissionBanner: View {
    @Bindable private var auth = LocationAuthorization.shared

    var body: some View {
        if !auth.isAuthorized {
            VStack(alignment: .leading, spacing: 6) {
                Text(auth.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                if let title = auth.actionButtonTitle {
                    Button(title) {
                        LocationAuthorization.shared.requestAuthorization()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}
