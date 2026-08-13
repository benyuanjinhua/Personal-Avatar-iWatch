import Foundation

/// RFC 9562 UUIDv7：前 48 位为 Unix 毫秒时间戳，保证请求 ID 按时间大致有序，
/// 便于服务端按时间排查与幂等去重。
enum UUIDv7 {
    static func generate(now: Date = Date()) -> UUID {
        var random = [UInt8](repeating: 0, count: 10)
        for index in random.indices {
            random[index] = UInt8.random(in: .min ... .max)
        }
        return make(timestampMs: UInt64(max(0, now.timeIntervalSince1970 * 1000)), random: random)
    }

    /// 随机字节可注入，供测试验证版本位与时间戳布局。
    static func make(timestampMs: UInt64, random: [UInt8]) -> UUID {
        precondition(random.count >= 10, "UUIDv7 需要至少 10 个随机字节")
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = UInt8((timestampMs >> 40) & 0xFF)
        bytes[1] = UInt8((timestampMs >> 32) & 0xFF)
        bytes[2] = UInt8((timestampMs >> 24) & 0xFF)
        bytes[3] = UInt8((timestampMs >> 16) & 0xFF)
        bytes[4] = UInt8((timestampMs >> 8) & 0xFF)
        bytes[5] = UInt8(timestampMs & 0xFF)
        bytes[6] = 0x70 | (random[0] & 0x0F)
        bytes[7] = random[1]
        bytes[8] = 0x80 | (random[2] & 0x3F)
        for index in 3..<10 {
            bytes[index + 6] = random[index]
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func timestampMs(of uuid: UUID) -> UInt64 {
        let bytes = uuid.uuid
        return UInt64(bytes.0) << 40
            | UInt64(bytes.1) << 32
            | UInt64(bytes.2) << 24
            | UInt64(bytes.3) << 16
            | UInt64(bytes.4) << 8
            | UInt64(bytes.5)
    }

    /// version nibble 是否为 7。非 v7 的 UUID 前 48 位是随机数，
    /// `timestampMs(of:)` 读出来是垃圾值——任何拿它做时序判定的调用方
    /// 都必须先过这道检查（ESS-747）。
    static func isV7(_ uuid: UUID) -> Bool {
        (uuid.uuid.6 >> 4) == 0x7
    }

    /// 只有 UUIDv7 才返回时间戳；其余一律 `nil`，让调用方显式处理
    /// 「这个 id 不携带时序」而不是拿随机位当时间用。
    static func turnTimestampMs(of uuid: UUID) -> UInt64? {
        isV7(uuid) ? timestampMs(of: uuid) : nil
    }

    /// 字符串入口：非法 UUID / 非 v7 都返回 `nil`。
    static func turnTimestampMs(ofString string: String) -> UInt64? {
        guard let uuid = UUID(uuidString: string) else { return nil }
        return turnTimestampMs(of: uuid)
    }
}
