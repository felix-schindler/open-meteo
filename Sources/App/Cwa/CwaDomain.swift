import Foundation

/**
 Taiwan Central Weather Administration (CWA) regional WRF model.

 Data source: https://cwaopendata.s3.ap-northeast-1.amazonaws.com/Model/
 License: Taiwan Open Government Data License 1.0
 */
enum CwaDomain: String, GenericDomain, CaseIterable {
    case wrf3

    var grid: any Gridable {
        switch self {
        case .wrf3:
            /** GRIB Lambert conformal grid metadata:
             Nx = 1158; Ny = 673;
             latitudeOfFirstGridPointInDegrees = 14.0222;
             longitudeOfFirstGridPointInDegrees = 105.25;
             LaDInDegrees = 10; LoVInDegrees = 120;
             Latin1InDegrees = 10; Latin2InDegrees = 40;
             DxInMetres = 3000; DyInMetres = 3000;
             jScansPositively = 1;
             shapeOfTheEarth = 6 (radius 6,371,229 m)
             */
            return ProjectionGrid(
                nx: 1158,
                ny: 673,
                latitude: 14.0222,
                longitude: 105.25,
                dx: 3000,
                dy: 3000,
                projection: LambertConformalConicProjection(λ0: 120, ϕ0: 10, ϕ1: 10, ϕ2: 40, radius: 6371229)
            )
        }
    }

    var domainRegistry: DomainRegistry {
        switch self {
        case .wrf3:
            return .cwa_wrf3
        }
    }

    var domainRegistryStatic: DomainRegistry? {
        return domainRegistry
    }

    var dtSeconds: Int {
        return 6 * 3600
    }

    var masterTimeRange: Range<Timestamp>? {
        return nil
    }

    var omFileLength: Int {
        // 15 steps per run + 3 days extra
        return 15 + 12
    }

    var countEnsembleMember: Int {
        return 1
    }

    var updateIntervalSeconds: Int {
        return 6 * 3600
    }

    var lastRun: Timestamp {
        // Data is complete about 5 hours after initialisation. Runs every 6 hours.
        return Timestamp.now().add(-6 * 3600).floor(toNearest: 6 * 3600)
    }

    /// Forecast hours available in each run: f000 to f084 in 6 hour steps.
    var forecastHours: [Int] {
        return Array(stride(from: 0, through: 84, by: 6))
    }

    func gribUrl(run: Timestamp, forecastHour: Int, server: String = "https://cwaopendata.s3.ap-northeast-1.amazonaws.com/Model/") -> String {
        return "\(server)M-A0064-\(forecastHour.zeroPadded(len: 3)).grb2"
    }
}
