// swift-tools-version:5.9
import PackageDescription

// The side-by-side comparison harness for 0.8.3's vector renderer.
//
// A HOST tool, not a test. The question this build is gated on -- which page
// would Ali rather play from -- is answered by looking at two pictures, and a
// simulator run costs a full app build (Python framework, Firebase, the engine
// snapshot) to produce files that then have to be dug out of an .xcresult.
// This produces PNGs in a directory in about a second, and it can be pointed
// at any page of any score.
//
// The Swift files under Sources/vector-compare are SYMLINKS to the app's own
// sources. Both paths under comparison therefore run the code that ships,
// which is the only version of this that proves anything; a copy would drift
// the first time either path changed.
let package = Package(
    name: "vector-compare",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/swhitty/SwiftDraw", from: "0.18.0")
    ],
    targets: [
        .executableTarget(
            name: "vector-compare",
            dependencies: [.product(name: "SwiftDraw", package: "SwiftDraw")]
        )
    ]
)
