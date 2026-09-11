import SwiftUI

extension ContentView {
    @ViewBuilder
    func copiedHUDOverlay() -> some View {
        CopiedHUD()
            .transition(.scale)
            .padding(20)
            .zIndex(1)
    }
    
    @ViewBuilder
    func aboutOverlayLayer() -> some View {
        AboutOverlayView(isPresented: aboutOverlayBinding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .zIndex(10)
    }
    
    @ViewBuilder
    func permissionsRequiredContent() -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)

                    PermissionsView(
                        needsScreenRecording: appDelegate.needsScreenRecordingPermission,
                        onContinue: {
                            appDelegate.showPermissionsView = false
                        }
                    )

                    Spacer(minLength: 32)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollIndicators(.automatic)
        }
    }
}
