import _MapboxNavigationHelpers
import Foundation
import MapboxDirections
import MapboxMaps
import Turf
import UIKit

extension NavigationMapView {
    func setupGestureRecognizers() {
        // Gesture recognizer, which is used to detect long taps on any point on the map.
        let longPressGestureRecognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleLongPress(_:))
        )
        addGestureRecognizer(longPressGestureRecognizer)

        // Gesture recognizer, which is used to detect taps on route line, waypoint or POI
        mapViewTapGestureRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(didReceiveTap(gesture:))
        )
        mapViewTapGestureRecognizer.delegate = self
        mapView.addGestureRecognizer(mapViewTapGestureRecognizer)

        makeGestureRecognizersDisableCameraFollowing()
        makeTapGestureRecognizerStopAnimatedTransitions()
    }

    @objc
    private func handleLongPress(_ gesture: UIGestureRecognizer) {
        guard gesture.state == .began else { return }
        let gestureLocation = gesture.location(in: self)
        Task { @MainActor in
            let point = await mapPoint(at: gestureLocation)
            delegate?.navigationMapView(self, userDidLongTap: point)
        }
    }

    /// Modifies `MapView` gesture recognizers to disable follow mode and move `NavigationCamera` to
    /// `NavigationCameraState.idle` state.
    private func makeGestureRecognizersDisableCameraFollowing() {
        for gestureRecognizer in mapView.gestureRecognizers ?? []
            where gestureRecognizer is UIPanGestureRecognizer
            || gestureRecognizer is UIRotationGestureRecognizer
            || gestureRecognizer is UIPinchGestureRecognizer
            || gestureRecognizer == mapView.gestures.doubleTapToZoomInGestureRecognizer
            || gestureRecognizer == mapView.gestures.doubleTouchToZoomOutGestureRecognizer

        {
            gestureRecognizer.addTarget(self, action: #selector(switchToIdleCamera))
        }
    }

    private func makeTapGestureRecognizerStopAnimatedTransitions() {
        for gestureRecognizer in mapView.gestureRecognizers ?? []
            where gestureRecognizer is UITapGestureRecognizer
            && gestureRecognizer != mapView.gestures.doubleTouchToZoomOutGestureRecognizer
        {
            gestureRecognizer.addTarget(self, action: #selector(switchToIdleCameraIfNotFollowing))
        }
    }

    @objc
    private func switchToIdleCamera() {
        update(navigationCameraState: .idle)
    }

    @objc
    private func switchToIdleCameraIfNotFollowing() {
        guard navigationCamera.currentCameraState != .following else { return }
        update(navigationCameraState: .idle)
    }

    /// Fired when NavigationMapView detects a tap not handled elsewhere by other gesture recognizers.
    @objc
    private func didReceiveTap(gesture: UITapGestureRecognizer) {
        guard gesture.state == .recognized else { return }
        let tapPoint = gesture.location(in: mapView)

        Task {
            if let alternativeRoute = try await alternativeRouteFromMapQuery(at: tapPoint) {
                delegate?.navigationMapView(self, didSelect: alternativeRoute)
                return
            }

            if let allRoutes = routes?.allRoutes() {
                let waypointTest = legSeparatingWaypoints(on: allRoutes, closeTo: tapPoint)
                if let selected = waypointTest?.first {
                    delegate?.navigationMapView(self, didSelect: selected)
                    return
                }
            }

            let point = await mapPoint(at: tapPoint)

            if point.name != nil {
                delegate?.navigationMapView(self, userDidTap: point)
            }
        }
    }

    func legSeparatingWaypoints(on routes: [Route], closeTo point: CGPoint) -> [Waypoint]? {
        // In case if route does not contain more than one leg - do nothing.
        let multipointRoutes = routes.filter { $0.legs.count > 1 }
        guard multipointRoutes.count > 0 else { return nil }

        let waypoints = multipointRoutes.compactMap { route in
            route.legs.dropLast().compactMap { $0.destination }
        }.flatMap { $0 }

        // Sort the array in order of closest to tap.
        let tapCoordinate = mapView.mapboxMap.coordinate(for: point)
        let closest = waypoints.sorted { left, right -> Bool in
            let leftDistance = left.coordinate.projectedDistance(to: tapCoordinate)
            let rightDistance = right.coordinate.projectedDistance(to: tapCoordinate)
            return leftDistance < rightDistance
        }

        // Filter to see which ones are under threshold.
        let candidates = closest.filter {
            let coordinatePoint = mapView.mapboxMap.point(for: $0.coordinate)

            return coordinatePoint.distance(to: point) < tapGestureDistanceThreshold
        }

        return candidates
    }

    private func mapPoint(at point: CGPoint) async -> MapPoint {
        let options = RenderedQueryOptions(layerIds: mapStyleManager.poiLayerIds, filter: nil)
        let rectSize = poiClickableAreaSize
        let rect = CGRect(x: point.x - rectSize / 2, y: point.y - rectSize / 2, width: rectSize, height: rectSize)

        let features = try? await mapView.mapboxMap.queryRenderedFeatures(with: rect, options: options)
        if let feature = features?.first?.queriedFeature.feature,
           case .string(let poiName) = feature[property: .poiName, languageCode: nil],
           case .point(let point) = feature.geometry
        {
            return MapPoint(name: poiName, coordinate: point.coordinates)
        } else {
            let coordinate = mapView.mapboxMap.coordinate(for: point)
            return MapPoint(name: nil, coordinate: coordinate)
        }
    }

    @MainActor
    private func alternativeRouteFromMapQuery(
        at point: CGPoint
    ) async throws -> AlternativeRoute? {
        let map = mapView.mapboxMap!

        let queryOptions = RenderedQueryOptions(layerIds: [
            FeatureIds.RouteAnnotations.default.routeDuration,
            FeatureIds.RouteAnnotations.default.relativeDurationOnAlternative,
            FeatureIds.RouteAnnotations.default.relativeDurationOnAlternativeManuever,
        ], filter: nil)

        let queriedRenderedFeatures = try await map.queryRenderedFeatures(with: point, options: queryOptions)
        for queriedRenderedFeature in queriedRenderedFeatures {
            let queriedFeature = queriedRenderedFeature.queriedFeature
            guard let indexValue = queriedFeature.feature.properties?["routeIndex"] as? JSONValue,
                  case .number(let routeIndex) = indexValue,
                  routeIndex != 0
            else {
                continue
            }

            guard let routes else {
                Log.warning("Unable to access routes", category: .navigation)
                return nil
            }

            guard let alternativeRoute = routes.alternativeRoutes[safe: Int(routeIndex)] else {
                Log.warning("Unable to access an alternative route at index", category: .navigation)
                return nil
            }

            return alternativeRoute
        }

        return continuousAlternativeRoutes(closeTo: point)?.first
    }
}

// MARK: - GestureManagerDelegate

extension NavigationMapView: GestureManagerDelegate {
    public nonisolated func gestureManager(
        _ gestureManager: MapboxMaps.GestureManager,
        didBegin gestureType: MapboxMaps.GestureType
    ) {
        guard gestureType != .singleTap else { return }

        MainActor.assumingIsolated {
            delegate?.navigationMapViewUserDidStartInteraction(self)
        }
    }

    public nonisolated func gestureManager(
        _ gestureManager: MapboxMaps.GestureManager,
        didEnd gestureType: MapboxMaps.GestureType,
        willAnimate: Bool
    ) {
        guard gestureType != .singleTap else { return }

        MainActor.assumingIsolated {
            delegate?.navigationMapViewUserDidEndInteraction(self)
        }
    }

    public nonisolated func gestureManager(
        _ gestureManager: MapboxMaps.GestureManager,
        didEndAnimatingFor gestureType: MapboxMaps.GestureType
    ) {}
}

// MARK: - UIGestureRecognizerDelegate

extension NavigationMapView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer is UITapGestureRecognizer,
           otherGestureRecognizer is UITapGestureRecognizer
        {
            return true
        }

        return false
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer is UITapGestureRecognizer,
           otherGestureRecognizer == mapView.gestures.doubleTapToZoomInGestureRecognizer
        {
            return true
        }
        return false
    }
}
