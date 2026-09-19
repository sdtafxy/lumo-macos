// swift-tools-version: 5.9
// 语言模式固定为 Swift 5：避免在 Swift 6 编译器下触发严格并发检查，
// 让 @MainActor 的 ObservableObject 与后台任务桥接按既有语义编译。
import PackageDescription

let package = Package(
    name: "Lumo",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Lumo", targets: ["LumoApp"]),
        .executable(name: "lumo-cli", targets: ["lumo-cli"])
    ],
    targets: [
        // 算法核心：只依赖系统框架，零第三方依赖
        .target(name: "LumoCore", path: "Sources/LumoCore"),
        // CI 自检 / 批处理入口
        .executableTarget(name: "lumo-cli", dependencies: ["LumoCore"], path: "Sources/lumo-cli"),
        .executableTarget(
            name: "LumoApp",
            dependencies: ["LumoCore"],
            path: "Sources/LumoApp",
            // 没有 main.swift，入口由 @main 提供；显式声明以兼容各版本 SwiftPM 的推断行为。
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
