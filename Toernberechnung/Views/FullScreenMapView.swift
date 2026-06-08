import SwiftUI
import CoreLocation

struct FullScreenMapView: View {
    @Binding var isPresented: Bool
    let start: HarbourOption
    let destination: HarbourOption
    let routePlan: RoutePlan?
    let waypointResults: [WaypointCalculationResult]?
    let breadcrumbs: [CLLocationCoordinate2D]

    var body: some View {
        // `ZStack(alignment: .topTrailing)` with the button as a direct child
        // mirrors the embedded map's expand button, which taps reliably. The
        // previous layout nested the button in a VStack/HStack/Spacer and used
        // `appCircularGlass`, whose interactive Liquid-Glass effect swallowed
        // the tap on top of the MapKit view, so the X never dismissed.
        ZStack(alignment: .topTrailing) {
            CompactMapView(
                zoomLevel: 10,
                start: start,
                destination: destination,
                routePlan: routePlan,
                waypointResults: waypointResults,
                voyageActive: false,
                breadcrumbCoordinates: breadcrumbs
            )
            .ignoresSafeArea()

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .padding(.trailing, 16)
            .padding(.top, 16)
            .accessibilityLabel("Vollbild schließen")
            .zIndex(1)
        }
        .background(Color.black)
    }
}
