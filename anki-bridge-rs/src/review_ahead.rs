//! Reviews answered before they were due (aux method 9).
//!
//! For each card's first review-type answer inside the window, returns when
//! the card was last answered before it and the interval that answer set.
//! The Swift side adds the interval to that answer's Anki day to get the
//! day the card was scheduled for — the same calendar that draws Study's
//! day axis does the bucketing, as with `review_times`.
//!
//! Only the first answer per card counts: a second answer today would see
//! the first one as its predecessor and read as reviewed ahead again.
//! Learning steps (negative `lastIvl`, in seconds) are skipped; a card with
//! no earlier answer has no schedule to have been ahead of.

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

#[derive(Serialize, Debug, PartialEq)]
struct Answer {
    answered_at_ms: i64,
    previous_answer_ms: i64,
    /// Days the previous answer scheduled the card for.
    interval_days: i64,
}

#[derive(Serialize)]
struct Response {
    answers: Vec<Answer>,
}

pub(crate) fn review_ahead(backend: &Backend, input: &[u8]) -> Result<Vec<u8>, String> {
    let req: Request =
        serde_json::from_slice(input).map_err(|e| format!("bad request json: {e}"))?;
    if req.end_ms <= req.start_ms {
        return Err("review_ahead: end_ms must be after start_ms".to_string());
    }

    let request = serde_json::json!({
        "kind": "query",
        "sql": WINDOW_QUERY,
        "args": [req.start_ms, req.end_ms],
        "first_row_only": false,
    });
    let raw = backend
        .run_db_command_bytes(&serde_json::to_vec(&request).map_err(|e| e.to_string())?)
        .map_err(|e| format!("review_ahead: database error ({} bytes)", e.len()))?;
    let rows: Vec<Vec<Option<i64>>> =
        serde_json::from_slice(&raw).map_err(|e| format!("review_ahead: bad db result: {e}"))?;

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
        answers: first_answers(&rows, scope.as_ref()),
    })
    .map_err(|e| e.to_string())
}

/// Review and filtered answers in the window, ascending, with each one's
/// predecessor among real answers (learn, review, relearn, filtered).
const WINDOW_QUERY: &str = "SELECT r.id, r.cid, r.type, r.lastIvl, \
     (SELECT MAX(p.id) FROM revlog p WHERE p.cid = r.cid AND p.id < r.id AND p.type IN (0,1,2,3)) \
     FROM revlog r WHERE r.id >= ?1 AND r.id < ?2 AND r.type IN (0,1,2,3) ORDER BY r.id";

/// Rows are `[id, cid, type, lastIvl, previousId]`. Each card's first
/// answer in the window decides; only reviews with a day interval and a
/// predecessor are kept.
fn first_answers(rows: &[Vec<Option<i64>>], scope: Option<&HashSet<i64>>) -> Vec<Answer> {
    let mut seen = HashSet::new();
    rows.iter()
        .filter_map(|row| {
            let id = (*row.first()?)?;
            let cid = (*row.get(1)?)?;
            if !seen.insert(cid) || !scope.is_none_or(|ids| ids.contains(&cid)) {
                return None;
            }
            let kind = (*row.get(2)?)?;
            let last_ivl = (*row.get(3)?)?;
            let previous = (*row.get(4)?)?;
            (matches!(kind, 1 | 3) && last_ivl > 0).then_some(Answer {
                answered_at_ms: id,
                previous_answer_ms: previous,
                interval_days: last_ivl,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn window(db: &Connection, start: i64, end: i64) -> Vec<Vec<Option<i64>>> {
        let mut stmt = db.prepare(WINDOW_QUERY).unwrap();
        stmt.query_map([start, end], |row| {
            Ok(vec![row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?])
        })
        .unwrap()
        .map(Result::unwrap)
        .collect()
    }

    #[test]
    fn keeps_each_cards_first_review_with_its_predecessor() {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch(
            "CREATE TABLE revlog (id INTEGER PRIMARY KEY, cid INTEGER NOT NULL, type INTEGER NOT NULL, lastIvl INTEGER NOT NULL);
             INSERT INTO revlog VALUES (100, 1, 1, 3);     -- card 1, earlier review
             INSERT INTO revlog VALUES (150, 1, 4, 0);     -- manual entry, not a predecessor
             INSERT INTO revlog VALUES (1000, 1, 1, 10);   -- card 1 in window
             INSERT INTO revlog VALUES (1100, 1, 1, 12);   -- card 1 again: ignored
             INSERT INTO revlog VALUES (1200, 2, 1, 5);    -- card 2: no predecessor
             INSERT INTO revlog VALUES (200, 3, 0, -600);  -- card 3 learning step
             INSERT INTO revlog VALUES (1300, 3, 0, -600); -- card 3 learning: skipped
             INSERT INTO revlog VALUES (1350, 3, 1, 2);    -- card 3 later review: not first
             INSERT INTO revlog VALUES (300, 4, 1, 7);
             INSERT INTO revlog VALUES (1400, 4, 3, 7);    -- filtered review counts",
        )
        .unwrap();

        let rows = window(&db, 1000, 2000);
        assert_eq!(
            first_answers(&rows, None),
            vec![
                Answer { answered_at_ms: 1000, previous_answer_ms: 100, interval_days: 10 },
                Answer { answered_at_ms: 1400, previous_answer_ms: 300, interval_days: 7 },
            ]
        );

        let scope: HashSet<i64> = [4].into_iter().collect();
        assert_eq!(first_answers(&rows, Some(&scope)).len(), 1);
    }
}
