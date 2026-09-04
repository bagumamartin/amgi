//! C ABI bridge for the Anki Rust backend.
//!
//! Exposes functions matching the pattern used by AnkiDroid's JNI bridge,
//! adapted for C ABI (Swift interop via XCFramework).

use std::os::raw::c_int;
use std::slice;

use anki::backend::{init_backend, Backend};
use anki_proto::search::search_node::{group::Joiner, Group as NodeGroup};
use anki_proto::search::{SearchNode, SearchRequest};
use anki_proto::{generic, notes, notetypes};
use prost::Message;
use serde::{Deserialize, Serialize};

/// Amgi-specific auxiliary service. Intercepts requests before engine
/// dispatch so we can ship features upstream has no RPC for without
/// touching vendored anki-upstream (browse-redesign-spec §4.3).
///
/// Wire format for aux methods is JSON (not protobuf): the payloads are
/// ours alone, and JSON avoids regenerating the Swift proto set whenever
/// an aux method grows a field.
const AUX_SERVICE_ID: u32 = 200;

#[derive(Deserialize)]
struct AuxFindDupesRequest {
    /// Optional search restricting the corpus (grammar text); empty = all.
    #[serde(default)]
    search: String,
    /// Field name to group by (case-insensitive per notetype).
    field_name: String,
}

#[derive(Serialize)]
struct AuxDuplicateGroup {
    value: String,
    note_ids: Vec<i64>,
}

#[derive(Serialize)]
struct AuxFindDupesResponse {
    groups: Vec<AuxDuplicateGroup>,
    /// Notes examined — lets Swift render "found N groups across M notes".
    notes_scanned: usize,
}

/// Create a new Anki backend instance.
///
/// # Safety
/// - `init_data` must point to a valid buffer of `init_len` bytes containing
///   a serialized `BackendInit` protobuf message (or be null for defaults).
/// - `out_ptr` must point to writable memory for a single i64.
///
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub unsafe extern "C" fn anki_open_backend(
    init_data: *const u8,
    init_len: usize,
    out_ptr: *mut i64,
) -> c_int {
    let init_bytes: &[u8] = if init_data.is_null() || init_len == 0 {
        // Empty init → default BackendInit (empty preferred_langs, server=false)
        b""
    } else {
        unsafe { slice::from_raw_parts(init_data, init_len) }
    };

    // If empty bytes, encode a default BackendInit
    let effective_bytes: Vec<u8>;
    let bytes_to_use = if init_bytes.is_empty() {
        use prost::Message;
        let default_init = anki_proto::backend::BackendInit::default();
        effective_bytes = default_init.encode_to_vec();
        &effective_bytes
    } else {
        init_bytes
    };

    match init_backend(bytes_to_use) {
        Ok(backend) => {
            let boxed = Box::new(backend);
            let ptr = Box::into_raw(boxed) as i64;
            unsafe { *out_ptr = ptr };
            0
        }
        Err(_e) => -1,
    }
}

/// Execute a backend RPC method via protobuf.
///
/// # Safety
/// - `backend_ptr` must be a valid pointer returned by `anki_open_backend`.
/// - `input_data`/`input_len` must describe a valid protobuf request.
/// - `out_data`/`out_len` receive the response (caller frees with `anki_free_response`).
///
/// Returns 0 on success (out_data has the response protobuf),
///         1 on backend error (out_data has the error protobuf),
///        -1 on FFI error.
#[no_mangle]
pub unsafe extern "C" fn anki_run_method(
    backend_ptr: i64,
    service: u32,
    method: u32,
    input_data: *const u8,
    input_len: usize,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    let backend = unsafe { &*(backend_ptr as *const Backend) };

    let input = if input_data.is_null() || input_len == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(input_data, input_len) }
    };

    // Aux services are handled in-crate, before engine dispatch.
    if service == AUX_SERVICE_ID {
        return match handle_aux_method(backend, method, input) {
            Ok(response_bytes) => {
                set_output(response_bytes, out_data, out_len);
                0
            }
            Err(message) => {
                set_output(message.into_bytes(), out_data, out_len);
                1 // aux error: response body is a UTF-8 message, not an Anki error proto
            }
        };
    }

    match backend.run_service_method(service, method, input) {
        Ok(output) => {
            set_output(output, out_data, out_len);
            0 // success
        }
        Err(err_bytes) => {
            set_output(err_bytes, out_data, out_len);
            1 // backend error (response contains error protobuf)
        }
    }
}

/// Free a response buffer allocated by `anki_run_method`.
#[no_mangle]
pub unsafe extern "C" fn anki_free_response(data: *mut u8, len: usize) {
    if !data.is_null() && len > 0 {
        let _ = unsafe { Vec::from_raw_parts(data, len, len) };
    }
}

/// Close and destroy the backend instance.
#[no_mangle]
pub unsafe extern "C" fn anki_close_backend(backend_ptr: i64) {
    if backend_ptr != 0 {
        let _ = unsafe { Box::from_raw(backend_ptr as *mut Backend) };
    }
}

// -- Helpers --

/// Aux dispatch. Methods: 0 = findDupesExact.
fn handle_aux_method(backend: &Backend, method: u32, input: &[u8]) -> Result<Vec<u8>, String> {
    match method {
        0 => aux_find_dupes_exact(backend, input),
        other => Err(format!("unknown aux method {other}")),
    }
}

