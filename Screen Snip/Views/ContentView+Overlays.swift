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
    func permissionsSheetContent() -> some View {
        PermissionsView(
            needsAccessibility: appDelegate.needsAccessibilityPermission,
            needsScreenRecording: appDelegate.needsScreenRecordingPermission,
            onContinue: {
                appDelegate.showPermissionsView = false
            }
        )
    }
}
