//! Answer timestamps inside one window (aux method 7).
//!
//! Study's day chart buckets these into local hours on the Swift side, so
//! the calendar that draws the axis is the one that buckets the answers.
//! The window is a millisecond range over `revlog.id`, which is the primary
//! key — one day costs a range scan, not a pass over the whole log.
//!
//! The filter matches the engine's review-count graph (`stats/graphs/
//! reviews.rs`): everything except Manual (4) and Rescheduled (5). A day's
//! hours therefore add up to that day's bar in the week and month views.

use std::collections::HashSet;

use anki::backend::Backend;
use anki_proto::search::{SearchRequest, SearchResponse};
use prost::Message;
use serde::{Deserialize, Serialize};

use super::engine_call;

#[derive(Deserialize)]
struct Request {
    /// Anki search restricting the cards (`""` = whole collection).
    #[serde(default)]
    scope_search: String,
    /// UTC millis matching `revlog.id`; start inclusive, end exclusive.
    start_ms: i64,
    end_ms: i64,
}

#[derive(Serialize)]
struct Response {
    /// One entry per answer, ascending.
    answered_at_ms: Vec<i64>,
}

pub(crate) fn review_times(backend: &Backend, input: &[u8]) -> Result<Vec<u8>, String> {
    let req: Request =
        serde_json::from_slice(input).map_err(|e| format!("bad request json: {e}"))?;
    if req.end_ms <= req.start_ms {
        return Err("review_times: end_ms must be after start_ms".to_string());
    }

    let request = serde_json::json!({
        "kind": "query",
        "sql": WINDOW_QUERY,
        "args": [req.start_ms, req.end_ms],
        "first_row_only": false,
    });
    let raw = backend
        .run_db_command_bytes(&serde_json::to_vec(&request).map_err(|e| e.to_string())?)
        .map_err(|e| format!("review_times: database error ({} bytes)", e.len()))?;
    let rows: Vec<Vec<i64>> =
        serde_json::from_slice(&raw).map_err(|e| format!("review_times: bad db result: {e}"))?;

    // Deck scope resolves through the engine so search grammar and deck
    // hierarchy behave exactly like in-app search.
    let scope: Option<HashSet<i64>> = if req.scope_search.trim().is_empty() {
        None
    } else {
        let resp = engine_call::<SearchResponse>(
            backend,
            29,
            1,
            &SearchRequest {
                search: req.scope_search,
                order: None,
            }
            .encode_to_vec(),
        )?;
        Some(resp.ids.into_iter().collect())
    };

    serde_json::to_vec(&Response {
        answered_at_ms: in_scope(&rows, scope.as_ref()),
    })
    .map_err(|e| e.to_string())
}

const WINDOW_QUERY: &str =
    "SELECT id, cid FROM revlog WHERE id >= ?1 AND id < ?2 AND type IN (0,1,2,3) ORDER BY id";

/// Keeps rows whose card is in scope. Rows are `[id, cid]`.
fn in_scope(rows: &[Vec<i64>], scope: Option<&HashSet<i64>>) -> Vec<i64> {
    rows.iter()
        .filter_map(|row| {
            let (&id, &cid) = (row.first()?, row.get(1)?);
            scope.is_none_or(|ids| ids.contains(&cid)).then_some(id)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn window(db: &Connection, start: i64, end: i64) -> Vec<Vec<i64>> {
        let mut stmt = db.prepare(WINDOW_QUERY).unwrap();
        stmt.query_map([start, end], |row| Ok(vec![row.get(0)?, row.get(1)?]))
            .unwrap()
            .map(Result::unwrap)
            .collect()
    }

    #[test]
    fn window_keeps_answers_and_drops_manual_and_rescheduled() {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch(
            "CREATE TABLE revlog (id INTEGER PRIMARY KEY, cid INTEGER NOT NULL, type INTEGER NOT NULL);
             INSERT INTO revlog VALUES (999, 1, 1);   -- before the window
             INSERT INTO revlog VALUES (1000, 1, 0);  -- learning, on the start bound
             INSERT INTO revlog VALUES (1100, 2, 1);  -- review
             INSERT INTO revlog VALUES (1200, 3, 2);  -- relearning
             INSERT INTO revlog VALUES (1300, 4, 3);  -- filtered
             INSERT INTO revlog VALUES (1400, 5, 4);  -- manual
             INSERT INTO revlog VALUES (1500, 6, 5);  -- rescheduled
             INSERT INTO revlog VALUES (2000, 7, 1);  -- on the end bound",
        )
        .unwrap();

        let rows = window(&db, 1000, 2000);
        assert_eq!(in_scope(&rows, None), vec![1000, 1100, 1200, 1300]);

        let scope: HashSet<i64> = [2, 4, 6].into_iter().collect();
        assert_eq!(in_scope(&rows, Some(&scope)), vec![1100, 1300]);
    }
}
