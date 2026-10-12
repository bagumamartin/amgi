import Foundation

/// The SDK currently decodes experimental capabilities as [String: String],
/// although MCP permits arbitrary JSON values. Ijuka implements no experimental
/// client capability, so omit that unused field before SDK decoding. All other
/// messages and advertised standard capabilities remain unchanged.
enum InitializeCompatibility {
    static func normalize(_ line: Data) -> Data {
        guard var message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              message["method"] as? String == "initialize",
              var params = message["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              capabilities["experimental"] != nil else { return line }
        capabilities.removeValue(forKey: "experimental")
        params["capabilities"] = capabilities
        message["params"] = params
        return (try? JSONSerialization.data(withJSONObject: message)) ?? line
    }
}
