import Foundation
import Testing
import OpenMeteoSdk
@testable import App

@Suite struct CwaTests {
    @Test func gridMatchesGribGeometry() {
        let grid = CwaDomain.wrf3.grid
        #expect(grid.nx == 1158 && grid.ny == 673)

        let first = grid.getCoordinates(gridpoint: 0)
        #expect(abs(first.latitude - 14.0222) < 0.001)
        #expect(abs(first.longitude - 105.25) < 0.001)

        let last = grid.getCoordinates(gridpoint: grid.nx * grid.ny - 1)
        #expect(abs(last.latitude - 32.118) < 0.01)
        #expect(abs(last.longitude - 140.906) < 0.01)

        #expect(grid.findPoint(lat: first.latitude, lon: first.longitude) == 0)
        #expect(grid.findPoint(lat: last.latitude, lon: last.longitude) == grid.nx * grid.ny - 1)
    }

    @Test func domainScheduleAndUrls() {
        let domain = CwaDomain.wrf3
        #expect(domain.domainRegistry == .cwa_wrf3)
        #expect(domain.domainRegistryStatic == .cwa_wrf3)
        #expect(domain.dtSeconds == 6 * 3600)
        #expect(domain.updateIntervalSeconds == 6 * 3600)
        #expect(domain.countEnsembleMember == 1)
        #expect(domain.forecastHours == Array(stride(from: 0, through: 84, by: 6)))
        #expect(domain.gribUrl(run: Timestamp(2026, 11, 9, 6), forecastHour: 6)
            == "https://cwaopendata.s3.ap-northeast-1.amazonaws.com/Model/M-A0064-006.grb2")
    }

    @Test func variableConversionsAndUnits() {
        let conversions: [(any CwaVariableDownloadable, Float, Float)] = [
            (CwaSurfaceVariable.temperature_2m, 273.15, 0),
            (CwaSurfaceVariable.surface_temperature, 288.15, 15),
            (CwaSurfaceVariable.surface_pressure, 101325, 1013.25),
            (CwaSurfaceVariable.pressure_msl, 101325, 1013.25),
            (CwaPressureVariable(variable: .temperature, level: 500), 263.15, -10)
        ]
        for (variable, raw, expected) in conversions {
            var values = [raw]
            if let fma = variable.multiplyAdd {
                values.multiplyAdd(multiply: fma.multiply, add: fma.add)
            }
            #expect(abs(values[0] - expected) < 0.001)
        }
        #expect(CwaSurfaceVariable.relative_humidity_2m.unit == .percentage)
        #expect(CwaSurfaceVariable.precipitation.unit == .millimetre)
        #expect(CwaSurfaceVariable.wind_u_component_10m.unit == .metrePerSecond)
        #expect(CwaPressureVariable(variable: .geopotential_height, level: 500).unit == .metre)
        #expect(CwaPressureVariable(variable: .vertical_velocity, level: 500).unit == .metrePerSecondNotUnitConverted)
        #expect(CwaSurfaceVariable.temperature_2m.isElevationCorrectable)
        #expect(!CwaPressureVariable(variable: .temperature, level: 500).isElevationCorrectable)
    }

    @Test func variablesAreExposedByTheApi() throws {
        // Raw 10m wind components are stored as inputs for derived wind speed/direction and are
        // deliberately not part of the public hourly API.
        let storedWindComponents: Set<String> = ["wind_u_component_10m", "wind_v_component_10m"]
        for variable in CwaSurfaceVariable.allCases where !storedWindComponents.contains(variable.rawValue) {
            #expect(ForecastVariable(rawValue: variable.rawValue) != nil, "Cannot parse \(variable.rawValue)")
        }
        for type in CwaPressureVariableType.allCases {
            let variable = CwaPressureVariable(variable: type, level: 500)
            #expect(ForecastVariable(rawValue: variable.rawValue) != nil, "Cannot parse \(variable.rawValue)")
        }
        for name in ["wind_speed_500hPa", "wind_direction_500hPa", "dew_point_2m", "surface_pressure"] {
            #expect(ForecastVariable(rawValue: name) != nil, "Missing derived variable \(name)")
        }
    }

    @Test func modelMapping() async throws {
        let model = try #require(MultiDomains(rawValue: "cwa_wrf3"))
        let mapping = try #require(try await model.getDomainAndVariable())
        #expect(mapping.primary.count == 1)
        #expect(mapping.secondary.isEmpty)
        guard case .domain(let domain, let variable) = try #require(mapping.primary.first) else {
            Issue.record("Expected a CWA domain source")
            return
        }
        #expect(domain.domainRegistry == .cwa_wrf3)
        #expect(ObjectIdentifier(variable) == ObjectIdentifier(CwaVariable.self))
        #expect(mapping.gridForBoundingBoxRequests?.domainRegistry == .cwa_wrf3)
        #expect(try await model.genericDomain()?.domainRegistry == .cwa_wrf3)
        #expect(model.flatBufferModel == .undefined)
    }

    @Test func precipitationDeaccumulation() async throws {
        let deaverager = GribDeaverager()
        let steps: [(stepRange: String, value: Float, keep: Bool, expected: Float)] = [
            ("0", 0.5, false, 0),
            ("0-6", 3.5, true, 3.5),
            ("0-12", 5.0, true, 1.5),
            ("0-18", 5.0, true, 0)
        ]
        for (stepRange, value, keep, expected) in steps {
            var array = Array2D(data: [value], nx: 1, ny: 1)
            let keepStep = await deaverager.deaccumulateIfRequired(
                variable: CwaSurfaceVariable.precipitation,
                member: 0,
                stepType: "accum",
                stepRange: stepRange,
                array2d: &array
            )
            #expect(keepStep == keep)
            if keep {
                #expect(abs(array.data[0] - expected) < 0.0001)
            }
        }
    }
}