/// Runs an engine RPC and decodes its response, mapping the engine's
/// error-bytes convention to a string for the aux error channel.
fn engine_call<M: Message + Default>(backend: &Backend, service: u32, method: u32, body: &[u8]) -> Result<M, String> {
    backend
        .run_service_method(service, method, body)
        .map_err(|err_bytes| {
            // Best effort: error proto carries a message field; fall back to raw bytes length.
            if let Ok(err) = anki_proto::backend::BackendError::decode(&err_bytes[..]) {
                format!("engine error: {}", err.message)
            } else {
                format!("engine error ({err_bytes_len} bytes)", err_bytes_len = err_bytes.len())
            }
        })
        .and_then(|bytes| M::decode(&bytes[..]).map_err(|e| format!("aux decode failed: {e}")))
}

/// Exact duplicate finder, mirroring desktop `Collection.find_dupes`
/// (pylib/anki/collection.py): restrict notes via optional search +
/// "has this field", take each note's value of that field,
/// strip HTML, skip empties, group exact matches.
///
/// Field values come from `getNote`, notetypes resolve their field ord
/// once. Composed only of public engine RPCs, so upstream refactors
/// can't silently break us (see handle_aux_method).
fn aux_find_dupes_exact(backend: &Backend, input: &[u8]) -> Result<Vec<u8>, String> {
    let req: AuxFindDupesRequest =
        serde_json::from_slice(input).map_err(|e| format!("bad request json: {e}"))?;

    let field_node = SearchNode {
        filter: Some(anki_proto::search::search_node::Filter::FieldName(
            req.field_name.clone(),
        )),
        ..Default::default()
    };
    let node = if req.search.trim().is_empty() {
        field_node
    } else {
        SearchNode {
            filter: Some(anki_proto::search::search_node::Filter::Group(NodeGroup {
                nodes: vec![
                    SearchNode {
                        filter: Some(anki_proto::search::search_node::Filter::ParsableText(
                            req.search.clone(),
                        )),
                        ..Default::default()
                    },
                    field_node,
                ],
                joiner: Joiner::And as i32,
            })),
            ..Default::default()
        }
    };

    let query = engine_call::<generic::String>(backend, 29, 0, &node.encode_to_vec())?;
    let ids = engine_call::<anki_proto::search::SearchResponse>(
        backend,
        29,
        2,
        &SearchRequest {
            search: query.val,
            order: None,
        }
        .encode_to_vec(),
    )?;

    let mut ords: std::collections::HashMap<i64, Option<usize>> = std::collections::HashMap::new();
    let mut order_index: Vec<String> = Vec::new();
    let mut groups: std::collections::HashMap<String, Vec<i64>> = std::collections::HashMap::new();

    for &nid in &ids.ids {
        let note = engine_call::<notes::Note>(
            backend,
            25,
            6,
            &notes::NoteId { nid }.encode_to_vec(),
        )?;
        let ord = *ords.entry(note.notetype_id).or_insert_with(|| {
            fetch_field_ord(backend, note.notetype_id, &req.field_name).unwrap_or(None)
        });
        let Some(ord) = ord else { continue };
        let Some(value) = note.fields.get(ord) else { continue };
        // Desktop uses strip_html_media; the media-preserving variant is
        // crate-private, so plain strip_html — differs only when a field
        // contains nothing but media filenames (never a real dupe signal).
        let val = anki::text::strip_html(value).trim().to_string();
        if val.is_empty() {
            continue;
        }
        let bucket = groups.entry(val.clone()).or_insert_with(|| {
            order_index.push(val.clone());
            Vec::new()
        });
        bucket.push(nid);
    }

    let groups_out: Vec<AuxDuplicateGroup> = order_index
        .into_iter()
        .filter_map(|key| {
            let ids = groups.remove(&key)?;
            (ids.len() >= 2).then_some(AuxDuplicateGroup {
                value: key,
                note_ids: ids,
            })
        })
        .collect();

    serde_json::to_vec(&AuxFindDupesResponse {
        notes_scanned: ids.ids.len(),
        groups: groups_out,
    })
    .map_err(|e| format!("encode failed: {e}"))
}

/// Ordinal of the named field in a notetype, case-insensitive.
fn fetch_field_ord(backend: &Backend, mid: i64, field_name: &str) -> Result<Option<usize>, String> {
    let notetype = engine_call::<notetypes::Notetype>(
        backend,
        23,
        6,
        &notetypes::NotetypeId { ntid: mid }.encode_to_vec(),
    )?;
    Ok(notetype
        .fields
        .iter()
        .position(|f| f.name.eq_ignore_ascii_case(field_name)))
}

unsafe fn set_output(data: Vec<u8>, out_data: *mut *mut u8, out_len: *mut usize) {
    let len = data.len();
    if len > 0 {
        let mut boxed = data.into_boxed_slice();
        let ptr = boxed.as_mut_ptr();
        std::mem::forget(boxed);
        unsafe {
            *out_data = ptr;
            *out_len = len;
        }
    } else {
        unsafe {
            *out_data = std::ptr::null_mut();
            *out_len = 0;
        }
    }
}
