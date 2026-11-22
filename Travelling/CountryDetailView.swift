import PhotosUI
import SwiftUI
import UIKit

struct CountryDetailView: View {
    @ObservedObject var store: TravelStore
    let country: Country

    @Environment(\.locale) private var locale
    @StateObject private var locationService = LocationService()
    @State private var visited = false
    @State private var visitDate = Date.now
    @State private var cityName = ""
    @State private var cityDate = Date.now
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var errorMessage: String?

    private var countryVisit: CountryVisit {
        store.visit(for: country.code)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                countryHeader
                visitControls
                photoSection
                citySection
            }
            .padding(20)
        }
        .background(Color.travelBackground.ignoresSafeArea())
        .navigationTitle(country.name(in: locale.identifier))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            visited = countryVisit.visited
            visitDate = countryVisit.visitedAt ?? .now
        }
        .onChange(of: visited) { _, value in
            do {
                try store.setVisited(value, for: country.code, date: visitDate)
            } catch {
                visited = countryVisit.visited
                errorMessage = error.localizedDescription
            }
        }
        .onChange(of: visitDate) { _, value in
            guard visited else { return }
            do {
                try store.setVisitDate(value, for: country.code)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw PhotoError.unreadable
                    }
                    try store.setPhoto(Self.normalizedPhotoData(from: data), for: country.code)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .onReceive(locationService.$state) { state in
            if case .found(let city) = state {
                cityName = city.name
                cityDate = city.date
            }
        }
        .alert("Something went wrong", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var countryHeader: some View {
        HStack(spacing: 16) {
            Text(country.flag)
                .font(.system(size: 58))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(country.name(in: locale.identifier))
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text(country.code)
                    .font(.subheadline.weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.travelCard, in: RoundedRectangle(cornerRadius: 22))
    }

    private var visitControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("I've visited this country", isOn: $visited)
                .font(.headline)
                .tint(.cyan)
                .foregroundStyle(.white)

            if visited {
                DatePicker("Visit date", selection: $visitDate, displayedComponents: .date)
                    .tint(.cyan)
                    .foregroundStyle(.white)
            }
        }
        .padding(18)
        .background(Color.travelCard, in: RoundedRectangle(cornerRadius: 18))
    }

    private var photoSection: some View {
        let photoURL = store.photoURL(for: country.code)
        let photoImage = photoURL.flatMap { UIImage(contentsOfFile: $0.path) }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Country photo")
                .font(.headline)
                .foregroundStyle(.white)

            if let image = photoImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Photo from \(country.name(in: locale.identifier))")
            } else {
                ContentUnavailableView(
                    "No photo yet",
                    systemImage: "photo",
                    description: Text("Add a selfie or memory from this country.")
                )
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .foregroundStyle(.white.opacity(0.8))
            }

            HStack {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label(photoURL == nil ? "Choose photo" : "Change photo", systemImage: "photo")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
                Spacer()
                if photoURL != nil {
                    Button("Remove photo", role: .destructive) {
                        do {
                            try store.setPhoto(nil, for: country.code)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private var citySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cities and trips")
                .font(.headline)
                .foregroundStyle(.white)

            HStack {
                TextField("City", text: $cityName)
                    .textContentType(.addressCity)
                    .textInputAutocapitalization(.words)
                    .padding(12)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                Button {
                    locationService.requestCity()
                } label: {
                    Image(systemName: "location.fill")
                        .font(.headline)
                        .foregroundStyle(.cyan)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("Use current location")
            }

            if case .requesting = locationService.state {
                ProgressView("Finding your city…")
                    .tint(.cyan)
                    .foregroundStyle(.white.opacity(0.75))
            } else if case .failed(let message) = locationService.state {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            DatePicker("Date", selection: $cityDate, displayedComponents: .date)
                .tint(.cyan)
                .foregroundStyle(.white)

            Button {
                let trimmedCity = cityName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedCity.isEmpty else { return }
                let coordinates: (Double?, Double?)
                if case .found(let location) = locationService.state {
                    coordinates = (location.latitude, location.longitude)
                } else {
                    coordinates = (nil, nil)
                }
                do {
                    try store.addCity(
                        CityVisit(name: trimmedCity, date: cityDate, latitude: coordinates.0, longitude: coordinates.1),
                        for: country.code
                    )
                    cityName = ""
                    locationService.reset()
                } catch {
                    errorMessage = error.localizedDescription
                }
            } label: {
                Label("Add city", systemImage: "plus")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.cyan, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(Color.travelBackground)
            }
            .disabled(cityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if !countryVisit.cities.isEmpty {
                ForEach(countryVisit.cities) { city in
                    HStack(spacing: 12) {
                        Image(systemName: city.latitude == nil ? "building.2" : "location")
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(city.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(city.date, style: .date)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.62))
                        }
                        Spacer()
                        Button(role: .destructive) {
                            do {
                                try store.removeCity(city, from: country.code)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .accessibilityLabel("Remove \(city.name)")
                    }
                    .padding(12)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(18)
        .background(Color.travelCard, in: RoundedRectangle(cornerRadius: 18))
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private static func normalizedPhotoData(from data: Data) throws -> Data {
        guard let image = UIImage(data: data) else { throw PhotoError.unreadable }
        let longestSide = max(image.size.width, image.size.height)
        let scale = min(1, 2048 / max(longestSide, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let compressed = resized.jpegData(compressionQuality: 0.82) else {
            throw PhotoError.unreadable
        }
        return compressed
    }
}

private enum PhotoError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        AppLanguage.localized("The selected photo could not be read.")
    }
}

extension Color {
    static let travelBackground = Color(red: 0.035, green: 0.075, blue: 0.15)
    static let travelCard = Color(red: 0.08, green: 0.15, blue: 0.25)
}
