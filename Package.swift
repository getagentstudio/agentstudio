// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "AgentStudio",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "AgentStudio", targets: ["AgentStudio"]),
        .executable(
            name: "agentstudio-bridge-dev-server",
            targets: ["AgentStudioBridgeDevelopmentServer"]
        ),
        .executable(name: "agentstudio-cli", targets: ["AgentStudioIPCClient"]),
        .executable(
            name: "agentstudio-sqlite-crash-fixture",
            targets: ["AgentStudioSQLiteCrashFixture"]
        ),
        .executable(
            name: "agentstudio-cli-store-process-fixture",
            targets: ["AgentStudioCLIStoreProcessFixture"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.12.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.10.0"),
        .package(url: "https://github.com/swift-otel/swift-otel.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.10.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(
            url: "https://github.com/getagentstudio/agentstudio-git.git",
            revision: "87193257e55e7516e43bb1e8338b929c586355ae"
        ),
    ],
    targets: [
        .executableTarget(
            name: "AgentStudio",
            dependencies: [
                "AgentStudioAppIPC",
                "AgentStudioCLIStore",
                "AgentStudioBridge",
                "AgentStudioCodeViewer",
                "AgentStudioCommandBar",
                "AgentStudioCore",
                "AgentStudioWorktreeOperations",
                "AgentStudioEditorChooser",
                "AgentStudioInboxNotification",
                "AgentStudioInfrastructure",
                "AgentStudioRepoExplorer",
                "AgentStudioSessions",
                "AgentStudioSharedComponents",
                "AgentStudioTerminal",
                "AgentStudioWebview",
                "GhosttyKit",
                "AgentStudioIPCTransport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/AgentStudio",
            exclude: [
                "Core",
                "Features",
                "Infrastructure",
                // Copied into Contents/Resources/AgentPackage by the bundle
                // assembly, not into the SwiftPM resource bundle.
                "Resources/AgentPackage",
                "Resources/Info.plist",
                "Resources/AppIcon.svg",
                "Resources/terminfo-src",
                "Resources/AgentStudio.entitlements",
                "SharedComponents",
            ],
            resources: [
                .process("Resources/Icons.xcassets"),
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/AppLogoTransparent.svg"),
                .copy("Resources/AppIcon.iconset"),
                .copy("Resources/terminfo"),
                .copy("Resources/ghostty"),
                .copy("Resources/BridgeWeb"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreServices"),
                .linkedFramework("WebKit"),
                .linkedFramework("AuthenticationServices"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),
        // Pure, Foundation-only value types and functions shared by the app and
        // the `agentstudio-cli` executable. No package dependencies, nothing
        // internal: this is what lets the CLI stay a leaf-only binary.
        .target(
            name: "AgentStudioPrimitives",
            path: "Sources/AgentStudioPrimitives",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AgentStudioWorktreeOperations",
            dependencies: [
                "AgentStudioPrimitives",
                .product(name: "AgentStudioGit", package: "agentstudio-git"),
            ],
            path: "Sources/AgentStudioWorktreeOperations",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AgentStudioInfrastructure",
            dependencies: [
                "AgentStudioPrimitives",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "OTel", package: "swift-otel"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "AgentStudioGit", package: "agentstudio-git"),
            ],
            path: "Sources/AgentStudio/Infrastructure",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AgentStudioSharedComponents",
            dependencies: [
                "AgentStudioInfrastructure"
            ],
            path: "Sources/AgentStudio/SharedComponents",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AgentStudioCore",
            dependencies: [
                "AgentStudioInfrastructure",
                "AgentStudioSharedComponents",
                "AgentStudioWorktreeOperations",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "AgentStudioGit", package: "agentstudio-git"),
            ],
            path: "Sources/AgentStudio/Core",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AgentStudioBridge",
            dependencies: [
                "AgentStudioCore",
                "AgentStudioInfrastructure",
                "AgentStudioProgrammaticControl",
                "AgentStudioSharedComponents",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "AgentStudioGit", package: "agentstudio-git"),
            ],
            path: "Sources/AgentStudio/Features/Bridge",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AgentStudioCodeViewer",
            dependencies: [
                "AgentStudioCore",
                "AgentStudioInfrastructure",
                "AgentStudioSharedComponents",
            ],
            path: "Sources/AgentStudio/Features/CodeViewer",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AgentStudioCommandBar",
            dependencies: [
                "AgentStudioCore",
                "AgentStudioInfrastructure",
                "AgentStudioSharedComponents",
                "AgentStudioWorktreeOperations",
            ],
            path: "Sources/AgentStudio/Features/CommandBar",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AgentStudioEditorChooser",
            dependencies: [
                "AgentStudioCore",
                "AgentStudioInfrastructure",
                "AgentStudioSharedComponents",
            ],
            path: "Sources/AgentStudio/Features/EditorChooser",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AgentStudioInboxNotification",
            dependencies: [
                "AgentStudioCore",
                "AgentStudioInfrastructure",
                "AgentStudioSharedComponents",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/AgentStudio/Features/InboxNotification",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AgentStudioRepoExplorer",
            dependencies: [
                "AgentStudioCore",
                "AgentStudioInfrastructure",
                "AgentStudioSharedComponents",
            ],
            path: "Sources/AgentStudio/Features/RepoExplorer",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AgentStudioTerminal",
            dependencies: [
                "AgentStudioCore",
                "AgentStudioInfrastructure",
                "AgentStudioSharedComponents",
                "GhosttyKit",
            ],
            path: "Sources/AgentStudio/Features/Terminal",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AgentStudioWebview",
            dependencies: [
                "AgentStudioCore",
                "AgentStudioInfrastructure",
                "AgentStudioSharedComponents",
            ],
            path: "Sources/AgentStudio/Features/Webview",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AgentStudioSessions",
            dependencies: [
                "AgentStudioCore",
                "AgentStudioInfrastructure",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/AgentStudio/Features/Sessions",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AgentStudioIPCTransport",
            path: "Sources/AgentStudioIPCTransport",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AgentStudioProgrammaticControl",
            path: "Sources/AgentStudioProgrammaticControl",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AgentStudioAppIPC",
            dependencies: [
                "AgentStudioIPCTransport",
                "AgentStudioProgrammaticControl",
                "AgentStudioInfrastructure",
            ],
            path: "Sources/AgentStudioAppIPC",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AgentStudioCLIStore",
            dependencies: [
                "AgentStudioPrimitives",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/AgentStudioCLIStore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AgentStudioIPCClientCore",
            dependencies: [
                "AgentStudioCLIStore",
                "AgentStudioIPCTransport",
                "AgentStudioPrimitives",
                "AgentStudioProgrammaticControl",
            ],
            path: "Sources/AgentStudioIPCClientCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "AgentStudioBridgeDevelopmentServer",
            dependencies: [
                "AgentStudioBridge",
                "AgentStudioCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/AgentStudioBridgeDevelopmentServer",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "AgentStudioIPCClient",
            dependencies: [
                "AgentStudioIPCClientCore",
                "AgentStudioPrimitives",
                "AgentStudioProgrammaticControl",
                "AgentStudioWorktreeOperations",
            ],
            path: "Sources/AgentStudioIPCClient",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "AgentStudioSQLiteCrashFixture",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Tests/AgentStudioSQLiteCrashFixture",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AgentStudioTestSupport",
            dependencies: [
                "AgentStudioCore",
                "AgentStudioTestHarness",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/AgentStudioTests/TestSupport",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "AgentStudioCLIStoreProcessFixture",
            dependencies: ["AgentStudioCLIStore", "AgentStudioPrimitives"],
            path: "Tests/AgentStudioCLIStoreProcessFixture",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AgentStudioCLIStoreTests",
            dependencies: [
                "AgentStudioCLIStore",
                "AgentStudioCLIStoreProcessFixture",
                "AgentStudioPrimitives",
                "AgentStudioTestHarness",
                "AgentStudioTestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/AgentStudioCLIStoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AgentStudioTestHarness",
            path: "Tests/AgentStudioTestHarness",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentStudioTestHarnessTests",
            dependencies: [
                "AgentStudioTestHarness"
            ],
            path: "Tests/AgentStudioTestHarnessTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentStudioBridgeDevelopmentServerTests",
            dependencies: [
                "AgentStudioBridgeDevelopmentServer",
                "AgentStudioCore",
                "AgentStudioTestSupport",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            path: "Tests/AgentStudioBridgeDevelopmentServerTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentStudioInfrastructureTests",
            dependencies: [
                "AgentStudioInfrastructure",
                "AgentStudioTestHarness",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "AgentStudioGit", package: "agentstudio-git"),
            ],
            path: "Tests/AgentStudioTests/Infrastructure",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentStudioSharedComponentsTests",
            dependencies: [
                "AgentStudioInfrastructure",
                "AgentStudioSharedComponents",
            ],
            path: "Tests/AgentStudioTests/SharedComponents",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentStudioCoreTests",
            dependencies: [
                "AgentStudioCore",
                "AgentStudioInfrastructure",
                "AgentStudioSharedComponents",
                "AgentStudioTestHarness",
                "AgentStudioTestSupport",
                "AgentStudioWorktreeOperations",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "AgentStudioGit", package: "agentstudio-git"),
            ],
            path: "Tests/AgentStudioTests/Core",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentStudioBridgeTests",
            dependencies: [
                "AgentStudioBridge",
                "AgentStudioCore",
                "AgentStudioInfrastructure",
                "AgentStudioProgrammaticControl",
                "AgentStudioSharedComponents",
                "AgentStudioTestHarness",
                "AgentStudioTestSupport",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "AgentStudioGit", package: "agentstudio-git"),
            ],
            path: "Tests/AgentStudioTests/Features/Bridge",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentStudioCodeViewerTests",
            dependencies: [
                "AgentStudioCodeViewer",
                "AgentStudioCore",
                "AgentStudioInfrastructure",
                "AgentStudioSharedComponents",
                "AgentStudioTestSupport",
            ],
            path: "Tests/AgentStudioTests/Features/CodeViewer",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentStudioCommandBarTests",
            dependencies: [
                "AgentStudioCommandBar",
                "AgentStudioCore",
                "AgentStudioInfrastructure",
                "AgentStudioSharedComponents",
                "AgentStudioTestSupport",
                "AgentStudioWorktreeOperations",
            ],
            path: "Tests/AgentStudioTests/Features/CommandBar",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentStudioEditorChooserTests",
            dependencies: [
                "AgentStudioCore",
                "AgentStudioEditorChooser",
                "AgentStudioInfrastructure",
                "AgentStudioSharedComponents",
                "AgentStudioTestSupport",
            ],
            path: "Tests/AgentStudioTests/Features/EditorChooser",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentStudioInboxNotificationTests",
            dependencies: [
                "AgentStudioCore",
                "AgentStudioInboxNotification",
                "AgentStudioInfrastructure",
                "AgentStudioSharedComponents",
                "AgentStudioTestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/AgentStudioTests/Features/InboxNotification",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentStudioRepoExplorerTests",
            dependencies: [
                "AgentStudioCore",
                "AgentStudioInfrastructure",
                "AgentStudioRepoExplorer",
                "AgentStudioSharedComponents",
                "AgentStudioTestSupport",
            ],
            path: "Tests/AgentStudioTests/Features/RepoExplorer",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentStudioTerminalTests",
            dependencies: [
                "AgentStudioTestHarness",
                "AgentStudioCore",
                "AgentStudioInfrastructure",
                "AgentStudioSharedComponents",
                "AgentStudioTerminal",
                "AgentStudioTestSupport",
                "GhosttyKit",
            ],
            path: "Tests/AgentStudioTests/Features/Terminal",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentStudioWebviewTests",
            dependencies: [
                "AgentStudioCore",
                "AgentStudioInfrastructure",
                "AgentStudioSharedComponents",
                "AgentStudioTestSupport",
                "AgentStudioWebview",
            ],
            path: "Tests/AgentStudioTests/Features/Webview",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentStudioIPCTransportTests",
            dependencies: [
                "AgentStudioIPCTransport",
                "AgentStudioTestHarness",
            ],
            path: "Tests/AgentStudioIPCTransportTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentStudioProgrammaticControlTests",
            dependencies: [
                "AgentStudioPrimitives",
                "AgentStudioProgrammaticControl",
            ],
            path: "Tests/AgentStudioProgrammaticControlTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentStudioAppIPCTests",
            dependencies: [
                "AgentStudio",
                "AgentStudioAppIPC",
                "AgentStudioCLIStore",
                "AgentStudioCore",
                "AgentStudioIPCClientCore",
                "AgentStudioIPCTransport",
                "AgentStudioProgrammaticControl",
                "AgentStudioInfrastructure",
                "AgentStudioTestHarness",
                "AgentStudioTestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/AgentStudioAppIPCTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentStudioSessionsTests",
            dependencies: [
                "AgentStudioSessions",
                "AgentStudioCore",
                "AgentStudioInfrastructure",
                "AgentStudioTestHarness",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/AgentStudioTests/Features/Sessions",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AgentStudioIPCClientTests",
            dependencies: [
                "AgentStudioIPCClientCore",
                "AgentStudioCLIStore",
                "AgentStudioIPCTransport",
                "AgentStudioPrimitives",
                "AgentStudioProgrammaticControl",
                "AgentStudioTestHarness",
            ],
            path: "Tests/AgentStudioIPCClientTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentStudioTests",
            dependencies: [
                "AgentStudio",
                "AgentStudioAppIPC",
                "AgentStudioCLIStore",
                "AgentStudioBridge",
                "AgentStudioCodeViewer",
                "AgentStudioCommandBar",
                "AgentStudioCore",
                "AgentStudioWorktreeOperations",
                "AgentStudioEditorChooser",
                "AgentStudioIPCClientCore",
                "AgentStudioIPCTransport",
                "AgentStudioInboxNotification",
                "AgentStudioInfrastructure",
                "AgentStudioProgrammaticControl",
                "AgentStudioRepoExplorer",
                "AgentStudioSessions",
                "AgentStudioSharedComponents",
                "AgentStudioTerminal",
                "AgentStudioTestHarness",
                "AgentStudioTestSupport",
                "AgentStudioWebview",
                "GhosttyKit",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "InMemoryTracing", package: "swift-distributed-tracing"),
                .product(name: "Instrumentation", package: "swift-distributed-tracing"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "AgentStudioGit", package: "agentstudio-git"),
            ],
            path: "Tests/AgentStudioTests",
            exclude: [
                "Fixtures/AtomLibCompileFailures",
                "Fixtures/SwiftLintLegacyCustomRules",
            ],
            sources: [
                "App",
                "Architecture",
                "Helpers",
                "Integration",
                "Scripts",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),
    ]
)

// A discarded completion handle or any other compiler warning in a repository-owned
// target fails the build. Remote dependencies are unaffected: the setting is per target.
for target in package.targets where target.type != .binary {
    target.swiftSettings = (target.swiftSettings ?? []) + [.treatAllWarnings(as: .error)]
}
