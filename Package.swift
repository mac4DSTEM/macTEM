// swift-tools-version: 6.2
// TEMCore (Sources/TEMCore) and TEMSession (Sources/TEMSession), the SwiftPM
// default layout, so no `path:` is needed. The Xcode app target links these
// two products (packageProductDependencies); their sources live OUTSIDE the
// app's synchronized folder `macTEM/`, so every file compiles exactly once
// with no per-file exception list. `swift build` here is the layering gate
// (`tools/run-tests.sh core`). Swift 6 language mode. TEMCore takes FormatoKit's FormatoDM / FormatoEMD / FormatoHDF5 / FormatoCore for the DM and Velox EMD readers and the
// HDF5 layer (ADR 026; they were SpectroKit's until 0.4.0, ADR 019). TEMCore and TEMSession also take SpectroKit's SpectroCore and SpectroEDX, exact, for the EDX
// room (ADR 028): the spectrum image, line windows and maps, the proposer, the pooled Cliff-Lorimer fit; its resource bundle (the NIST EPQ tables) rides in the app.
// FormatoKit 0.5.0 carries libhdf5 as three framework binaries (FormatoLibHDF5 / SZ / AEC) the app embeds and signs.
// TEMCore takes DiffractoKit's DiffractoCore / DiffractoScattering / DiffractoGeometry for
// crystallography, kinematic lists, ring calibration and indexing (ADR 025): both exact, so a new tag is a deliberate,
// gated bump. Only Diffraction/StandardCrystals.swift imports a DiffractoKit module today; the app links the other two
// so the tests and harnesses reach them as they reach SpectroCore; TEMSession takes them with the Diffraction room.
// TEMCore also takes ImagoKit's ImagoCore / ImagoFFT / ImagoFilters, exact, for the image-analysis maths of the FFT room
// (the 2D FFT, the power spectrum and radial profile, the spot measurement, the masked inverse FFT, the HRTEM filters;
// ADR 027): the room's rules and the app's CalibratedImage stay here, the kit's Micrograph is what its functions read.
import PackageDescription

let package = Package(
    name: "macTEM",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "TEMCore", targets: ["TEMCore"]),
        .library(name: "TEMSession", targets: ["TEMSession"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mac4DSTEM/FormatoKit", exact: "0.11.0"),
        .package(url: "https://github.com/mac4DSTEM/DiffractoKit", exact: "0.10.0"),
        .package(url: "https://github.com/mac4DSTEM/ImagoKit", exact: "0.7.0"),
        .package(url: "https://github.com/mac4DSTEM/SpectroKit", exact: "0.12.0"),
        // The window shell, controls and Metal image view both apps share (suite task 8). TEMCore takes ShellMetal only (MetalEngine, ColormapKind, MTLTexture+Float);
        // TEMSession takes ShellLayout (SystemMonitor).
        .package(url: "https://github.com/mac4DSTEM/MacEMUI", exact: "0.3.0"),
    ],
    targets: [
        .target(
            name: "TEMCore",
            dependencies: [
                .product(name: "Formato", package: "FormatoKit"),
                .product(name: "FormatoCore", package: "FormatoKit"),
                .product(name: "FormatoDM", package: "FormatoKit"),
                .product(name: "FormatoEMD", package: "FormatoKit"),
                .product(name: "FormatoHDF5", package: "FormatoKit"),
                .product(name: "FormatoMRC", package: "FormatoKit"),
                .product(name: "FormatoMSA", package: "FormatoKit"),
                .product(name: "FormatoTIFF", package: "FormatoKit"),
                .product(name: "DiffractoCore", package: "DiffractoKit"),
                .product(name: "DiffractoScattering", package: "DiffractoKit"),
                .product(name: "DiffractoGeometry", package: "DiffractoKit"),
                .product(name: "ImagoCore", package: "ImagoKit"),
                .product(name: "ImagoFFT", package: "ImagoKit"),
                .product(name: "ImagoFilters", package: "ImagoKit"),
                .product(name: "SpectroCore", package: "SpectroKit"),
                .product(name: "SpectroEDX", package: "SpectroKit"),
                .product(name: "SpectroEELS", package: "SpectroKit"),
                .product(name: "ShellMetal", package: "MacEMUI"),
            ],
            swiftSettings: [
                // Optimised in Debug too, as mac4DSTEM (Gate D 2026-09-30).
                .unsafeFlags(["-O"], .when(configuration: .debug)),
                // nonisolated by default: no .defaultIsolation here.
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .target(
            name: "TEMSession",
            dependencies: [
                "TEMCore",
                .product(name: "FormatoCore", package: "FormatoKit"),
                .product(name: "ImagoCore", package: "ImagoKit"),
                .product(name: "ImagoFFT", package: "ImagoKit"),
                .product(name: "ImagoFilters", package: "ImagoKit"),
                .product(name: "SpectroCore", package: "SpectroKit"),
                .product(name: "SpectroEDX", package: "SpectroKit"),
                .product(name: "SpectroEELS", package: "SpectroKit"),
                .product(name: "ShellMetal", package: "MacEMUI"),
                .product(name: "ShellLayout", package: "MacEMUI"),
            ],
            swiftSettings: [
                .unsafeFlags(["-O"], .when(configuration: .debug)),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
