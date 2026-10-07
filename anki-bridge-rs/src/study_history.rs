//! Read-only interpretation of retained scheduling events, not a scheduler.
//! Daily new-card limits and historical deck membership are not retained.
//! A queue flag predating the boundary is usable only when the card has not
//! changed since then. Later suspension transitions are not logged by Anki.
use std::collections::BTreeMap;

use anki::backend::Backend;
use anki_proto::search::{SearchRequest, SearchResponse};
use chrono::{Local, TimeZone, Timelike};
use prost::Message;
use serde::{Deserialize, Serialize};

use super::engine_call;

#[derive(Deserialize)]
struct Request {
    #[serde(default)]
    scope_search: String,
    day_end_ms: i64,
    rollover_hour: u32,
}

#[derive(Default, Serialize)]
struct History {
    learning_ids: Vec<i64>,
    review_ids: Vec<i64>,
    new_candidate_ids: Vec<i64>,
    unresolved: Vec<Unresolved>,
    suspension_unknown_ids: Vec<i64>,
}

#[derive(Serialize)]
struct Unresolved {
    card_id: i64,
    reason: &'static str,
}

#[derive(Clone, Debug)]
struct Event {
    id: i64,
    ease: i64,
    interval: i64,
    last_interval: i64,
    factor: i64,
    kind: i64,
}

impl Event {
    fn reset(&self) -> bool {
        self.kind == 4 && self.factor == 0 && self.interval == 0
    }

    fn scheduling_answer(&self) -> bool {
        self.ease > 0 && matches!(self.kind, 0..=3) && !(self.kind == 3 && self.factor == 0)
    }
}

#[derive(Debug)]
struct Card {
    id: i64,
    kind: i64,
    queue: i64,
    due: i64,
    modified_secs: i64,
    events: Vec<Event>,
}

fn suspension_state_is_known(card: &Card, end: i64) -> bool {
    // Card modifications have second precision. Use the end of that second,
    // and reject contradictory later logs (for example, imported history).
    card.modified_secs > 0
        && card.modified_secs.saturating_add(1).saturating_mul(1000) <= end
        && !card.events.iter().any(|e| e.id >= end)
}

