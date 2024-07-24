import Foundation
import MapboxMaps
@testable import MapboxNavigationCore

public class PredictiveCacheManagerSpy: PredictiveCacheManager {
    public var passedMapView: MapView?

    public init() {
        super.init(predictiveCacheOptions: .init(), tileStore: .default)
    }

    override public func updateMapControllers(mapView: MapView) {
        passedMapView = mapView
    }
}
