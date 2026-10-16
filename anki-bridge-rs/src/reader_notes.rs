//! Reader notes: the notes behind an Anki-deck book, read in one pass.
//!
//! The reader used to fetch these one `GetNote` at a time from Swift — one
//! FFI round trip, one row read and one protobuf decode per chapter — and
//! carried every chapter's full text to draw a grid of titles. This reads
//! the matching rows in batches straight from the notes table and returns
//! only the fields the caller names, so the shelf never sees chapter text
//! and opening a book costs one call however many chapters it has.

use std::collections::HashMap;

use anki::backend::Backend;
use anki_proto::notetypes;
use anki_proto::search::{SearchRequest, SearchResponse};
use prost::Message;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::engine_call;

#[derive(Deserialize)]
struct Request {
    /// Search grammar text, e.g. `deck:"Books"` or `nid:1,2,3`.
    search: String,
    /// Field names to return. Absent returns every field.
    #[serde(default)]
    fields: Option<Vec<String>>,
    /// Notes where any of these fields is missing or empty are skipped,
    /// without returning the field itself — how the shelf drops chapters
    /// with no text while never reading that text across the bridge.
    #[serde(default)]
    require_nonempty: Vec<String>,
}

#[derive(Serialize)]
struct ReaderNote {
    id: i64,
    notetype_id: i64,
    fields: HashMap<String, String>,
}

#[derive(Serialize)]
struct Response {
    notes: Vec<ReaderNote>,
}

pub(crate) fn reader_notes(backend: &Backend, input: &[u8]) -> Result<Vec<u8>, String> {
    let req: Request = serde_json::from_slice(input).map_err(|e| format!("bad request json: {e}"))?;
    let ids = engine_call::<SearchResponse>(
        backend,
        29,
        2,
        &SearchRequest {
            search: req.search,
            order: None,
        }
        .encode_to_vec(),
    )?
    .ids;

    let mut field_names: HashMap<i64, Vec<String>> = HashMap::new();
    let mut notes = Vec::with_capacity(ids.len());
    for chunk in ids.chunks(1000) {
        let list = chunk.iter().map(i64::to_string).collect::<Vec<_>>().join(",");
        let rows = query(backend, &format!("SELECT id, mid, flds FROM notes WHERE id IN ({list})"))?;
        for row in rows {
            let (Some(id), Some(mid), Some(flds)) = (
                row.first().and_then(Value::as_i64),
                row.get(1).and_then(Value::as_i64),
                row.get(2).and_then(Value::as_str),
            ) else {
                continue;
            };
            if !field_names.contains_key(&mid) {
                field_names.insert(mid, notetype_field_names(backend, mid)?);
            }
            let names = &field_names[&mid];
            let values: Vec<&str> = flds.split('\u{1f}').collect();
            let value_of = |name: &str| {
                names
                    .iter()
                    .position(|n| n == name)
                    .and_then(|ord| values.get(ord).copied())
            };
            if req
                .require_nonempty
                .iter()
                .any(|name| value_of(name).map_or(true, str::is_empty))
            {
                continue;
            }
            let fields = match &req.fields {
                Some(wanted) => wanted
                    .iter()
                    .filter_map(|name| value_of(name).map(|v| (name.clone(), v.to_string())))
                    .collect(),
                None => names
                    .iter()
                    .enumerate()
                    .map(|(ord, name)| {
                        (name.clone(), values.get(ord).copied().unwrap_or("").to_string())
                    })
                    .collect(),
            };
            notes.push(ReaderNote {
                id,
                notetype_id: mid,
                fields,
            });
        }
    }

    serde_json::to_vec(&Response { notes }).map_err(|e| format!("encode failed: {e}"))
}

fn notetype_field_names(backend: &Backend, mid: i64) -> Result<Vec<String>, String> {
    let notetype = engine_call::<notetypes::Notetype>(
        backend,
        23,
        6,
        &notetypes::NotetypeId { ntid: mid }.encode_to_vec(),
    )?;
    Ok(notetype.fields.into_iter().map(|f| f.name).collect())
}

fn query(backend: &Backend, sql: &str) -> Result<Vec<Vec<Value>>, String> {
    let request = serde_json::json!({"kind": "query", "sql": sql, "args": [], "first_row_only": false});
    let bytes = backend
        .run_db_command_bytes(&serde_json::to_vec(&request).map_err(|e| e.to_string())?)
        .map_err(|e| format!("reader_notes: database error ({} bytes)", e.len()))?;
    serde_json::from_slice(&bytes).map_err(|e| format!("reader_notes: invalid database result: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use anki::backend::init_backend;
    use anki_proto::{
        backend::BackendInit,
        collection::OpenCollectionRequest,
        generic::Empty,
        notes::{AddNoteRequest, AddNoteResponse, Note},
        notetypes::NotetypeId,
    };

    fn add(backend: &Backend, ntid: i64, front: &str, back: &str) -> i64 {
        let mut note =
            engine_call::<Note>(backend, 25, 0, &NotetypeId { ntid }.encode_to_vec()).unwrap();
        note.fields = vec![front.into(), back.into()];
        engine_call::<AddNoteResponse>(
            backend,
            25,
            1,
            &AddNoteRequest {
                note: Some(note),
                deck_id: 1,
            }
            .encode_to_vec(),
        )
        .unwrap()
        .note_id
    }

    fn run(backend: &Backend, request: serde_json::Value) -> Vec<serde_json::Value> {
        let out: serde_json::Value = serde_json::from_slice(
            &reader_notes(backend, &serde_json::to_vec(&request).unwrap()).unwrap(),
        )
        .unwrap();
        let mut notes = out["notes"].as_array().unwrap().clone();
        notes.sort_by_key(|n| n["id"].as_i64());
        notes
    }

    #[test]
    fn returns_only_named_fields_and_skips_empty_required_ones() {
        let dir = tempfile::tempdir().unwrap();
        let backend = init_backend(&BackendInit::default().encode_to_vec()).unwrap();
        engine_call::<Empty>(
            &backend,
            3,
            0,
            &OpenCollectionRequest {
                collection_path: dir.path().join("collection.anki2").to_string_lossy().into_owned(),
                media_folder_path: dir.path().join("media").to_string_lossy().into_owned(),
                media_db_path: dir.path().join("media.db").to_string_lossy().into_owned(),
            }
            .encode_to_vec(),
        )
        .unwrap();
        let rows = query(&backend, "SELECT id FROM notetypes WHERE name = 'Basic'").unwrap();
        let ntid = rows[0][0].as_i64().unwrap();
        let first = add(&backend, ntid, "Chapter 1", "Long chapter text");
        let second = add(&backend, ntid, "Chapter 2", "More text");
        // Anki refuses a note whose first field is empty, so the "no
        // content" case is the second field.
        add(&backend, ntid, "Chapter 3", "");

        let shelf = run(
            &backend,
            serde_json::json!({"search": "deck:Default", "fields": ["Front"], "require_nonempty": ["Back"]}),
        );
        assert_eq!(shelf.len(), 2);
        assert_eq!(shelf[0]["id"], first);
        assert_eq!(shelf[0]["notetype_id"], ntid);
        assert_eq!(shelf[0]["fields"], serde_json::json!({"Front": "Chapter 1"}));

        let full = run(&backend, serde_json::json!({"search": format!("nid:{first},{second}")}));
        assert_eq!(
            full[1]["fields"],
            serde_json::json!({"Front": "Chapter 2", "Back": "More text"})
        );
    }
}
