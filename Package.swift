// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "SystemAudioRecorder",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "sysaudio-rec", targets: ["SystemAudioRecorder"])
    ],
    targets: [
        .executableTarget(
            name: "SystemAudioRecorder",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AudioToolbox")
            ]
        )
    ]
)
