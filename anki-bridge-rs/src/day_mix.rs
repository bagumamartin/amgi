//! Historical day mix for the Study history card (aux method 4).
//!
//! A past Anki day's dues are never recorded — the revlog logs answers,
//! and dues are transient scheduler state — so the mix is reconstructed
//! from the two durable traces:
//!
//! * **Answered** (revlog, exact per card): entries in the day's
//!   millisecond window with `ease > 0`. Manual reschedules and Forget
//!   log ease 0 and are not answers. Buckets follow the entry's `type`,
//!   except for new cards: a new answer logs the same `Learning` kind as
//!   a learning answer (`states/new.rs`), so answered-as-new is the
//!   subset whose entry is also the card's first-ever answer. Each card
//!   lands in exactly one bucket via its earliest entry of the day, so
//!   intraday learning steps never double-count.
//! * **Remaining** (engine search, same semantics as the backlog query):
//!   `prop:due<=-N` in the card's current queue state. `is:review` also
//!   matches Relearn types, so the review leg excludes `is:learn` —
//!   otherwise relearning cards land in both rows.
//!
//! Documented approximations: new cards due but skipped stay invisible
//! (no due-day is ever recorded for new cards — callers define due-new
//! as answered-as-new); a card answered then stuck relearning appears in
//! both halves; preview-repeat cards match neither state filter; deck
//! scoping joins the cards table's *current* deck.

use anki::backend::Backend;
use anki_proto::search::{SearchRequest, SearchResponse};
use prost::Message;
use serde::{Deserialize, Serialize};

use super::engine_call;

#[derive(Deserialize)]
struct StudyDayMixRequest {
    /// Anki search restricting the corpus (`""` = whole collection).
    #[serde(default)]
    scope_search: String,
    /// Anki-day window, UTC millis matching `revlog.id`.
    day_start_ms: i64,
    day_end_ms: i64,
    /// Days before today the window's start sits on; drives the
    /// still-due comparison (`prop:due<=-N`).
    overdue_days: i32,
}

#[derive(Serialize)]
struct StudyDayMixResponse {
    answered_new: i64,
    answered_learn: i64,
    answered_relearn: i64,
    answered_review: i64,
    answered_cards: i64,
    remaining_learn: i64,
    remaining_review: i64,
}

pub(crate) fn study_day_mix(
    backend: &Backend,
    input: &[u8],
) -> Result<Vec<u8>, String> {
    let req: StudyDayMixRequest =
        serde_json::from_slice(input).map_err(|e| format!("bad request json: {e}"))?;
    if req.day_end_ms <= req.day_start_ms {
        return Err("study_day_mix: day_end_ms must be after day_start_ms".to_string());
    }

    // Deck scope resolves through the engine so grammar, hierarchy, and
    // filtered-deck membership behave exactly like in-app search.
    let scope_ids: Option<Vec<i64>> = if req.scope_search.trim().is_empty() {
        None
    } else {
        Some(engine_call::<SearchResponse>(
            backend,
            29,
            1,
            &SearchRequest {
                search: req.scope_search.clone(),
                order: None,
            }
            .encode_to_vec(),
        ).map(|resp| resp.ids)?)
    };

    // Aggregation runs unscoped, or once per id chunk: chunks partition
    // cards, so per-bucket sums stay exact at any deck size.
    let mut answered = [0i64; 4];
    match scope_ids.as_deref() {
        None => {
            let row = query_buckets(backend, req.day_start_ms, req.day_end_ms, None)?;
            for (i, total) in answered.iter_mut().enumerate() {
                *total = row[i];
            }
        }
        Some(ids) => {
            for chunk in ids.chunks(10_000) {
                if chunk.is_empty() {
                    continue;
                }
                let row = query_buckets(backend, req.day_start_ms, req.day_end_ms, Some(chunk))?;
                for (i, total) in answered.iter_mut().enumerate() {
                    *total += row[i];
                }
            }
        }
    }
    let [answered_new, answered_learn, answered_relearn, answered_review] = answered;

    let overdue = req.overdue_days.max(0);
    let remaining_learn = search_count(
        backend,
        &scoped_due_search(&req.scope_search, "is:learn", overdue),
    )?;
    let remaining_review = search_count(
        backend,
        &scoped_due_search(&req.scope_search, "is:review -is:learn", overdue),
    )?;

    serde_json::to_vec(&StudyDayMixResponse {
        answered_new,
        answered_learn,
        answered_relearn,
        answered_review,
        answered_cards: answered_new + answered_learn + answered_relearn + answered_review,
        remaining_learn,
        remaining_review,
    })
    .map_err(|e| e.to_string())
}

