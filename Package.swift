// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "bigvoice",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "bigvoice", targets: ["Bigvoice"]),
        .executable(name: "bigvoice-check", targets: ["BigvoiceCheck"]),
        .executable(name: "bigvoice-tests", targets: ["BigvoiceTests"])
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.3/whisper-v1.8.3-xcframework.zip",
            checksum: "a970006f256c8e689bc79e73f7fa7ddb8c1ed2703ad43ee48eb545b5bb6de6af"
        ),
        .target(name: "BigvoiceCore"),
        .target(
            name: "BigvoiceRuntime", dependencies: ["BigvoiceCore", "whisper"],
            // Apple's on-device model ships with macOS 26; weak linking keeps bigvoice launching on macOS 14 and 15.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])]
        ),
        .executableTarget(
            name: "Bigvoice",
            dependencies: ["BigvoiceCore", "BigvoiceRuntime"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .executableTarget(name: "BigvoiceCheck", dependencies: ["BigvoiceCore", "BigvoiceRuntime"]),
        .executableTarget(
            name: "BigvoiceTests", dependencies: ["BigvoiceCore", "BigvoiceRuntime"],
            path: "Tests/BigvoiceTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
