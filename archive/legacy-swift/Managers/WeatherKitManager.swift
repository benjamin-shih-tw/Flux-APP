import Foundation
import WeatherKit
import CoreLocation
import SwiftUI

@Observable
final class WeatherKitManager: NSObject, CLLocationManagerDelegate {
    let weatherService = WeatherService.shared
    private let locationManager = CLLocationManager()
    
    var currentApparentTemperature: Double?
    var locationError: Error?
    var weatherError: Error?
    
    override init() {
        super.init()
        locationManager.delegate = self
    }
    
    // Bug Prevention: Handle location authorization gracefully. Don't assume user grants it.
    func requestLocationAndWeather() {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            locationManager.requestLocation()
        } else {
            print("Location access denied. Cannot fetch WeatherKit data.")
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else { return }
        Task {
            await fetchWeather(for: location)
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        self.locationError = error
        print("Location manager failed: \(error.localizedDescription)")
    }
    
    private func fetchWeather(for location: CLLocation) async {
        do {
            let weather = try await weatherService.weather(for: location)
            DispatchQueue.main.async {
                // value is typically in Celsius depending on system locale, but we can standardize it if needed
                self.currentApparentTemperature = weather.currentWeather.apparentTemperature.value
            }
        } catch {
            DispatchQueue.main.async {
                self.weatherError = error
                print("WeatherKit fetch failed: \(error.localizedDescription)")
            }
        }
    }
}