/// Still-due search for one state leg. Mirrors the backlog query's shape
/// (`(is:learn or is:review) prop:due<0 -is:suspended`), pushed back N
/// days; the engine resolves learn-queue epoch dues against the same
/// comparison, so intraday steps and review day-numbers share it.
fn scoped_due_search(scope: &str, state: &str, overdue_days: i32) -> String {
    let base = format!("{state} prop:due<={} -is:suspended", -overdue_days);
    if scope.trim().is_empty() {
        base
    } else {
        format!("{base} {}", scope.trim())
    }
}

fn search_count(backend: &Backend, search: &str) -> Result<i64, String> {
    let resp = engine_call::<SearchResponse>(
        backend,
        29,
        1,
        &SearchRequest {
            search: search.to_string(),
            order: None,
        }
        .encode_to_vec(),
    )?;
    Ok(resp.ids.len() as i64)
}

/// Maps the engine's protobuf error envelope to the aux UTF-8 channel.
fn db_error_message(err_bytes: Vec<u8>) -> String {
    if let Ok(err) = anki_proto::backend::BackendError::decode(&err_bytes[..]) {
        format!("engine error: {}", err.message)
    } else {
        format!("engine error ({} bytes)", err_bytes.len())
    }
}

/// Runs the answered-mix aggregation once and returns the four bucket
/// counts (new, learn, relearn, review).
fn query_buckets(
    backend: &Backend,
    day_start_ms: i64,
    day_end_ms: i64,
    scope_ids: Option<&[i64]>,
) -> Result<[i64; 4], String> {
    let (sql, args) = answered_mix_query(day_start_ms, day_end_ms, scope_ids);
    let db_request = serde_json::json!({
        "kind": "query",
        "sql": sql,
        "args": args,
        "first_row_only": false,
    });
    let raw = backend
        .run_db_command_bytes(&serde_json::to_vec(&db_request).map_err(|e| e.to_string())?)
        .map_err(db_error_message)?;
    let rows: Vec<Vec<i64>> =
        serde_json::from_slice(&raw).map_err(|e| format!("study_day_mix: bad db result: {e}"))?;
    let row = rows
        .first()
        .ok_or_else(|| "study_day_mix: empty db result".to_string())?;
    let mut out = [0i64; 4];
    for (i, total) in out.iter_mut().enumerate() {
        *total = row
            .get(i)
            .copied()
            .ok_or_else(|| format!("study_day_mix: missing column {i}"))?;
    }
    Ok(out)
}
fn answered_mix_query(
    day_start_ms: i64,
    day_end_ms: i64,
    scope_ids: Option<&[i64]>,
) -> (String, Vec<i64>) {
    use std::fmt::Write;

    let mut sql = String::from(
        "SELECT \
           COUNT(DISTINCT CASE WHEN d.rn_day = 1 AND d.first_overall = 1 THEN d.cid END), \
           COUNT(DISTINCT CASE WHEN d.rn_day = 1 AND d.first_overall = 0 AND d.rtype = 0 THEN d.cid END), \
           COUNT(DISTINCT CASE WHEN d.rn_day = 1 AND d.rtype = 2 THEN d.cid END), \
           COUNT(DISTINCT CASE WHEN d.rn_day = 1 AND d.rtype IN (1, 3) THEN d.cid END) \
         FROM ( \
           SELECT r.cid AS cid, r.\"type\" AS rtype, \
                  CASE WHEN r.id = firsts.first_id THEN 1 ELSE 0 END AS first_overall, \
                  ROW_NUMBER() OVER (PARTITION BY r.cid ORDER BY r.id) AS rn_day \
           FROM revlog r \
           JOIN (SELECT cid, MIN(id) AS first_id FROM revlog WHERE ease > 0 GROUP BY cid) firsts \
             ON firsts.cid = r.cid \
           WHERE r.ease > 0 AND r.id >= ?1 AND r.id < ?2",
    );
    let mut args = vec![day_start_ms, day_end_ms];
    // Callers chunk large scopes so one statement never approaches
    // SQLite's variable limit; a single IN group suffices here.
    if let Some(ids) = scope_ids {
        sql.push_str(" AND r.cid IN (");
        for (j, id) in ids.iter().enumerate() {
            if j > 0 {
                sql.push(',');
            }
            // Args 1-2 are the day bounds; ids follow positionally.
            let _ = write!(sql, "?{}", args.len() + 1);
            args.push(*id);
        }
        sql.push(')');
    }
    sql.push_str(") d");
    (sql, args)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    /// Minimal revlog-shaped fixture. Columns mirror the engine schema;
    /// only the queried ones are populated.
    fn fixture_db() -> Connection {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch(
            "CREATE TABLE revlog (
               id INTEGER PRIMARY KEY, cid INTEGER NOT NULL, usn INTEGER NOT NULL,
               ease INTEGER NOT NULL, ivl INTEGER NOT NULL, lastIvl INTEGER NOT NULL,
               factor INTEGER NOT NULL, time INTEGER NOT NULL, type INTEGER NOT NULL
             );
             CREATE INDEX ix_revlog_cid ON revlog (cid);",
        )
        .unwrap();
        // Day window: [1000, 2000). Card 1: new card answered twice
        // (learning steps) — counts once, as new.
        db.execute("INSERT INTO revlog VALUES (1100, 1, 0, 3, 0, 0, 0, 10, 0)", [])
            .unwrap();
        db.execute("INSERT INTO revlog VALUES (1200, 1, 0, 3, 0, 0, 0, 10, 0)", [])
            .unwrap();
        // Card 2: answered before the window, learns again inside it.
        db.execute("INSERT INTO revlog VALUES (500, 2, 0, 3, 0, 0, 0, 10, 0)", [])
            .unwrap();
        db.execute("INSERT INTO revlog VALUES (1300, 2, 0, 2, 0, 0, 0, 10, 0)", [])
            .unwrap();
        // Card 3: relearn inside the window.
        db.execute("INSERT INTO revlog VALUES (600, 3, 0, 4, 10, 9, 0, 10, 1)", [])
            .unwrap();
        db.execute("INSERT INTO revlog VALUES (1400, 3, 0, 1, 10, 9, 0, 10, 2)", [])
            .unwrap();
        // Cards 4-5: review and early (filtered) review, each with
        // earlier history so only new card 1 lands in the new bucket.
        db.execute("INSERT INTO revlog VALUES (800, 4, 0, 4, 10, 9, 0, 10, 1)", [])
            .unwrap();
        db.execute("INSERT INTO revlog VALUES (1500, 4, 0, 4, 20, 19, 0, 10, 1)", [])
            .unwrap();
        db.execute("INSERT INTO revlog VALUES (850, 5, 0, 3, 10, 9, 0, 10, 1)", [])
            .unwrap();
        db.execute("INSERT INTO revlog VALUES (1600, 5, 0, 3, 20, 19, 0, 10, 3)", [])
            .unwrap();
        // Card 6: manual reschedule only — not an answer.
        db.execute("INSERT INTO revlog VALUES (1700, 6, 0, 0, 20, 19, 0, 10, 1)", [])
            .unwrap();
        // Card 7: answered before the window only.
        db.execute("INSERT INTO revlog VALUES (700, 7, 0, 4, 30, 29, 0, 10, 1)", [])
            .unwrap();
        db
    }

    fn run_query(db: &Connection, scope: Option<&[i64]>) -> Vec<i64> {
        let (sql, args) = answered_mix_query(1000, 2000, scope);
        let mut stmt = db.prepare(&sql).unwrap();
        let params = rusqlite::params_from_iter(args.iter());
        stmt.query_row(params, |row| {
            Ok(vec![
                row.get::<_, i64>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, i64>(3)?,
            ])
        })
        .unwrap()
    }

    #[test]
    fn buckets_new_learn_relearn_review_without_double_counting() {
        let counts = run_query(&fixture_db(), None);
        assert_eq!(counts, vec![1, 1, 1, 2], "new/learn/relearn/review: {counts:?}");
    }

    #[test]
    fn scope_filter_restricts_to_listed_cards() {
        let counts = run_query(&fixture_db(), Some(&[1, 4]));
        assert_eq!(counts, vec![1, 0, 0, 1], "scoped: {counts:?}");
    }

    #[test]
    fn scope_ids_become_positional_args_after_the_day_bounds() {
        let ids: Vec<i64> = (1..=10_001).collect();
        let (sql, args) = answered_mix_query(1000, 2000, Some(&ids));
        // One IN group per call — the handler chunks large scopes into
        // separate calls so no statement nears the variable limit.
        assert_eq!(sql.matches("r.cid IN (").count(), 1);
        assert_eq!(args.len(), 2 + ids.len());
        // Highest positional placeholder matches the arg count.
        assert!(sql.contains("?10003"));
    }

    #[test]
    fn empty_window_returns_zero_row() {
        let counts = run_query(&fixture_db(), None);
        let _ = counts;
        let (sql, args) = answered_mix_query(5000, 6000, None);
        let db = fixture_db();
        let mut stmt = db.prepare(&sql).unwrap();
        let row = stmt
            .query_row(rusqlite::params_from_iter(args.iter()), |row| {
                Ok(vec![
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                ])
            })
            .unwrap();
        assert_eq!(row, vec![0, 0, 0, 0]);
    }
}
