// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
//
// Vauta — your meetings, locked in your Mac. One dependency: MLX (a pinned fork of mlx-swift, MIT) for the
// optional on-device search model; everything else is Apple frameworks and the system SQLite.
import PackageDescription

let package = Package(
    name: "Vauta",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Vauta", targets: ["Vauta"]),
    ],
    dependencies: [
        // MaquinaTech/mlx-swift = ml-explore/mlx-swift 0.32.3 (19601207...) + runtime kernel compilation patch v2
        // (no metallib, 167-name kernel table; builds with the Command Line Tools only). Pinned by revision;
        // bumps follow docs/SEARCH_MODEL.md.
        .package(url: "https://github.com/MaquinaTech/mlx-swift.git", revision: "999f159e905affa3cc25bc1127a6cb489a5ffbb9"),
    ],
    targets: [
        // The only target that may import MLX (a source-scan test enforces it): the GPU kernels and the text encoder.
        .target(
            name: "VautaMLX",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
            ]
        ),
        .target(
            name: "VautaCore",
            dependencies: ["VautaMLX"],
            resources: [
                // Compiled Core ML models for speaker separation (tools/convert-diarization-models); verified by SHA-256 before use.
                .copy("Resources/Models"),
            ],
            linkerSettings: [
                .linkedFramework("CoreML"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("Accelerate"),
                .linkedFramework("FoundationModels"),
                .linkedFramework("NaturalLanguage"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "VautaCoreTests",
            dependencies: ["VautaCore", "VautaMLX"],
            exclude: ["Fixtures"]
        ),
        // The pieces of the app target that have logic worth a test (view models, the notepad and Answers panels, the PDF export).
        .testTarget(
            name: "VautaAppTests",
            dependencies: ["Vauta", "VautaCore"]
        ),
        .executableTarget(
            name: "Vauta",
            dependencies: ["VautaCore"],
            linkerSettings: [
                .linkedFramework("EventKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("LocalAuthentication"),
            ]
        ),
    ]
)
