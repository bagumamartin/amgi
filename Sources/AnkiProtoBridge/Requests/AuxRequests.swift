import Foundation
public import AnkiBackend
public import AnkiKit

// MARK: - aux service (anki-bridge-rs, service 200)

/// Amgi-only methods implemented inside our FFI crate and intercepted
/// before engine dispatch. Wire format is JSON on both sides — see
/// `handle_aux_method` in anki-bridge-rs/src/lib.rs. The engine's
/// protobuf error envelope does NOT apply here: failures surface as a
/// UTF-8 message with the same exit-code convention.
extension Request where Response == FindDuplicatesResult {
    /// Exact duplicate finder over one field (desktop `find_dupes`
    /// semantics). Optional `search` restricts the corpus.
    public static func findDuplicatesExact(search: String, fieldName: String) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.findDupesExact,
            encode: {
                let payload: [String: String] = [
                    "search": search,
                    "field_name": fieldName,
                ]
                return try JSONSerialization.data(withJSONObject: payload)
            },
            decode: { bytes in
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return try decoder.decode(FindDuplicatesResult.self, from: bytes)
            }
        )
    }
}