#[derive(Debug, PartialEq)]
enum ResultKind {
    Learning,
    Review,
    New,
    NotDue,
    Unresolved(&'static str),
}

// Calendar dates, not elapsed 86400-second blocks: DST changes day length.
fn day(stamp_ms: i64, rollover: u32) -> Result<chrono::NaiveDate, String> {
    let dt = Local
        .timestamp_millis_opt(stamp_ms)
        .single()
        .ok_or_else(|| "study_history: invalid timestamp".to_string())?;
    let date = dt.date_naive();
    if dt.hour() < rollover {
        date.pred_opt()
            .ok_or_else(|| "study_history: date underflow".to_string())
    } else {
        Ok(date)
    }
}

fn reconstruct(card: &Card, end: i64, rollover: u32) -> Result<ResultKind, String> {
    // This establishes a suspension at the historical boundary; it does not
    // apply a suspension made today to an earlier day.
    if card.queue == -1 && suspension_state_is_known(card, end) {
        return Ok(ResultKind::NotDue);
    }
    let before: Vec<_> = card.events.iter().filter(|e| e.id < end).collect();
    let after = card.events.iter().find(|e| e.id >= end);
    let Some(last) = before.last().copied() else {
        return Ok(match card.events.first() {
            Some(first) if first.kind == 0 && first.last_interval == 0 && first.ease > 0 => {
                ResultKind::New
            }
            None if card.kind == 0 => ResultKind::New,
            _ => ResultKind::Unresolved("incomplete_log"),
        });
    };
    if last.reset() {
        return Ok(ResultKind::New);
    }
    if last.kind == 4 || (last.ease == 0 && last.kind != 5) {
        return Ok(ResultKind::Unresolved("manual_schedule"));
    }
    let boundary_day = day(end - 1, rollover)?;
    if last.kind == 5 {
        // Upstream FSRS rescheduling measures its new interval from the last
        // scheduling answer, not from the time the parameters were changed.
        let reset = before
            .iter()
            .rfind(|e| e.reset())
            .map(|e| e.id)
            .unwrap_or(0);
        let Some(anchor) = before
            .iter()
            .rfind(|e| e.scheduling_answer() && e.id > reset)
        else {
            return Ok(ResultKind::Unresolved("incomplete_log"));
        };
        if last.interval <= 0 {
            return Ok(ResultKind::Unresolved("ambiguous_state"));
        }
        let elapsed = boundary_day
            .signed_duration_since(day(anchor.id, rollover)?)
            .num_days();
        return Ok(if elapsed >= last.interval {
            ResultKind::Review
        } else {
            ResultKind::NotDue
        });
    }
    if !last.scheduling_answer() {
        return Ok(ResultKind::Unresolved("incomplete_log"));
    }
    if last.interval < 0 {
        // The revlog records the nominal delay. Anki can fuzz intraday
        // learning by up to 25%, capped at five minutes, before persisting due.
        let delay = last.interval.saturating_neg();
        let nominal = last.id.saturating_add(delay.saturating_mul(1000));
        let latest = nominal.saturating_add((delay / 4).min(300) * 1000);
        if nominal >= end {
            return Ok(ResultKind::NotDue);
        }
        if latest >= end {
            // Current timestamp is usable only if this is still the latest
            // scheduling event and the card remains an intraday learner.
            if after.is_none() && card.queue == 1 && matches!(card.kind, 1 | 3) {
                return Ok(if card.due.saturating_mul(1000) < end {
                    ResultKind::Learning
                } else {
                    ResultKind::NotDue
                });
            }
            return Ok(ResultKind::Unresolved("learning_rollover"));
        }
        return Ok(ResultKind::Learning);
    }
    if last.interval == 0 {
        return Ok(ResultKind::Unresolved("ambiguous_state"));
    }
    let elapsed = boundary_day
        .signed_duration_since(day(last.id, rollover)?)
        .num_days();
    if elapsed < last.interval {
        return Ok(ResultKind::NotDue);
    }
    // Positive intervals also occur in interday learning. The next scheduling
    // answer describes its input state; a manual event between them invalidates
    // that evidence. Current state is the fallback only without later events.
    Ok(match after {
        Some(e) if e.scheduling_answer() => match e.kind {
            0 | 2 => ResultKind::Learning,
            1 | 3 => ResultKind::Review,
            _ => ResultKind::Unresolved("ambiguous_state"),
        },
        Some(_) => ResultKind::Unresolved("ambiguous_state"),
        None => match card.kind {
            1 | 3 => ResultKind::Learning,
            2 => ResultKind::Review,
            _ => ResultKind::Unresolved("ambiguous_state"),
        },
    })
}

fn query(backend: &Backend, sql: &str, args: Vec<i64>) -> Result<Vec<Vec<i64>>, String> {
    let request =
        serde_json::json!({"kind":"query", "sql":sql, "args":args, "first_row_only":false});
    let bytes = backend
        .run_db_command_bytes(&serde_json::to_vec(&request).map_err(|e| e.to_string())?)
        .map_err(|e| format!("study_history: database error ({} bytes)", e.len()))?;
    serde_json::from_slice(&bytes)
        .map_err(|e| format!("study_history: invalid database result: {e}"))
}

// At most five evidence rows per card, selected using Anki's revlog(cid) index.
// Include the earliest event, the latest event before the boundary, the first
// after it, the preceding real answer and the last logged reset.
fn evidence_query(ids: &[i64]) -> String {
    let ids = ids.iter().map(i64::to_string).collect::<Vec<_>>().join(",");
    let targets = ids
        .split(',')
        .map(|id| format!("({id})"))
        .collect::<Vec<_>>()
        .join(",");
    format!(
        r#"WITH targets(cid) AS (VALUES {targets}), evidence AS MATERIALIZED (
      SELECT
        (SELECT MIN(id) FROM revlog WHERE cid=t.cid AND (type != 3 OR factor != 0)) AS first_id,
        (SELECT MAX(id) FROM revlog WHERE cid=t.cid AND id<?1 AND (type != 3 OR factor != 0)) AS before_id,
        (SELECT MIN(id) FROM revlog WHERE cid=t.cid AND id>=?1 AND (type != 3 OR factor != 0)) AS after_id,
        (SELECT MAX(id) FROM revlog WHERE cid=t.cid AND id<?1 AND ease>0 AND type IN (0,1,2,3) AND (type != 3 OR factor != 0)) AS answer_id,
        (SELECT MAX(id) FROM revlog WHERE cid=t.cid AND id<?1 AND type=4 AND factor=0 AND ivl=0) AS reset_id
      FROM targets t
    ) SELECT cid,id,ease,ivl,lastIvl,factor,type FROM revlog WHERE id IN (
      SELECT first_id FROM evidence UNION SELECT before_id FROM evidence
      UNION SELECT after_id FROM evidence UNION SELECT answer_id FROM evidence
      UNION SELECT reset_id FROM evidence
    ) ORDER BY cid,id"#
    )
}

