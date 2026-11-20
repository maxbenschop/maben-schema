// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MabenSchema",
    platforms: [.macOS(.v14)],
    targets: [
        // The model: entities, relationships, the foreign-key rules, SQL out and in, layout. No UI, no dependencies.
        .target(name: "SchemaCore", path: "Sources/SchemaCore"),
        // The app.
        .executableTarget(name: "Schema", dependencies: ["SchemaCore"], path: "Sources/Schema"),
        .testTarget(name: "SchemaCoreTests", dependencies: ["SchemaCore"], path: "Tests/SchemaCoreTests"),
    ]
)
