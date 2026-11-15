// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Control24Lab",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Control24Lab", targets: ["Control24Lab"]),
               .executable(name: "Control24Bridge", targets: ["Control24Bridge"])],
    targets: [
        .target(name: "Control24Core"),
        .target(name: "CControl24Capture",publicHeadersPath:"include",linkerSettings:[.linkedLibrary("pcap")]),
        .executableTarget(name:"Control24Bridge",dependencies:["Control24Core","CControl24Capture"]),
        .executableTarget(name: "Control24Lab", dependencies: ["Control24Core"],
                          resources: [.copy("Resources")]),
        .testTarget(name: "Control24CoreTests", dependencies: ["Control24Core"]),
        .testTarget(name: "Control24AppTests", dependencies: ["Control24Lab"])
    ]
)
