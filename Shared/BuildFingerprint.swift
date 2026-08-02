import Foundation

/// 客户端 build 指纹（ESS-56）。
///
/// 为什么需要：R3 真机验收实测的不是 R3 build——手表上跑的是 14:36 冷启动的旧
/// 进程，而待验收 commit 15:30 才合入，ESS-45/47/48 的表端代码一次都没运行过，
/// 一整轮人工验收白做。当时无法察觉，是因为 `MARKETING_VERSION` 固定 `0.1.0`、
/// `CURRENT_PROJECT_VERSION` 固定 `1`，每个 build 的版本号完全一样，
/// `cold_start` 报的 `version=0.1.0` 对"新装还是旧装"零信息量。
///
/// 因此指纹的时间来源不取版本号，也不取构建期注入的 git sha，而取
/// **可执行文件自身的文件时间戳**：它由构建产物决定，不依赖任何 build script
/// phase、环境变量或"记得先跑 xcodegen"。人工在 Xcode 里直接 Run —— 也就是
/// R3 出事的那条路径 —— 同样覆盖得到。
///
/// 判定留在 Bridge 侧（`MacRemoteFrontendBridge/watch-build.mjs`）：本类型只负责
/// 如实上报，不做通过/不通过的判断。
struct BuildFingerprint: Equatable {
    /// 字段读不到时的占位；Bridge 侧据此判为"证据不足"，按不通过处理。
    static let unknown = "unknown"

    let shortVersion: String
    let build: String
    /// 可执行文件的文件时间戳；读不到时为 nil（detail 中写 `unknown`）。
    let builtAt: Date?

    init(shortVersion: String?, build: String?, builtAt: Date?) {
        self.shortVersion = Self.normalize(shortVersion)
        self.build = Self.normalize(build)
        self.builtAt = builtAt
    }

    var builtAtText: String {
        builtAt.map(Self.formatter.string(from:)) ?? Self.unknown
    }

    /// `cold_start` 的 detail 载荷：空格分隔的 `k=v`，Bridge 侧按同一格式解析。
    /// detail 已在 Bridge 的字段白名单内（截断 500 字符），无需改协议版本。
    var detail: String {
        "version=\(shortVersion) build=\(build) built_at=\(builtAtText)"
    }

    /// 从 Bundle 读取当前 build 的指纹。
    static func current(bundle: Bundle = .main, fileManager: FileManager = .default) -> BuildFingerprint {
        BuildFingerprint(
            shortVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
            build: bundle.infoDictionary?["CFBundleVersion"] as? String,
            builtAt: resolveBuiltAt(
                executableURL: bundle.executableURL,
                bundleURL: bundle.bundleURL,
                fileManager: fileManager
            )
        )
    }

    /// 可执行文件的时间戳，读不到时退到 bundle 目录自身。
    ///
    /// 取 `modificationDate` 而非 `creationDate`：拷贝/解包通常把 creationDate
    /// 重置为拷贝时刻、而保留源文件的 mtime。即便某些安装路径把 mtime 也重写成
    /// 安装时刻，那个值仍 ≥ 真实构建时刻，"新装通过、旧装拦下"的判定方向不变。
    static func resolveBuiltAt(
        executableURL: URL?,
        bundleURL: URL?,
        fileManager: FileManager = .default
    ) -> Date? {
        for url in [executableURL, bundleURL].compactMap({ $0 }) {
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { continue }
            if let date = attributes[.modificationDate] as? Date { return date }
            if let date = attributes[.creationDate] as? Date { return date }
        }
        return nil
    }

    /// detail 是空格分隔的 `k=v`，值里混进空格或 `=` 会让 Bridge 侧解析错位。
    /// 版本号理论上不含这些字符，但它来自 Info.plist（可被改），按外部输入处理。
    private static func normalize(_ value: String?) -> String {
        guard let value else { return unknown }
        let cleaned = String(
            value.map { $0.isWhitespace || $0 == "=" ? "_" : $0 }.prefix(64)
        ).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return cleaned.isEmpty ? unknown : cleaned
    }

    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
