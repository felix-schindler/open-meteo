import Foundation
import OmFileFormat
import Vapor
@preconcurrency import SwiftEccodes
import OmFileIO

/**
 Downloader for Taiwan Central Weather Administration (CWA) models.

 Data is read from the public CWA open data S3 bucket. Each forecast hour is a
 single GRIB2 file containing surface and pressure level fields. Precipitation
 is accumulated from the start of the run and deaccumulated across files.
 */
struct DownloadCwaCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "domain")
        var domain: String

        @Option(name: "run")
        var run: String?

        @Option(name: "server", help: "Root URL to the CWA GRIB files")
        var server: String?

        @Option(name: "upload-s3-bucket", help: "Upload open-meteo database to an S3 bucket after processing")
        var uploadS3Bucket: String?

        @Flag(name: "create-netcdf")
        var createNetcdf: Bool

        @Option(name: "concurrent", short: "c", help: "Number of concurrent download/conversion jobs")
        var concurrent: Int?

        @Option(name: "max-forecast-hour", help: "Only download data until this forecast hour")
        var maxForecastHour: Int?

        @Flag(name: "skip-timeseries")
        var skipTimeseries: Bool
    }

    var help: String {
        "Download a specified CWA model run"
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let uploadQueues = await context.application.s3SyncManager.getQueues(bucketsOpt: signature.uploadS3Bucket)
        disableIdleSleep()

        let domain = try CwaDomain.load(rawValue: signature.domain)
        let run = try signature.run.flatMap(Timestamp.fromRunHourOrYYYYMMDD) ?? domain.lastRun
        let logger = context.application.logger
        let concurrent = signature.concurrent ?? 4
        let server = signature.server ?? "https://cwaopendata.s3.ap-northeast-1.amazonaws.com/Model/"

        logger.info("Downloading domain \(domain) run '\(run.iso8601_YYYY_MM_dd_HH_mm)'")

        let handles = try await download(
            application: context.application,
            domain: domain,
            run: run,
            concurrent: concurrent,
            maxForecastHour: signature.maxForecastHour,
            server: server,
            uploadQueues: uploadQueues
        )
        try await GenericVariableHandle.convert(
            application: context.application,
            domain: domain,
            createNetcdf: signature.createNetcdf,
            run: run,
            handles: handles,
            concurrent: concurrent,
            writeUpdateJson: true,
            uploadQueues: uploadQueues,
            generateTimeSeries: !signature.skipTimeseries
        )
    }

    func getCwaVariable(logger: Logger, message: GribMessage) -> (any CwaVariableDownloadable)? {
        guard let shortName = message.get(attribute: "shortName"),
              let typeOfLevel = message.get(attribute: "typeOfLevel") else {
            return nil
        }

        switch typeOfLevel {
        case "isobaricInhPa":
            guard let level = message.get(attribute: "level").flatMap(Int.init) else {
                return nil
            }
            switch shortName {
            case "t": return CwaPressureVariable(variable: .temperature, level: level)
            case "r": return CwaPressureVariable(variable: .relative_humidity, level: level)
            case "u": return CwaPressureVariable(variable: .wind_u_component, level: level)
            case "v": return CwaPressureVariable(variable: .wind_v_component, level: level)
            case "gh": return CwaPressureVariable(variable: .geopotential_height, level: level)
            case "wz": return CwaPressureVariable(variable: .vertical_velocity, level: level)
            default: break
            }
        case "surface":
            switch shortName {
            case "sp": return CwaSurfaceVariable.surface_pressure
            case "skt": return CwaSurfaceVariable.surface_temperature
            default: break
            }
            // The precipitation field has no short name
            if message.get(attribute: "parameterName") == "Total precipitation" {
                return CwaSurfaceVariable.precipitation
            }
        case "meanSea":
            if shortName == "prmsl" {
                return CwaSurfaceVariable.pressure_msl
            }
        case "heightAboveGround":
            guard let level = message.get(attribute: "level").flatMap(Int.init) else {
                return nil
            }
            switch (shortName, level) {
            case ("2t", 2): return CwaSurfaceVariable.temperature_2m
            case ("2r", 2): return CwaSurfaceVariable.relative_humidity_2m
            case ("10u", 10): return CwaSurfaceVariable.wind_u_component_10m
            case ("10v", 10): return CwaSurfaceVariable.wind_v_component_10m
            default: break
            }
        default:
            break
        }

        logger.debug("Unmapped GRIB message \(shortName) \(typeOfLevel) \(message.get(attribute: "level") ?? "-")")
        return nil
    }

    /// Derive elevation from surface and sea level pressure in the analysis step
    func writeElevation(application: Application, domain: CwaDomain, collector: CwaFileCollector, uploadQueues: [S3UploadQueue], createNetCdf: Bool) async throws {
        guard let input = await collector.elevationInput() else {
            throw CwaDownloadError(description: "Could not derive elevation from CWA f000")
        }
        let elevation = Meteorology.elevation(
            sealevelPressure: input.seaLevelPressure,
            surfacePressure: input.surfacePressure,
            temperature_2m: input.temperature2m
        )
        try domain.surfaceElevationFileOm.createDirectory()
        try await elevation.writeStaticOmFile(file: domain.surfaceElevationFileOm, grid: domain.grid, application: application, uploadQueues: uploadQueues, createNetCdf: createNetCdf)
    }

    func download(application: Application, domain: CwaDomain, run: Timestamp, concurrent: Int, maxForecastHour: Int?, server: String, uploadQueues: [S3UploadQueue]) async throws -> [GenericVariableHandle] {
        let logger = application.logger
        let deadLineHours: Double = 6
        let curl = Curl(logger: logger, client: application.dedicatedHttpClient, deadLineHours: deadLineHours)
        Process.alarm(seconds: Int(deadLineHours + 1) * 3600)
        defer { Process.alarm(seconds: 0) }

        let forecastHours = domain.forecastHours.filter { $0 <= (maxForecastHour ?? Int.max) }
        let timestamps = forecastHours.map { run.add(hours: $0) }
        let elevationExists = FileManager.default.fileExists(atPath: domain.surfaceElevationFileOm.getFilePath())
        var deaverager = GribDeaverager()
        var handles = [GenericVariableHandle]()

        for (i, forecastHour) in forecastHours.enumerated() {
            let timestamp = timestamps[i]
            let url = domain.gribUrl(run: run, forecastHour: forecastHour, server: server)
            let collector = CwaFileCollector()
            let result = try await curl.withGribStream(url: url, bzip2Decode: false, nConcurrent: concurrent, deadLineHours: deadLineHours) { stream -> [GenericVariableHandle]? in
                let deaveragerScoped = await deaverager.copy()
                let writer = OmSpatialTimestepWriter(domain: domain, run: run, time: timestamp, storeOnDisk: true, realm: nil, logger: logger)
                try await stream.foreachConcurrent(nConcurrent: concurrent) { message in
                    guard let dataDate = message.get(attribute: "dataDate"),
                          let dataTime = message.get(attribute: "dataTime").flatMap(Int.init) else {
                        return
                    }
                    // CWA only keeps the latest run. Never mix a stale file into the requested run.
                    guard dataDate == run.format_YYYYMMdd, dataTime == run.hour * 100 else {
                        await collector.markMismatch()
                        return
                    }
                    await collector.markMatch()

                    guard let stepRange = message.get(attribute: "stepRange"),
                          let stepType = message.get(attribute: "stepType"),
                          let variable = getCwaVariable(logger: logger, message: message) else {
                        return
                    }

                    var grib2d = GribArray2D(nx: domain.grid.nx, ny: domain.grid.ny)
                    try grib2d.load(message: message)

                    // Scaling before compression with scalefactor
                    if let fma = variable.multiplyAdd {
                        grib2d.array.data.multiplyAdd(multiply: fma.multiply, add: fma.add)
                    }

                    // Precipitation accumulates from the start of the run
                    guard await deaveragerScoped.deaccumulateIfRequired(variable: variable, member: 0, stepType: stepType, stepRange: stepRange, grib2d: &grib2d) else {
                        return
                    }

                    if forecastHour == 0, !elevationExists, let surface = variable as? CwaSurfaceVariable {
                        await collector.capture(surface, data: grib2d.array.data)
                    }

                    logger.info("Compressing and writing data to \(variable.omFileName.file)_\(forecastHour).om")
                    try await writer.write(member: 0, variable: variable, data: grib2d.array.data)
                }
                guard await collector.isValid else {
                    return nil
                }
                deaverager = deaveragerScoped
                let completed = i == forecastHours.count - 1
                return try await writer.finalise(application: application, completed: completed, validTimes: Array(timestamps[0...i]), uploadQueues: uploadQueues)
            }
            guard let result else {
                throw CwaDownloadError(description: "CWA file \(url) does not match run \(run.iso8601_YYYY_MM_dd_HH_mm)")
            }
            handles.append(contentsOf: result)

            if forecastHour == 0, !elevationExists {
                try await writeElevation(application: application, domain: domain, collector: collector, uploadQueues: uploadQueues, createNetCdf: false)
            }
        }
        await curl.printStatistics()
        return handles
    }
}

/// Collects run validation state and the fields required for the elevation file
actor CwaFileCollector {
    private var matched = false
    private var mismatched = false
    private var surfacePressure: [Float]?
    private var seaLevelPressure: [Float]?
    private var temperature2m: [Float]?

    var isValid: Bool {
        return matched && !mismatched
    }

    func markMatch() {
        matched = true
    }

    func markMismatch() {
        mismatched = true
    }

    func capture(_ variable: CwaSurfaceVariable, data: [Float]) {
        switch variable {
        case .surface_pressure: surfacePressure = data
        case .pressure_msl: seaLevelPressure = data
        case .temperature_2m: temperature2m = data
        default: break
        }
    }

    func elevationInput() -> (surfacePressure: [Float], seaLevelPressure: [Float], temperature2m: [Float])? {
        guard let surfacePressure, let seaLevelPressure, let temperature2m else {
            return nil
        }
        return (surfacePressure, seaLevelPressure, temperature2m)
    }
}

struct CwaDownloadError: Error, CustomStringConvertible {
    let description: String
}
