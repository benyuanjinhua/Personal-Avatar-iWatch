import Foundation

/// ESS-749：服务端（Bridge / WSS 下行）给出的 `request_id` 是不可信输入，
/// 在此统一收敛，三道闸口缺一不可：
///
/// 1. `isValid` —— 严格类型/长度/字符集校验，坏 ID 在解码边界直接丢弃；
/// 2. `fileToken` —— 落盘文件名只用 ID 的不可逆摘要，原始 ID 永不进路径；
/// 3. `fileURL(in:name:)` —— 标准化后仍须位于目标目录内，逃逸即失败。
///
/// 任何拿服务端 ID 拼文件路径的新代码都必须走这里，不得裸拼 `appendingPathComponent`。
enum RelayIdentifier {
    /// 上限 128：现网 ID 是 36 字符 UUID 或 `req_` + 32 hex，留足余量的同时
    /// 挡住超长 ID 撑爆文件名/日志。
    static let maxLength = 128

    /// 允许 ASCII 字母数字与 `-` `_`。`.` `/` `\` 与任何非 ASCII 一律拒绝——
    /// 因此 `..`、绝对路径、`%2e%2e` 解码后的分隔符、NUL 都进不来。
    static func isValid(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.utf8.count <= maxLength else { return false }
        return raw.utf8.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7A) // a-z
                || (byte >= 0x41 && byte <= 0x5A) // A-Z
                || (byte >= 0x30 && byte <= 0x39) // 0-9
                || byte == 0x2D // -
                || byte == 0x5F // _
        }
    }

    static func validated(_ raw: String) -> String? { isValid(raw) ? raw : nil }

    /// 文件名 token：ID 的 sha256 十六进制摘要。定长 64 hex、不可逆、天然
    /// path-safe——即使上游校验被绕过，也构造不出目录分隔符。
    static func fileToken(for raw: String) -> String {
        RelayWire.sha256Hex(Data(raw.utf8))
    }

    /// 在 `directory` 下按 `name` 造 URL，标准化后确认仍是该目录的直接子项。
    /// 逃逸/畸形名返回 nil，调用方必须按落盘失败处理，不许回退到裸拼接。
    static func fileURL(in directory: URL, name: String) -> URL? {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0")
        else { return nil }
        let base = directory.standardizedFileURL
        let candidate = base.appendingPathComponent(name).standardizedFileURL
        guard candidate.deletingLastPathComponent().path == base.path else { return nil }
        return candidate
    }
}
