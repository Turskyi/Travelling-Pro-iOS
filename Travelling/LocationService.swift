import Combine
import CoreLocation
import Foundation

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum State {
        case idle
        case requesting
        case found(CityVisit)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var waitingForAuthorization = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func requestCity() {
        switch manager.authorizationStatus {
        case .notDetermined:
            waitingForAuthorization = true
            state = .requesting
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            state = .requesting
            manager.requestLocation()
        case .denied, .restricted:
            state = .failed(AppLanguage.localized("Location access is unavailable. You can enter a city manually."))
        @unknown default:
            state = .failed(AppLanguage.localized("Location access is unavailable. You can enter a city manually."))
        }
    }

    func reset() {
        state = .idle
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard waitingForAuthorization else { return }
        waitingForAuthorization = false
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        } else {
            state = .failed(AppLanguage.localized("Location access is unavailable. You can enter a city manually."))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            state = .failed(AppLanguage.localized("Could not determine your location. Try again or enter a city manually."))
            return
        }
        Task {
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                guard let place = placemarks.first,
                      let city = place.locality ?? place.subAdministrativeArea
                else {
                    state = .failed(AppLanguage.localized("Could not find a city for this location. Enter it manually."))
                    return
                }
                state = .found(CityVisit(
                    name: city,
                    date: .now,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                ))
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        state = .failed(error.localizedDescription)
    }
}
