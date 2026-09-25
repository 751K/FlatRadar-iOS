import FlatRadarCore
import MapKit
import SwiftUI

/// A local neighborhood preview; its camera never changes the main Map tab.
struct ListingMapCard: View {
    let listing: Listing
    var isSplitDetail = false

    private enum LoadState {
        case loading
        case located(MapListing)
        case notFound
        case noCoordinates
        case failed
    }

    @State private var state: LoadState = .loading
    @State private var camera: MapCameraPosition = .automatic
    @State private var retryCount = 0

    var body: some View {
        mapContent
        .frame(height: isSplitDetail ? 300 : 260)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .task(id: retryCount) { await load() }
    }

    @ViewBuilder
    private var mapContent: some View {
        switch state {
        case .located(let location):
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                // Use the address coordinate, not the offset used to separate
                // overlapping listings in the main map.
                Marker(listing.name, systemImage: "house.fill", coordinate: location.coordinate)
                    .tint(Color.accentColor)
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .all))
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        camera = Self.neighborhoodCamera(for: location)
                    }
                } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.primary.opacity(0.08)))
                        .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Recenter")
                .padding(12)
            }
            .accessibilityIdentifier("listing-detail-map")
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notFound:
            placeholder("Not on the map", detail: "The server doesn’t have this listing.")
        case .noCoordinates:
            placeholder("No coordinates yet", detail: "This address hasn’t been geocoded.")
        case .failed:
            VStack(spacing: 12) {
                Label("Couldn’t load the map", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
                Button("Try Again") { retryCount += 1 }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "mappin.slash")
                .font(.title2)
            Text(title).font(.headline)
            Text(detail).font(.subheadline)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func neighborhoodCamera(for location: MapListing) -> MapCameraPosition {
        .region(MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 600,
            longitudinalMeters: 600
        ))
    }

    private func load() async {
        // Retain a loaded map when returning from the main Map tab.
        if case .located = state { return }
        state = .loading
        do {
            let result = try await APIClient.shared.locateListing(id: listing.id)
            guard !Task.isCancelled else { return }
            switch result {
            case .located(let location):
                camera = Self.neighborhoodCamera(for: location)
                state = .located(location)
            case .notFound:
                state = .notFound
            case .noCoordinates:
                state = .noCoordinates
            }
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed
        }
    }
}
