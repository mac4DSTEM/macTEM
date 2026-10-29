// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-only
// TEMCore and TEMSession, the app's two library targets (`tools/run-tests.sh core` builds them standalone: the layering
// gate). Kits at exact tags. No UI below the app: TEMCore takes only ShellEDXModel from MacEMUI (the shared EDS room's model, no SwiftUI).
import PackageDescription

let package = Package(
    name: "macTEM",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TEMCore", targets: ["TEMCore"]),
        .library(name: "TEMSession", targets: ["TEMSession"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mac4DSTEM/FormatoKit", exact: "0.11.0"),
        .package(url: "https://github.com/mac4DSTEM/DiffractoKit", exact: "0.10.0"),
        .package(url: "https://github.com/mac4DSTEM/ImagoKit", exact: "0.8.0"),
        .package(url: "https://github.com/mac4DSTEM/SpectroKit", exact: "0.12.0"),
        // The window shell, controls and Metal image view both apps share. TEMSession takes ShellMetal (MetalEngine, ColormapKind); TEMCore and
        // TEMSession take ShellEDXModel (the shared EDS room; the EELS room reuses its regions and pins).
        .package(url: "https://github.com/mac4DSTEM/MacEMUI", exact: "0.4.0"),
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
                .product(name: "ShellEDXModel", package: "MacEMUI"),
            ],
            swiftSettings: [
                // Optimised in Debug too.
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
                .product(name: "ShellEDXModel", package: "MacEMUI"),
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
