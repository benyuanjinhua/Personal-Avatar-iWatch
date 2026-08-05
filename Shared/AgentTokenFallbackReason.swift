import Foundation

enum AgentTokenFallbackReason {
    static func reason(for error: Error) -> String {
        if (error as? URLError)?.code == .timedOut {
            return "token_mint_timeout"
        }
        return "token_mint_failed"
    }
}
