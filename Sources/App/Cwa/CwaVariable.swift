import Foundation

/// Required additions to a GRIB variable to make it downloadable
protocol CwaVariableDownloadable: GenericVariable, Hashable {
    var multiplyAdd: (multiply: Float, add: Float)? { get }
}

enum CwaSurfaceVariable: String, CaseIterable, GenericVariableMixable, CwaVariableDownloadable {
    case temperature_2m
    case relative_humidity_2m
    case surface_pressure
    case pressure_msl
    case precipitation
    case wind_u_component_10m
    case wind_v_component_10m
    case surface_temperature

    var storePreviousForecast: Bool {
        switch self {
        case .temperature_2m, .relative_humidity_2m, .precipitation, .pressure_msl, .surface_pressure,
             .wind_u_component_10m, .wind_v_component_10m:
            return true
        case .surface_temperature:
            return false
        }
    }

    var multiplyAdd: (multiply: Float, add: Float)? {
        switch self {
        case .temperature_2m, .surface_temperature:
            return (1, -273.15)
        case .surface_pressure, .pressure_msl:
            return (1 / 100, 0)
        default:
            return nil
        }
    }

    var omFileName: (file: String, level: Int) {
        return (rawValue, 0)
    }

    var scalefactor: Float {
        switch self {
        case .temperature_2m, .surface_temperature:
            return 20
        case .relative_humidity_2m:
            return 1
        case .surface_pressure, .pressure_msl, .precipitation,
             .wind_u_component_10m, .wind_v_component_10m:
            return 10
        }
    }

    var interpolation: ReaderInterpolation {
        switch self {
        case .temperature_2m, .surface_pressure, .pressure_msl,
             .wind_u_component_10m, .wind_v_component_10m, .surface_temperature:
            return .hermite(bounds: nil)
        case .relative_humidity_2m:
            return .hermite(bounds: 0...100)
        case .precipitation:
            return .backwards_sum
        }
    }

    var unit: SiUnit {
        switch self {
        case .temperature_2m, .surface_temperature:
            return .celsius
        case .relative_humidity_2m:
            return .percentage
        case .surface_pressure, .pressure_msl:
            return .hectopascal
        case .precipitation:
            return .millimetre
        case .wind_u_component_10m, .wind_v_component_10m:
            return .metrePerSecond
        }
    }

    var isElevationCorrectable: Bool {
        switch self {
        case .temperature_2m, .surface_temperature:
            return true
        default:
            return false
        }
    }
}

/**
 Types of pressure level variables
 */
enum CwaPressureVariableType: String, CaseIterable {
    case temperature
    case relative_humidity
    case wind_u_component
    case wind_v_component
    case geopotential_height
    case vertical_velocity
}

/**
 A pressure level variable on a given level in hPa / mb
 */
struct CwaPressureVariable: PressureVariableRespresentable, Hashable, GenericVariableMixable, CwaVariableDownloadable {
    let variable: CwaPressureVariableType
    let level: Int

    var storePreviousForecast: Bool {
        return false
    }

    var multiplyAdd: (multiply: Float, add: Float)? {
        switch variable {
        case .temperature:
            return (1, -273.15)
        default:
            return nil
        }
    }

    var omFileName: (file: String, level: Int) {
        return (rawValue, 0)
    }

    var scalefactor: Float {
        // Upper level data are more dynamic and that is bad for compression. Use lower scalefactors
        switch variable {
        case .temperature:
            // Use scalefactor of 2 for everything higher than 300 hPa
            return (2..<10).interpolated(atFraction: (300..<1000).fraction(of: Float(level)))
        case .wind_u_component, .wind_v_component:
            // Use scalefactor 3 for levels higher than 500 hPa.
            return (3..<10).interpolated(atFraction: (500..<1000).fraction(of: Float(level)))
        case .geopotential_height:
            return (0.05..<1).interpolated(atFraction: (0..<500).fraction(of: Float(level)))
        case .relative_humidity:
            return (0.2..<1).interpolated(atFraction: (0..<800).fraction(of: Float(level)))
        case .vertical_velocity:
            return (20..<100).interpolated(atFraction: (0..<500).fraction(of: Float(level)))
        }
    }

    var interpolation: ReaderInterpolation {
        switch variable {
        case .temperature, .wind_u_component, .wind_v_component, .vertical_velocity:
            return .hermite(bounds: nil)
        case .relative_humidity:
            return .hermite(bounds: 0...100)
        case .geopotential_height:
            return .linear
        }
    }

    var unit: SiUnit {
        switch variable {
        case .temperature:
            return .celsius
        case .wind_u_component, .wind_v_component:
            return .metrePerSecond
        case .geopotential_height:
            return .metre
        case .relative_humidity:
            return .percentage
        case .vertical_velocity:
            return .metrePerSecondNotUnitConverted
        }
    }

    var isElevationCorrectable: Bool {
        return false
    }
}

/**
 Combined surface and pressure level variables with all definitions for downloading and API
 */
typealias CwaVariable = SurfaceAndPressureVariable<CwaSurfaceVariable, CwaPressureVariable>