pub(crate) fn study_history(backend: &Backend, input: &[u8]) -> Result<Vec<u8>, String> {
    let req: Request = serde_json::from_slice(input).map_err(|e| e.to_string())?;
    if req.day_end_ms <= 0 || req.rollover_hour > 23 {
        return Err("study_history: invalid boundary or rollover hour".to_string());
    }
    let scope = engine_call::<SearchResponse>(
        backend,
        29,
        1,
        &SearchRequest {
            search: req.scope_search,
            order: None,
        }
        .encode_to_vec(),
    )?
    .ids;
    let mut history = History::default();
    for chunk in scope.chunks(1000) {
        let ids = chunk
            .iter()
            .map(i64::to_string)
            .collect::<Vec<_>>()
            .join(",");
        let rows = query(backend, &format!("SELECT id,type,queue,CASE WHEN odue!=0 THEN odue ELSE due END,mod FROM cards WHERE id IN ({ids}) AND id<?1 ORDER BY id"), vec![req.day_end_ms])?;
        let mut cards: BTreeMap<i64, Card> = rows
            .into_iter()
            .map(|r| {
                (
                    r[0],
                    Card {
                        id: r[0],
                        kind: r[1],
                        queue: r[2],
                        due: r[3],
                        modified_secs: r[4],
                        events: vec![],
                    },
                )
            })
            .collect();
        for r in query(backend, &evidence_query(chunk), vec![req.day_end_ms])? {
            if let Some(card) = cards.get_mut(&r[0]) {
                card.events.push(Event {
                    id: r[1],
                    ease: r[2],
                    interval: r[3],
                    last_interval: r[4],
                    factor: r[5],
                    kind: r[6],
                });
            }
        }
        for card in cards.values() {
            match reconstruct(card, req.day_end_ms, req.rollover_hour)? {
                ResultKind::Learning => history.learning_ids.push(card.id),
                ResultKind::Review => history.review_ids.push(card.id),
                ResultKind::New => history.new_candidate_ids.push(card.id),
                ResultKind::Unresolved(reason) => history.unresolved.push(Unresolved {
                    card_id: card.id,
                    reason,
                }),
                ResultKind::NotDue => continue,
            }
            if !suspension_state_is_known(card, req.day_end_ms) {
                history.suspension_unknown_ids.push(card.id);
            }
        }
    }
    history.learning_ids.sort_unstable();
    history.review_ids.sort_unstable();
    history.new_candidate_ids.sort_unstable();
    history.unresolved.sort_by_key(|e| e.card_id);
    history.suspension_unknown_ids.sort_unstable();
    serde_json::to_vec(&history).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stamp(day: u32, hour: u32) -> i64 {
        Local
            .with_ymd_and_hms(2026, 10, day, hour, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis()
    }
    fn event(day: u32, kind: i64, interval: i64) -> Event {
        Event {
            id: stamp(day, 12),
            ease: 3,
            interval,
            last_interval: 1,
            factor: 2500,
            kind,
        }
    }
    fn card(kind: i64, events: Vec<Event>) -> Card {
        Card {
            id: stamp(1, 1),
            kind,
            queue: 2,
            due: 999,
            modified_secs: stamp(1, 1) / 1000,
            events,
        }
    }
    fn result(card: &Card) -> ResultKind {
        reconstruct(card, stamp(6, 4), 4).unwrap()
    }

    #[test]
    fn retains_missed_review_after_later_answer() {
        assert_eq!(
            result(&card(2, vec![event(1, 1, 3), event(6, 1, 10)])),
            ResultKind::Review
        );
        assert_eq!(
            result(&card(2, vec![event(1, 1, 10), event(12, 1, 20)])),
            ResultKind::NotDue
        );
    }
    #[test]
    fn unfinished_learning_and_interday_state() {
        assert_eq!(
            result(&card(2, vec![event(5, 0, -600), event(6, 0, 4)])),
            ResultKind::Learning
        );
        assert_eq!(
            result(&card(2, vec![event(4, 0, 1), event(6, 0, 4)])),
            ResultKind::Learning
        );
        assert_eq!(
            result(&card(2, vec![event(4, 0, 1), event(6, 1, 4)])),
            ResultKind::Review
        );
    }
    #[test]
    fn new_before_later_introduction_and_after_reset() {
        let mut first = event(6, 0, 1);
        first.last_interval = 0;
        assert_eq!(result(&card(2, vec![first])), ResultKind::New);
        let mut reset = event(4, 4, 0);
        reset.factor = 0;
        reset.ease = 0;
        assert_eq!(
            result(&card(2, vec![event(1, 1, 1), reset, event(6, 0, 1)])),
            ResultKind::New
        );
        assert_eq!(result(&card(0, vec![])), ResultKind::New);
    }
    #[test]
    fn manual_truncated_and_ambiguous_histories() {
        assert_eq!(
            result(&card(2, vec![event(4, 4, 5)])),
            ResultKind::Unresolved("manual_schedule")
        );
        assert_eq!(
            result(&card(2, vec![event(6, 1, 10)])),
            ResultKind::Unresolved("incomplete_log")
        );
        assert_eq!(
            result(&card(2, vec![event(4, 0, 1), event(6, 4, 4)])),
            ResultKind::Unresolved("ambiguous_state")
        );
    }
    #[test]
    fn fsrs_reschedule_anchors_to_last_answer() {
        let mut rescheduled = event(4, 5, 3);
        rescheduled.ease = 0;
        assert_eq!(
            result(&card(2, vec![event(1, 1, 10), rescheduled])),
            ResultKind::Review
        );
    }
    #[test]
    fn learning_fuzz_crossing_rollover_is_unresolved() {
        let mut learn = event(5, 0, -600);
        learn.id = stamp(6, 4) - 620_000;
        assert_eq!(
            result(&card(2, vec![learn, event(6, 0, 1)])),
            ResultKind::Unresolved("learning_rollover")
        );
    }

    #[test]
    fn historical_suspension_uses_dated_evidence_not_todays_queue() {
        for mut c in [
            card(0, vec![]),
            card(2, vec![event(1, 1, 3)]),
            card(1, vec![event(5, 0, -600)]),
            card(2, vec![event(4, 4, 5)]),
        ] {
            let scheduled = result(&c);
            c.queue = -1;
            c.modified_secs = stamp(5, 13) / 1000;
            assert!(suspension_state_is_known(&c, stamp(6, 4)));
            assert_eq!(result(&c), ResultKind::NotDue);
            // Suspending later cannot erase the earlier scheduled state.
            c.modified_secs = stamp(6, 13) / 1000;
            assert!(!suspension_state_is_known(&c, stamp(6, 4)));
            assert_eq!(result(&c), scheduled);
            // Unsuspending later does not prove it was active earlier, either.
            c.queue = 2;
            assert!(!suspension_state_is_known(&c, stamp(6, 4)));
        }
        let mut c = card(2, vec![event(1, 1, 3), event(6, 1, 10)]);
        c.queue = -1;
        assert!(!suspension_state_is_known(&c, stamp(6, 4)));
        assert_eq!(result(&c), ResultKind::Review);
        c.events.pop();
        c.modified_secs = stamp(6, 4) / 1000;
        assert!(!suspension_state_is_known(&c, stamp(6, 4)));
    }
    #[test]
    fn evidence_query_ignores_preview_and_keeps_relevant_events() {
        let db = rusqlite::Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE revlog(id INTEGER PRIMARY KEY,cid INTEGER,ease INTEGER,ivl INTEGER,lastIvl INTEGER,factor INTEGER,type INTEGER); CREATE INDEX ix_revlog_cid ON revlog(cid);
          INSERT INTO revlog VALUES(1,7,3,2,1,2500,1),(2,7,3,3,2,2500,1),(3,7,3,0,3,0,3),(4,7,3,4,3,2500,1),(5,8,3,2,1,2500,1);").unwrap();
        let mut stmt = db.prepare(&evidence_query(&[7])).unwrap();
        let ids = stmt
            .query_map([3], |r| r.get::<_, i64>(1))
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap();
        assert_eq!(ids, vec![1, 2, 4]);
    }

    #[test]
    fn real_upstream_collection_queries_are_read_only_and_scoped() {
        use anki::backend::init_backend;
        use anki_proto::{
            backend::BackendInit,
            cards::CardIds,
            collection::OpenCollectionRequest,
            generic::Empty,
            notes::{AddNoteRequest, AddNoteResponse, Note},
            notetypes::NotetypeId,
            scheduler::{
                card_answer::Rating, BuryOrSuspendCardsRequest, CardAnswer, GetQueuedCardsRequest,
                QueuedCards, ScheduleCardsAsNewRequest, SetDueDateRequest,
            },
        };
        // Compare every stored collection table, including text/blob fields.
        fn snapshot(backend: &Backend) -> Vec<Vec<u8>> {
            let request = |sql: String| {
                serde_json::to_vec(&serde_json::json!({"kind":"query", "sql":sql,
                    "args":[], "first_row_only":false}))
                .unwrap()
            };
            let names: Vec<Vec<String>> = serde_json::from_slice(&backend.run_db_command_bytes(
                &request("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name".into())
            ).unwrap()).unwrap();
            names
                .into_iter()
                .map(|row| {
                    backend
                        .run_db_command_bytes(&request(format!(
                            "SELECT * FROM \"{}\"",
                            row[0].replace('"', "\"\"")
                        )))
                        .unwrap()
                })
                .collect()
        }
        let dir = tempfile::tempdir().unwrap();
        let backend = init_backend(&BackendInit::default().encode_to_vec()).unwrap();
        engine_call::<Empty>(
            &backend,
            3,
            0,
            &OpenCollectionRequest {
                collection_path: dir
                    .path()
                    .join("collection.anki2")
                    .to_string_lossy()
                    .into_owned(),
                media_folder_path: dir.path().join("media").to_string_lossy().into_owned(),
                media_db_path: dir.path().join("media.db").to_string_lossy().into_owned(),
            }
            .encode_to_vec(),
        )
        .unwrap();
        let ntid = query(
            &backend,
            "SELECT id FROM notetypes ORDER BY id LIMIT 1",
            vec![],
        )
        .unwrap()[0][0];
        let mut note =
            engine_call::<Note>(&backend, 25, 0, &NotetypeId { ntid }.encode_to_vec()).unwrap();
        note.fields = vec!["history front".into(), "history back".into()];
        engine_call::<AddNoteResponse>(
            &backend,
            25,
            1,
            &AddNoteRequest {
                note: Some(note),
                deck_id: 1,
            }
            .encode_to_vec(),
        )
        .unwrap();
        let cid = query(&backend, "SELECT id FROM cards", vec![]).unwrap()[0][0];
        let end = Local::now().timestamp_millis() + 86_400_000;
        let payload = serde_json::json!({"scope_search":format!("cid:{cid}"),"day_end_ms":end,"rollover_hour":4});
        let before = snapshot(&backend);
        let history: serde_json::Value = serde_json::from_slice(
            &study_history(&backend, &serde_json::to_vec(&payload).unwrap()).unwrap(),
        )
        .unwrap();
        assert_eq!(history["new_candidate_ids"], serde_json::json!([cid]));
        assert_eq!(before, snapshot(&backend));
        engine_call::<Empty>(
            &backend,
            13,
            14,
            &BuryOrSuspendCardsRequest {
                card_ids: vec![cid],
                note_ids: vec![],
                mode: 0,
            }
            .encode_to_vec(),
        )
        .unwrap();
        let before = snapshot(&backend);
        let history: serde_json::Value = serde_json::from_slice(
            &study_history(&backend, &serde_json::to_vec(&payload).unwrap()).unwrap(),
        )
        .unwrap();
        assert_eq!(history["new_candidate_ids"], serde_json::json!([]));
        assert_eq!(before, snapshot(&backend));
        // The current suspension cannot be projected before its dated change.
        let early = serde_json::json!({"scope_search":format!("cid:{cid}"),"day_end_ms":cid+1,"rollover_hour":4});
        let history: serde_json::Value = serde_json::from_slice(
            &study_history(&backend, &serde_json::to_vec(&early).unwrap()).unwrap(),
        )
        .unwrap();
        assert_eq!(history["new_candidate_ids"], serde_json::json!([cid]));
        assert_eq!(history["suspension_unknown_ids"], serde_json::json!([cid]));
        assert_eq!(before, snapshot(&backend));
        engine_call::<Empty>(
            &backend,
            13,
            12,
            &CardIds { cids: vec![cid] }.encode_to_vec(),
        )
        .unwrap();
        let not_created = serde_json::json!({"scope_search":"","day_end_ms":cid,"rollover_hour":4});
        let history: serde_json::Value = serde_json::from_slice(
            &study_history(&backend, &serde_json::to_vec(&not_created).unwrap()).unwrap(),
        )
        .unwrap();
        assert_eq!(history["new_candidate_ids"], serde_json::json!([]));
        let queued = engine_call::<QueuedCards>(
            &backend,
            13,
            3,
            &GetQueuedCardsRequest {
                fetch_limit: 1,
                intraday_learning_only: false,
            }
            .encode_to_vec(),
        )
        .unwrap();
        let states = queued.cards[0].states.as_ref().unwrap();
        engine_call::<Empty>(
            &backend,
            13,
            4,
            &CardAnswer {
                card_id: cid,
                current_state: states.current.clone(),
                new_state: states.good.clone(),
                rating: Rating::Good as i32,
                answered_at_millis: Local::now().timestamp_millis(),
                milliseconds_taken: 1000,
            }
            .encode_to_vec(),
        )
        .unwrap();
        let before = snapshot(&backend);
        let history: serde_json::Value = serde_json::from_slice(
            &study_history(&backend, &serde_json::to_vec(&payload).unwrap()).unwrap(),
        )
        .unwrap();
        assert_eq!(history["learning_ids"], serde_json::json!([cid]));
        assert_eq!(before, snapshot(&backend));
        let empty = serde_json::json!({"scope_search":"cid:0","day_end_ms":end,"rollover_hour":4});
        let history: serde_json::Value = serde_json::from_slice(
            &study_history(&backend, &serde_json::to_vec(&empty).unwrap()).unwrap(),
        )
        .unwrap();
        assert_eq!(history["learning_ids"], serde_json::json!([]));

        engine_call::<Empty>(
            &backend,
            13,
            19,
            &SetDueDateRequest {
                card_ids: vec![cid],
                days: "7".into(),
                config_key: None,
            }
            .encode_to_vec(),
        )
        .unwrap();
        let history: serde_json::Value = serde_json::from_slice(
            &study_history(&backend, &serde_json::to_vec(&payload).unwrap()).unwrap(),
        )
        .unwrap();
        assert_eq!(
            history["unresolved"],
            serde_json::json!([{"card_id":cid,"reason":"manual_schedule"}])
        );
        engine_call::<Empty>(
            &backend,
            13,
            17,
            &ScheduleCardsAsNewRequest {
                card_ids: vec![cid],
                log: true,
                restore_position: true,
                reset_counts: true,
                context: None,
            }
            .encode_to_vec(),
        )
        .unwrap();
        let before = snapshot(&backend);
        let history: serde_json::Value = serde_json::from_slice(
            &study_history(&backend, &serde_json::to_vec(&payload).unwrap()).unwrap(),
        )
        .unwrap();
        assert_eq!(history["new_candidate_ids"], serde_json::json!([cid]));
        assert_eq!(before, snapshot(&backend));
    }

    #[test]
    fn rollover_and_dst_use_calendar_dates() {
        assert_eq!(day(stamp(6, 3), 4).unwrap(), day(stamp(5, 12), 4).unwrap());
        assert_ne!(day(stamp(6, 4), 4).unwrap(), day(stamp(5, 12), 4).unwrap());
        // Europe/Budapest's fall transition is 25 hours long. Calendar day
        // difference remains one; no elapsed-seconds division is involved.
        let a = stamp(24, 4);
        let b = stamp(25, 4);
        assert_eq!(
            day(b, 4)
                .unwrap()
                .signed_duration_since(day(a, 4).unwrap())
                .num_days(),
            1
        );
        assert_eq!(
            reconstruct(&card(2, vec![event(24, 1, 1)]), stamp(26, 4), 4).unwrap(),
            ResultKind::Review
        );
    }
}
