//! Past Anki days as the deck list would have shown them (aux method 8).
//!
//! For each requested day this returns three numbers per card kind:
//!
//! * **due** — the deck list's count at the start of the day: every card due
//!   that day, capped by that day's deck limits (new cards included, so
//!   `new` is `min(pool, new/day)` with the hierarchy applied exactly as
//!   `decks/tree.rs` does it).
//! * **studied** — answers recorded in the revlog for the day. Exact.
//! * **left** — the deck list's count at the end of the day: what was still
//!   due, capped by the limits that remained after the day's studying.
//!
//! A card's state at a moment comes from one of two sources. If the card row
//! has not changed since that moment, the row *is* that state. Otherwise the
//! revlog is replayed. Anything neither source can establish is counted, and
//! the day is reported as not exact, with the cause:
//!
//! * a card whose earlier schedule the log does not establish;
//! * a currently suspended card whose suspension cannot be dated;
//! * a deck where more was studied than today's options allow, which proves
//!   that day's options or limits differed from today's.
//!
//! Everything comes from the collection, so every device that syncs it
//! computes the same history, whatever app did the studying. Two inputs exist
//! only as they are now: deck membership (moves are not logged) and deck
//! options (only the current version is stored). The third check above is how
//! an options change shows up in the result.

use std::collections::HashMap;

use anki::backend::Backend;
use anki_proto::{deck_config, decks, generic, scheduler};
use chrono::{Local, NaiveDate, TimeZone, Timelike};
use prost::Message;
use serde::{Deserialize, Serialize};

use super::engine_call;

// Backend service/method indices (the generated `run_service_method` table).
const DECKS: u32 = 7;
const GET_DECK: u32 = 8;
const GET_DECK_NAMES: u32 = 13;
const CONFIG: u32 = 9;
const GET_CONFIG_JSON: u32 = 0;
const DECK_CONFIG: u32 = 11;
const GET_DECK_CONFIG: u32 = 1;
const SCHEDULER: u32 = 13;
const SCHED_TIMING_TODAY: u32 = 5;

#[derive(Deserialize)]
struct Request {
    /// 0 = whole collection; otherwise the deck whose subtree is in scope.
    #[serde(default)]
    deck_id: i64,
    rollover_hour: u32,
    days: Vec<DayRequest>,
    /// The day that also returns card IDs and per-deck rows.
    #[serde(default)]
    detail_offset: Option<i32>,
}

#[derive(Deserialize, Clone, Copy)]
struct DayRequest {
    /// Days before today (0 = today).
    offset: i32,
    /// UTC millis matching `revlog.id`. The end is the day's end, or now for
    /// a day still in progress.
    start_ms: i64,
    end_ms: i64,
}

#[derive(Default, Serialize, Clone, Copy, Debug, PartialEq)]
struct Counts {
    new: u32,
    learn: u32,
    review: u32,
}

#[derive(Default, Serialize, Debug)]
struct Studied {
    /// Cards introduced that day.
    new: u32,
    /// Cards whose first answer of the day was a learning or relearning step.
    learn: u32,
    /// Cards whose first answer of the day was a review.
    review: u32,
    cards: u32,
    answers: u32,
    millis: i64,
}

#[derive(Default, Serialize, Debug)]
struct Uncertain {
    incomplete_log: u32,
    manual_schedule: u32,
    ambiguous_state: u32,
    learning_rollover: u32,
    suspension_unknown: u32,
    /// Decks where more was studied than today's options allow.
    limits_exceeded: Vec<String>,
}

impl Uncertain {
    fn is_empty(&self) -> bool {
        self.incomplete_log == 0
            && self.manual_schedule == 0
            && self.ambiguous_state == 0
            && self.learning_rollover == 0
            && self.suspension_unknown == 0
            && self.limits_exceeded.is_empty()
    }
}

#[derive(Serialize)]
struct DeckRow {
    deck_id: i64,
    name: String,
    due: Counts,
    studied_cards: u32,
    left: Counts,
}

#[derive(Serialize)]
struct Detail {
    /// Uncapped: every learning/review card still due at the day's end.
    left_learning_ids: Vec<i64>,
    left_review_ids: Vec<i64>,
    decks: Vec<DeckRow>,
}

#[derive(Serialize)]
struct DayLedger {
    offset: i32,
    due: Counts,
    studied: Studied,
    left: Counts,
    uncertain: Uncertain,
    exact: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    detail: Option<Detail>,
}

#[derive(Serialize)]
struct Response {
    days: Vec<DayLedger>,
}

// MARK: - Card state

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
        self.ease > 0 && matches!(self.kind, 0..=3)
    }
}

#[derive(Clone, Copy, Debug)]
struct Answer {
    id: i64,
    kind: i64,
    millis: i64,
}

#[derive(Debug, Default)]
struct Card {
    id: i64,
    kind: i64,
    queue: i64,
    /// Home-deck due (`odue` for cards in a filtered deck).
    due: i64,
    modified_secs: i64,
    /// Home deck.
    deck: i64,
    /// Scheduling events, oldest first. Previews (filtered, no rescheduling)
    /// change nothing and are left out.
    events: Vec<Event>,
    /// Every answer, previews included, oldest first.
    answers: Vec<Answer>,
}

#[derive(Debug, PartialEq, Clone, Copy)]
enum State {
    New,
    LearnIntraday,
    LearnInterday,
    Review,
    NotDue,
    Unresolved(&'static str),
}

impl State {
    fn is_due(self) -> bool {
        !matches!(self, State::NotDue)
    }
}

/// A moment and the day it is judged against.
#[derive(Clone, Copy)]
struct Moment {
    /// State is taken from everything before this instant.
    at: i64,
    /// Learning due before this instant counts as due.
    until: i64,
    /// The Anki day, as a calendar date and as Anki's day number.
    date: NaiveDate,
    day_number: i64,
}

// Calendar dates, not elapsed 86400-second blocks: DST changes day length.
fn day(stamp_ms: i64, rollover: u32) -> Result<NaiveDate, String> {
    let dt = Local
        .timestamp_millis_opt(stamp_ms)
        .single()
        .ok_or_else(|| "study_ledger: invalid timestamp".to_string())?;
    let date = dt.date_naive();
    if dt.hour() < rollover {
        date.pred_opt()
            .ok_or_else(|| "study_ledger: date underflow".to_string())
    } else {
        Ok(date)
    }
}

/// True when nothing about the card changed at or after `at`, so its row is
/// its state at `at`. Card modifications have second precision.
fn unchanged_since(card: &Card, at: i64) -> bool {
    card.modified_secs > 0
        && card.modified_secs.saturating_add(1).saturating_mul(1000) <= at
        && card.events.last().is_none_or(|e| e.id < at)
}

fn from_row(card: &Card, m: Moment) -> State {
    let due_today = |due: i64| if due <= m.day_number { State::Review } else { State::NotDue };
    let learning = |due: i64| {
        // Intraday learning stores epoch seconds; interday stores a day.
        if due > 1_000_000_000 {
            if due.saturating_mul(1000) < m.until { State::LearnIntraday } else { State::NotDue }
        } else if due <= m.day_number {
            State::LearnInterday
        } else {
            State::NotDue
        }
    };
    match card.queue {
        -1 => State::NotDue,
        0 => State::New,
        1 | 3 => learning(card.due),
        2 => due_today(card.due),
        // Buried: the burial ends at the next rollover, so judge the type.
        _ => match card.kind {
            0 => State::New,
            2 => due_today(card.due),
            _ => learning(card.due),
        },
    }
}

fn from_log(card: &Card, m: Moment, rollover: u32) -> Result<State, String> {
    let split = card.events.partition_point(|e| e.id < m.at);
    let before = &card.events[..split];
    let after = card.events.get(split);
    let Some(last) = before.last() else {
        return Ok(match card.events.first() {
            Some(first) if first.kind == 0 && first.last_interval == 0 && first.ease > 0 => {
                State::New
            }
            None if card.kind == 0 => State::New,
            _ => State::Unresolved("incomplete_log"),
        });
    };
    if last.reset() {
        return Ok(State::New);
    }
    if last.kind == 4 || (last.ease == 0 && last.kind != 5) {
        return Ok(State::Unresolved("manual_schedule"));
    }
    let elapsed = |stamp: i64| -> Result<i64, String> {
        Ok(m.date.signed_duration_since(day(stamp, rollover)?).num_days())
    };
    if last.kind == 5 {
        // FSRS rescheduling measures its new interval from the last scheduling
        // answer, not from when the parameters changed.
        let reset = before.iter().rfind(|e| e.reset()).map(|e| e.id).unwrap_or(0);
        let Some(anchor) = before
            .iter()
            .rfind(|e| e.scheduling_answer() && e.id > reset)
        else {
            return Ok(State::Unresolved("incomplete_log"));
        };
        if last.interval <= 0 {
            return Ok(State::Unresolved("ambiguous_state"));
        }
        return Ok(if elapsed(anchor.id)? >= last.interval {
            State::Review
        } else {
            State::NotDue
        });
    }
    if last.interval < 0 {
        // The revlog records the nominal delay. Anki can fuzz intraday
        // learning by up to 25%, capped at five minutes, before persisting due.
        let delay = last.interval.saturating_neg();
        let nominal = last.id.saturating_add(delay.saturating_mul(1000));
        let latest = nominal.saturating_add((delay / 4).min(300) * 1000);
        if nominal >= m.until {
            return Ok(State::NotDue);
        }
        if latest >= m.until {
            // The stored due settles it only while this is still the latest
            // scheduling event and the card is still an intraday learner.
            if after.is_none() && card.queue == 1 && matches!(card.kind, 1 | 3) {
                return Ok(if card.due.saturating_mul(1000) < m.until {
                    State::LearnIntraday
                } else {
                    State::NotDue
                });
            }
            return Ok(State::Unresolved("learning_rollover"));
        }
        return Ok(State::LearnIntraday);
    }
    if last.interval == 0 {
        return Ok(State::Unresolved("ambiguous_state"));
    }
    if elapsed(last.id)? < last.interval {
        return Ok(State::NotDue);
    }
    // Positive intervals also occur in interday learning. The next scheduling
    // answer describes its input state; a manual event between them
    // invalidates that evidence. Current state is the fallback.
    Ok(match after {
        Some(e) if e.scheduling_answer() => match e.kind {
            0 | 2 => State::LearnInterday,
            1 | 3 => State::Review,
            _ => State::Unresolved("ambiguous_state"),
        },
        Some(_) => State::Unresolved("ambiguous_state"),
        None => match card.kind {
            1 | 3 => State::LearnInterday,
            2 => State::Review,
            _ => State::Unresolved("ambiguous_state"),
        },
    })
}

/// The card's state at `m`, and whether its suspension at `m` is unknown.
fn classify(card: &Card, m: Moment, rollover: u32) -> Result<(State, bool), String> {
    // A card added during the day belongs to that day's pool.
    if card.id >= m.until {
        return Ok((State::NotDue, false)); // not created yet
    }
    if unchanged_since(card, m.at) {
        return Ok((from_row(card, m), false));
    }
    let state = from_log(card, m, rollover)?;
    // Suspended now, changed since: it may have been suspended later.
    Ok((state, card.queue == -1 && state.is_due()))
}

// MARK: - Limits (mirrors decks/limits.rs and decks/tree.rs, v3)

#[derive(Clone, Copy, Debug)]
struct Remaining {
    review: u32,
    new: u32,
    cap_new_to_review: bool,
}

/// Upstream's `RemainingLimits::default`, the seed for global parent limits.
impl Default for Remaining {
    fn default() -> Self {
        Remaining { review: 9999, new: 9999, cap_new_to_review: false }
    }
}

impl Remaining {
    fn cap_to(&mut self, parent: Remaining) {
        self.review = self.review.min(parent.review);
        self.new = self.new.min(parent.new);
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct DayLimit {
    limit: u32,
    today: u32,
}

#[derive(Clone, Debug, Default)]
struct Limits {
    reviews_per_day: u32,
    new_per_day: u32,
    review_limit: Option<u32>,
    new_limit: Option<u32>,
    review_limit_today: Option<DayLimit>,
    new_limit_today: Option<DayLimit>,
}

impl Limits {
    /// `decks/limits.rs` `RemainingLimits::new_for_normal_deck_v3`.
    fn remaining(&self, day_number: u32, new_studied: u32, review_studied: u32, ignore_review_limit: bool) -> Remaining {
        let today = |l: Option<DayLimit>| l.and_then(|l| (l.today == day_number).then_some(l.limit));
        let mut review = today(self.review_limit_today)
            .or(self.review_limit)
            .unwrap_or(self.reviews_per_day) as i64;
        let mut new = today(self.new_limit_today)
            .or(self.new_limit)
            .unwrap_or(self.new_per_day) as i64;
        review -= review_studied as i64;
        new -= new_studied as i64;
        if !ignore_review_limit {
            review -= new_studied as i64;
            new = new.min(review);
        }
        Remaining {
            review: review.max(0) as u32,
            new: new.max(0) as u32,
            cap_new_to_review: !ignore_review_limit,
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct NodeCounts {
    new: u32,
    review: u32,
    intraday: u32,
    interday: u32,
}

impl NodeCounts {
    fn add(&mut self, other: NodeCounts) {
        self.new += other.new;
        self.review += other.review;
        self.intraday += other.intraday;
        self.interday += other.interday;
    }

    /// `decks/tree.rs` `NodeCountsV3::capped`.
    fn capped(self, remaining: &Remaining) -> Self {
        let mut c = self;
        c.interday = c.interday.min(remaining.review);
        let mut reviews_left = remaining.review.saturating_sub(c.interday);
        c.review = c.review.min(reviews_left);
        c.new = c.new.min(remaining.new);
        if remaining.cap_new_to_review {
            reviews_left = reviews_left.saturating_sub(c.review);
            c.new = c.new.min(reviews_left);
        }
        c
    }

    fn counts(self) -> Counts {
        Counts {
            new: self.new,
            learn: self.intraday + self.interday,
            review: self.review,
        }
    }

    fn record(&mut self, state: State) {
        match state {
            State::New => self.new += 1,
            State::LearnIntraday => self.intraday += 1,
            State::LearnInterday => self.interday += 1,
            State::Review => self.review += 1,
            State::NotDue | State::Unresolved(_) => {}
        }
    }
}

struct Tree {
    ids: Vec<i64>,
    names: Vec<String>,
    children: Vec<Vec<usize>>,
    roots: Vec<usize>,
    limits: Vec<Limits>,
}

impl Tree {
    fn build(entries: Vec<(i64, String)>, limits: HashMap<i64, Limits>) -> Self {
        let mut entries = entries;
        entries.sort_by(|a, b| a.1.cmp(&b.1));
        let index: HashMap<&str, usize> = entries
            .iter()
            .enumerate()
            .map(|(i, (_, name))| (name.as_str(), i))
            .collect();
        let mut children = vec![Vec::new(); entries.len()];
        let mut roots = Vec::new();
        for (i, (_, name)) in entries.iter().enumerate() {
            match name.rsplit_once("::").and_then(|(parent, _)| index.get(parent)) {
                Some(&parent) => children[parent].push(i),
                None => roots.push(i),
            }
        }
        Tree {
            limits: entries
                .iter()
                .map(|(id, _)| limits.get(id).cloned().unwrap_or_default())
                .collect(),
            ids: entries.iter().map(|(id, _)| *id).collect(),
            names: entries.into_iter().map(|(_, name)| name).collect(),
            children,
            roots,
        }
    }

    fn subtree(&self, node: usize, out: &mut Vec<usize>) {
        out.push(node);
        for &child in &self.children[node] {
            self.subtree(child, out);
        }
    }

    /// Per-node capped counts, `sum_counts_and_apply_limits_v3`.
    fn apply(
        &self,
        node: usize,
        own: &[NodeCounts],
        remaining: &[Remaining],
        parent: Option<Remaining>,
        out: &mut [NodeCounts],
    ) -> NodeCounts {
        let mut limit = remaining[node];
        let mut parent = parent;
        if let Some(p) = parent {
            limit.cap_to(p);
            parent = Some(limit);
        }
        let mut sum = own[node];
        for &child in &self.children[node] {
            sum.add(self.apply(child, own, remaining, parent, out));
        }
        let capped = sum.capped(&limit);
        out[node] = capped;
        capped
    }

    /// Start-of-day limit for each node after parents capped it.
    fn effective_start_limits(
        &self,
        node: usize,
        remaining: &[Remaining],
        parent: Option<Remaining>,
        out: &mut [Remaining],
    ) {
        let mut limit = remaining[node];
        let mut parent = parent;
        if let Some(p) = parent {
            limit.cap_to(p);
            parent = Some(limit);
        }
        out[node] = limit;
        for &child in &self.children[node] {
            self.effective_start_limits(child, remaining, parent, out);
        }
    }
}

// MARK: - Engine access

fn query(backend: &Backend, sql: &str, args: Vec<i64>) -> Result<Vec<Vec<serde_json::Value>>, String> {
    let request =
        serde_json::json!({"kind":"query", "sql":sql, "args":args, "first_row_only":false});
    let bytes = backend
        .run_db_command_bytes(&serde_json::to_vec(&request).map_err(|e| e.to_string())?)
        .map_err(|e| format!("study_ledger: database error ({} bytes)", e.len()))?;
    serde_json::from_slice(&bytes).map_err(|e| format!("study_ledger: invalid database result: {e}"))
}

fn int(row: &[serde_json::Value], i: usize) -> i64 {
    row.get(i).and_then(|v| v.as_i64()).unwrap_or(0)
}

fn config_bool(backend: &Backend, key: &str) -> bool {
    engine_call::<generic::Json>(
        backend,
        CONFIG,
        GET_CONFIG_JSON,
        &generic::String { val: key.to_string() }.encode_to_vec(),
    )
    .ok()
    .and_then(|json| serde_json::from_slice::<bool>(&json.json).ok())
    .unwrap_or(false)
}

fn load_limits(backend: &Backend, deck_ids: &[i64]) -> Result<HashMap<i64, Limits>, String> {
    let mut configs: HashMap<i64, (u32, u32)> = HashMap::new();
    let mut out = HashMap::new();
    for &did in deck_ids {
        let deck = engine_call::<decks::Deck>(backend, DECKS, GET_DECK, &decks::DeckId { did }.encode_to_vec())?;
        let Some(decks::deck::Kind::Normal(normal)) = deck.kind else { continue };
        let dcid = normal.config_id;
        let per_day = match configs.get(&dcid) {
            Some(&v) => v,
            None => {
                let conf = engine_call::<deck_config::DeckConfig>(
                    backend,
                    DECK_CONFIG,
                    GET_DECK_CONFIG,
                    &deck_config::DeckConfigId { dcid }.encode_to_vec(),
                )?;
                let inner = conf.config.unwrap_or_default();
                let v = (inner.reviews_per_day, inner.new_per_day);
                configs.insert(dcid, v);
                v
            }
        };
        let day_limit = |l: Option<decks::deck::normal::DayLimit>| l.map(|l| DayLimit { limit: l.limit, today: l.today });
        out.insert(
            did,
            Limits {
                reviews_per_day: per_day.0,
                new_per_day: per_day.1,
                review_limit: normal.review_limit,
                new_limit: normal.new_limit,
                review_limit_today: day_limit(normal.review_limit_today),
                new_limit_today: day_limit(normal.new_limit_today),
            },
        );
    }
    Ok(out)
}

fn load_cards(backend: &Backend, deck_ids: &[i64], until_ms: i64) -> Result<Vec<Card>, String> {
    let mut cards: Vec<Card> = Vec::new();
    let mut index: HashMap<i64, usize> = HashMap::new();
    for chunk in deck_ids.chunks(500) {
        let list = chunk.iter().map(i64::to_string).collect::<Vec<_>>().join(",");
        let rows = query(
            backend,
            &format!(
                "SELECT id,type,queue,CASE WHEN odid!=0 THEN odue ELSE due END,mod,\
                 CASE WHEN odid!=0 THEN odid ELSE did END AS home FROM cards \
                 WHERE id<?1 AND (CASE WHEN odid!=0 THEN odid ELSE did END) IN ({list})"
            ),
            vec![until_ms],
        )?;
        for r in rows {
            index.insert(int(&r, 0), cards.len());
            cards.push(Card {
                id: int(&r, 0),
                kind: int(&r, 1),
                queue: int(&r, 2),
                due: int(&r, 3),
                modified_secs: int(&r, 4),
                deck: int(&r, 5),
                ..Default::default()
            });
        }
    }
    if cards.is_empty() {
        return Ok(cards);
    }
    // One pass over the log; rows for cards out of scope are skipped.
    let rows = query(
        backend,
        "SELECT cid,id,ease,ivl,lastIvl,factor,type,time FROM revlog ORDER BY cid,id",
        vec![],
    )?;
    for r in rows {
        let Some(&i) = index.get(&int(&r, 0)) else { continue };
        let event = Event {
            id: int(&r, 1),
            ease: int(&r, 2),
            interval: int(&r, 3),
            last_interval: int(&r, 4),
            factor: int(&r, 5),
            kind: int(&r, 6),
        };
        if event.ease > 0 && matches!(event.kind, 0..=3) {
            cards[i].answers.push(Answer { id: event.id, kind: event.kind, millis: int(&r, 7) });
        }
        // A filtered-deck preview leaves the schedule untouched.
        if !(event.kind == 3 && event.factor == 0) {
            cards[i].events.push(event);
        }
    }
    Ok(cards)
}

// MARK: - Ledger

struct Collection {
    tree: Tree,
    ignore_review_limit: bool,
    apply_all_parent_limits: bool,
    days_elapsed: i64,
    rollover: u32,
}

/// Per-node counts of the cards in `cards`, by state at `m`.
fn tally(
    col: &Collection,
    cards: &[Card],
    deck_index: &HashMap<i64, usize>,
    m: Moment,
    uncertain: &mut Uncertain,
    states: &mut Vec<State>,
) -> Result<Vec<NodeCounts>, String> {
    let mut own = vec![NodeCounts::default(); col.tree.ids.len()];
    states.clear();
    for card in cards {
        let (state, suspension_unknown) = classify(card, m, col.rollover)?;
        states.push(state);
        if suspension_unknown {
            uncertain.suspension_unknown += 1;
        }
        match state {
            State::Unresolved("incomplete_log") => uncertain.incomplete_log += 1,
            State::Unresolved("manual_schedule") => uncertain.manual_schedule += 1,
            State::Unresolved("learning_rollover") => uncertain.learning_rollover += 1,
            State::Unresolved(_) => uncertain.ambiguous_state += 1,
            _ => {}
        }
        if let Some(&node) = deck_index.get(&card.deck) {
            own[node].record(state);
        }
    }
    Ok(own)
}

fn ledger_day(
    col: &Collection,
    cards: &[Card],
    deck_index: &HashMap<i64, usize>,
    scope: &[usize],
    day_req: DayRequest,
    detail: bool,
) -> Result<DayLedger, String> {
    let n = col.tree.ids.len();
    let date = day(day_req.start_ms, col.rollover)?;
    let day_number = col.days_elapsed - day_req.offset as i64;
    let day_u32 = day_number.max(0) as u32;
    let start = Moment { at: day_req.start_ms, until: day_req.end_ms, date, day_number };
    let end = Moment { at: day_req.end_ms, ..start };

    let mut uncertain = Uncertain::default();
    let mut start_states = Vec::with_capacity(cards.len());
    let mut end_states = Vec::with_capacity(cards.len());
    let own_start = tally(col, cards, deck_index, start, &mut uncertain, &mut start_states)?;
    // Count each card's uncertainty once: the end pass only adds new causes.
    let mut end_uncertain = Uncertain::default();
    let own_end = tally(col, cards, deck_index, end, &mut end_uncertain, &mut end_states)?;
    for (s, e) in start_states.iter().zip(&end_states) {
        if let (State::Unresolved(_), false) = (e, matches!(s, State::Unresolved(_))) {
            match e {
                State::Unresolved("incomplete_log") => uncertain.incomplete_log += 1,
                State::Unresolved("manual_schedule") => uncertain.manual_schedule += 1,
                State::Unresolved("learning_rollover") => uncertain.learning_rollover += 1,
                _ => uncertain.ambiguous_state += 1,
            }
        }
    }
    uncertain.suspension_unknown = uncertain.suspension_unknown.max(end_uncertain.suspension_unknown);

    // Studied: per node (counts roll up to parents, as in decks/stats.rs) and
    // for the scope.
    let mut node_new = vec![0u32; n];
    let mut node_review = vec![0u32; n];
    let mut studied = Studied::default();
    let mut studied_cards_by_node = vec![0u32; n];
    for card in cards {
        let lo = card.answers.partition_point(|a| a.id < day_req.start_ms);
        let hi = card.answers.partition_point(|a| a.id < day_req.end_ms);
        let today = &card.answers[lo..hi];
        let Some(first) = today.first() else { continue };
        let node = deck_index.get(&card.deck).copied();
        // Introduced: answered from the New queue — nothing scheduled it
        // since it was created or last reset.
        let introduced = today.iter().any(|a| {
            a.kind == 0
                && card.events[..card.events.partition_point(|e| e.id < a.id)]
                    .last()
                    .is_none_or(|e| e.reset())
        });
        // Answers from the Review or DayLearn queue consume the review limit;
        // filtered-deck answers do not touch the home deck's limits.
        let mut review_answers = 0u32;
        for answer in today {
            let from_review_queue = match answer.kind {
                1 => true,
                0 | 2 => {
                    // Interday learning: the previous step scheduled whole days.
                    let prior = card.events.partition_point(|e| e.id < answer.id);
                    card.events[..prior]
                        .last()
                        .is_some_and(|e| e.scheduling_answer() && e.interval > 0)
                }
                _ => false,
            };
            if from_review_queue {
                review_answers += 1;
            }
        }
        if let Some(node) = node {
            if introduced {
                node_new[node] += 1;
            }
            node_review[node] += review_answers;
            studied_cards_by_node[node] += 1;
        }
        if node.is_some_and(|i| scope.contains(&i)) {
            studied.cards += 1;
            studied.answers += today.len() as u32;
            studied.millis += today.iter().map(|a| a.millis).sum::<i64>();
            if introduced {
                studied.new += 1;
            } else if matches!(first.kind, 0 | 2) {
                studied.learn += 1;
            } else {
                studied.review += 1;
            }
        }
    }
    // Roll studied counts up to parents.
    let mut sub_new = vec![0u32; n];
    let mut sub_review = vec![0u32; n];
    let mut sub_cards = vec![0u32; n];
    for node in 0..n {
        let mut members = Vec::new();
        col.tree.subtree(node, &mut members);
        sub_new[node] = members.iter().map(|&i| node_new[i]).sum();
        sub_review[node] = members.iter().map(|&i| node_review[i]).sum();
        sub_cards[node] = members.iter().map(|&i| studied_cards_by_node[i]).sum();
    }

    let remaining = |new_s: &[u32], rev_s: &[u32]| -> Vec<Remaining> {
        (0..n)
            .map(|i| col.tree.limits[i].remaining(day_u32, new_s[i], rev_s[i], col.ignore_review_limit))
            .collect()
    };
    let zeros = vec![0u32; n];
    let start_limits = remaining(&zeros, &zeros);
    let end_limits = remaining(&sub_new, &sub_review);
    let parent = col.apply_all_parent_limits.then(Remaining::default);
    let mut due_nodes = vec![NodeCounts::default(); n];
    let mut left_nodes = vec![NodeCounts::default(); n];
    let mut effective = vec![Remaining::default(); n];
    for &root in &col.tree.roots {
        col.tree.apply(root, &own_start, &start_limits, parent, &mut due_nodes);
        col.tree.apply(root, &own_end, &end_limits, parent, &mut left_nodes);
        col.tree.effective_start_limits(root, &start_limits, parent, &mut effective);
    }

    // Scope roots: the chosen deck, or every top-level deck.
    let scope_roots: Vec<usize> = scope
        .iter()
        .copied()
        .filter(|&i| !scope.iter().any(|&p| col.tree.children[p].contains(&i)))
        .collect();
    let sum = |nodes: &[NodeCounts]| {
        let mut total = NodeCounts::default();
        for &r in &scope_roots {
            total.add(nodes[r]);
        }
        total.counts()
    };

    for &i in scope {
        if sub_new[i] > effective[i].new || sub_review[i] > effective[i].review {
            uncertain.limits_exceeded.push(col.tree.names[i].clone());
        }
    }

    let detail = detail.then(|| {
        let in_scope = |card: &Card| deck_index.get(&card.deck).is_some_and(|i| scope.contains(i));
        let ids = |want: &dyn Fn(State) -> bool| {
            cards
                .iter()
                .zip(&end_states)
                .filter(|(c, s)| want(**s) && in_scope(c))
                .map(|(c, _)| c.id)
                .collect::<Vec<_>>()
        };
        let rows_for: Vec<usize> = if scope_roots.len() == 1 && !col.tree.children[scope_roots[0]].is_empty() {
            col.tree.children[scope_roots[0]].clone()
        } else {
            scope_roots.clone()
        };
        Detail {
            left_learning_ids: ids(&|s| matches!(s, State::LearnIntraday | State::LearnInterday)),
            left_review_ids: ids(&|s| s == State::Review),
            decks: rows_for
                .into_iter()
                .map(|i| DeckRow {
                    deck_id: col.tree.ids[i],
                    name: col.tree.names[i].rsplit("::").next().unwrap_or_default().to_string(),
                    due: due_nodes[i].counts(),
                    studied_cards: sub_cards[i],
                    left: left_nodes[i].counts(),
                })
                .collect(),
        }
    });

    Ok(DayLedger {
        offset: day_req.offset,
        due: sum(&due_nodes),
        studied,
        left: sum(&left_nodes),
        exact: uncertain.is_empty(),
        uncertain,
        detail,
    })
}

pub(crate) fn study_ledger(backend: &Backend, input: &[u8]) -> Result<Vec<u8>, String> {
    let req: Request = serde_json::from_slice(input).map_err(|e| format!("bad request json: {e}"))?;
    if req.rollover_hour > 23 {
        return Err("study_ledger: invalid rollover hour".to_string());
    }
    if req.days.iter().any(|d| d.end_ms <= d.start_ms) {
        return Err("study_ledger: each day must end after it starts".to_string());
    }
    let names = engine_call::<decks::DeckNames>(
        backend,
        DECKS,
        GET_DECK_NAMES,
        &decks::GetDeckNamesRequest { skip_empty_default: false, include_filtered: false }.encode_to_vec(),
    )?;
    let entries: Vec<(i64, String)> = names.entries.into_iter().map(|e| (e.id, e.name)).collect();
    let all_ids: Vec<i64> = entries.iter().map(|e| e.0).collect();
    let limits = load_limits(backend, &all_ids)?;
    let timing = engine_call::<scheduler::SchedTimingTodayResponse>(
        backend,
        SCHEDULER,
        SCHED_TIMING_TODAY,
        &generic::Empty {}.encode_to_vec(),
    )?;
    let col = Collection {
        tree: Tree::build(entries, limits),
        ignore_review_limit: config_bool(backend, "newCardsIgnoreReviewLimit"),
        apply_all_parent_limits: config_bool(backend, "applyAllParentLimits"),
        days_elapsed: timing.days_elapsed as i64,
        rollover: req.rollover_hour,
    };

    let scope: Vec<usize> = if req.deck_id == 0 {
        (0..col.tree.ids.len()).collect()
    } else {
        let root = col
            .tree
            .ids
            .iter()
            .position(|&id| id == req.deck_id)
            .ok_or_else(|| "study_ledger: deck not found".to_string())?;
        let mut members = Vec::new();
        col.tree.subtree(root, &mut members);
        members
    };
    let scope_ids: Vec<i64> = scope.iter().map(|&i| col.tree.ids[i]).collect();
    let until = req.days.iter().map(|d| d.end_ms).max().unwrap_or(0);
    let cards = load_cards(backend, &scope_ids, until)?;
    let deck_index: HashMap<i64, usize> = col.tree.ids.iter().enumerate().map(|(i, &id)| (id, i)).collect();

    let days = req
        .days
        .iter()
        .map(|&d| ledger_day(&col, &cards, &deck_index, &scope, d, req.detail_offset == Some(d.offset)))
        .collect::<Result<Vec<_>, _>>()?;
    serde_json::to_vec(&Response { days }).map_err(|e| e.to_string())
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
        Event { id: stamp(day, 12), ease: 3, interval, last_interval: 1, factor: 2500, kind }
    }
    fn card(kind: i64, events: Vec<Event>) -> Card {
        Card {
            id: stamp(1, 1),
            kind,
            queue: 2,
            due: 999,
            // Changed after every moment these tests judge, so the log decides.
            modified_secs: stamp(30, 1) / 1000,
            events,
            ..Default::default()
        }
    }
    /// Start of 6 Oct (rollover 4am), with the whole day for learning.
    fn moment(at: i64) -> Moment {
        Moment { at, until: stamp(7, 4), date: day(stamp(6, 12), 4).unwrap(), day_number: 100 }
    }
    fn result(card: &Card) -> State {
        classify(card, moment(stamp(6, 4)), 4).unwrap().0
    }

    #[test]
    fn review_due_that_day_counts_even_when_answered_later() {
        assert_eq!(result(&card(2, vec![event(1, 1, 5), event(6, 1, 10)])), State::Review);
        assert_eq!(result(&card(2, vec![event(1, 1, 10), event(12, 1, 20)])), State::NotDue);
        // Due on the day itself, not only overdue.
        assert_eq!(result(&card(2, vec![event(5, 1, 1)])), State::Review);
    }

    #[test]
    fn learning_is_split_into_intraday_and_interday() {
        // Due at 12:10 on the 6th: inside the day.
        let mut step = event(6, 0, -600);
        step.id = stamp(6, 3);
        assert_eq!(result(&card(1, vec![step])), State::LearnIntraday);
        assert_eq!(result(&card(2, vec![event(4, 0, 1), event(7, 0, 4)])), State::LearnInterday);
        assert_eq!(result(&card(2, vec![event(4, 0, 1), event(7, 1, 4)])), State::Review);
    }

    #[test]
    fn new_until_first_answer_and_after_reset() {
        let mut first = event(6, 0, 1);
        first.last_interval = 0;
        assert_eq!(result(&card(2, vec![first])), State::New);
        let mut reset = event(4, 4, 0);
        reset.factor = 0;
        reset.ease = 0;
        assert_eq!(result(&card(2, vec![event(1, 1, 1), reset, event(7, 0, 1)])), State::New);
        assert_eq!(result(&card(0, vec![])), State::New);
    }

    #[test]
    fn unchanged_row_is_the_state_at_that_moment() {
        // Imported with a schedule and never touched since: no log needed.
        let mut c = card(2, vec![]);
        c.modified_secs = stamp(2, 12) / 1000;
        c.due = 100;
        assert_eq!(result(&c), State::Review);
        c.due = 101;
        assert_eq!(result(&c), State::NotDue);
        // Suspended before the day and never changed since: known.
        c.queue = -1;
        assert_eq!(classify(&c, moment(stamp(6, 4)), 4).unwrap(), (State::NotDue, false));
        // Set-due-date with nothing after it is exact from the row.
        let mut manual = card(2, vec![event(3, 4, 5)]);
        manual.modified_secs = stamp(3, 13) / 1000;
        manual.due = 99;
        assert_eq!(result(&manual), State::Review);
    }

    #[test]
    fn later_suspension_is_flagged_not_assumed() {
        let mut c = card(2, vec![event(1, 1, 3)]);
        c.queue = -1;
        assert_eq!(classify(&c, moment(stamp(6, 4)), 4).unwrap(), (State::Review, true));
    }

    #[test]
    fn cards_join_the_pool_on_the_day_they_are_created() {
        let mut c = card(0, vec![]);
        c.id = stamp(6, 9);
        assert_eq!(result(&c), State::New);
        c.id = stamp(7, 9);
        assert_eq!(result(&c), State::NotDue);
    }

    #[test]
    fn manual_and_truncated_logs_are_unresolved() {
        assert_eq!(result(&card(2, vec![event(4, 4, 5)])), State::Unresolved("manual_schedule"));
        assert_eq!(result(&card(2, vec![event(7, 1, 10)])), State::Unresolved("incomplete_log"));
    }

    #[test]
    fn fsrs_reschedule_anchors_to_last_answer() {
        let mut rescheduled = event(4, 5, 3);
        rescheduled.ease = 0;
        assert_eq!(result(&card(2, vec![event(1, 1, 10), rescheduled])), State::Review);
    }

    fn limits(new: u32, review: u32) -> Limits {
        Limits { new_per_day: new, reviews_per_day: review, ..Default::default() }
    }

    #[test]
    fn nested_new_limits_match_upstream_tree_test() {
        // decks/tree.rs `nested_counts_v3`: parent 8, child 4, grandchildren
        // 2 and 1, each deck holding 10 new cards.
        let entries = vec![
            (1, "Default".to_string()),
            (2, "Default::child".to_string()),
            (3, "Default::child::grandchild_1".to_string()),
            (4, "Default::child::grandchild_2".to_string()),
        ];
        let lim = HashMap::from([(1, limits(8, 9999)), (2, limits(4, 9999)), (3, limits(2, 9999)), (4, limits(1, 9999))]);
        let tree = Tree::build(entries, lim);
        let own = vec![NodeCounts { new: 10, ..Default::default() }; 4];
        let remaining: Vec<Remaining> = tree.limits.iter().map(|l| l.remaining(0, 0, 0, false)).collect();
        let mut out = vec![NodeCounts::default(); 4];
        tree.apply(tree.roots[0], &own, &remaining, None, &mut out);
        let by_name = |n: &str| out[tree.names.iter().position(|x| x == n).unwrap()].new;
        assert_eq!(by_name("Default::child::grandchild_1"), 2);
        assert_eq!(by_name("Default::child::grandchild_2"), 1);
        assert_eq!(by_name("Default::child"), 4);
        assert_eq!(by_name("Default"), 8);
    }

    #[test]
    fn remaining_limits_follow_v3_rules() {
        let mut l = limits(20, 200);
        l.new_limit_today = Some(DayLimit { limit: 5, today: 7 });
        // The today-only new limit applies on its day only.
        assert_eq!(l.remaining(7, 0, 0, false).new, 5);
        assert_eq!(l.remaining(8, 0, 0, false).new, 20);
        // Studied cards are subtracted; new cards also consume the review limit.
        let r = limits(20, 30).remaining(1, 15, 10, false);
        assert_eq!((r.new, r.review), (5, 5));
        let r = limits(20, 30).remaining(1, 15, 10, true);
        assert_eq!((r.new, r.review), (5, 20));
    }

    /// Today reconstructed from the log must equal the engine's own deck
    /// list right now, and computing it must not write to the collection.
    #[test]
    fn today_matches_the_engines_deck_tree() {
        use anki::backend::init_backend;
        use anki_proto::{
            backend::BackendInit,
            collection::OpenCollectionRequest,
            notes::{AddNoteRequest, AddNoteResponse, Note},
            notetypes::NotetypeId,
            scheduler::{card_answer::Rating, CardAnswer, GetQueuedCardsRequest, QueuedCards},
        };
        fn dump(backend: &Backend) -> Vec<Vec<Vec<serde_json::Value>>> {
            let tables = query(backend, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name", vec![]).unwrap();
            tables
                .iter()
                .map(|t| query(backend, &format!("SELECT * FROM \"{}\"", t[0].as_str().unwrap()), vec![]).unwrap())
                .collect()
        }
        let dir = tempfile::tempdir().unwrap();
        let backend = init_backend(&BackendInit::default().encode_to_vec()).unwrap();
        engine_call::<generic::Empty>(
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
        let ntid = int(&query(&backend, "SELECT id FROM notetypes ORDER BY id LIMIT 1", vec![]).unwrap()[0], 0);
        for i in 0..30 {
            let mut note = engine_call::<Note>(&backend, 25, 0, &NotetypeId { ntid }.encode_to_vec()).unwrap();
            note.fields = vec![format!("front {i}"), "back".into()];
            let _ = engine_call::<AddNoteResponse>(
                &backend,
                25,
                1,
                &AddNoteRequest { note: Some(note), deck_id: 1 }.encode_to_vec(),
            )
            .unwrap();
        }
        let queued = engine_call::<QueuedCards>(
            &backend,
            13,
            3,
            &GetQueuedCardsRequest { fetch_limit: 5, intraday_learning_only: false }.encode_to_vec(),
        )
        .unwrap();
        for (i, q) in queued.cards.iter().enumerate() {
            let card = q.card.as_ref().unwrap();
            let states = q.states.as_ref().unwrap();
            let (rating, state) = if i < 3 {
                (Rating::Good, states.good.clone())
            } else {
                (Rating::Easy, states.easy.clone())
            };
            let _ = engine_call::<anki_proto::collection::OpChanges>(
                &backend,
                13,
                4,
                &CardAnswer {
                    card_id: card.id,
                    current_state: states.current.clone(),
                    new_state: state,
                    rating: rating as i32,
                    answered_at_millis: Local::now().timestamp_millis(),
                    milliseconds_taken: 2000,
                }
                .encode_to_vec(),
            )
            .unwrap();
        }

        let timing = engine_call::<scheduler::SchedTimingTodayResponse>(
            &backend, SCHEDULER, SCHED_TIMING_TODAY, &generic::Empty {}.encode_to_vec(),
        )
        .unwrap();
        let now = Local::now().timestamp_millis();
        let start = (timing.next_day_at - 86_400) * 1000;
        // The deck list looks 20 minutes ahead for learning cards.
        let request = serde_json::json!({
            "deck_id": 0, "rollover_hour": 4, "detail_offset": 0,
            "days": [{"offset": 0, "start_ms": start, "end_ms": now + 1_200_000}],
        });
        let before = dump(&backend);
        let out: serde_json::Value =
            serde_json::from_slice(&study_ledger(&backend, &serde_json::to_vec(&request).unwrap()).unwrap()).unwrap();
        assert_eq!(before, dump(&backend), "the ledger must not write");
        let ledger = &out["days"][0];

        let tree = engine_call::<decks::DeckTreeNode>(
            &backend,
            DECKS,
            4,
            &decks::DeckTreeRequest { now: now / 1000 }.encode_to_vec(),
        )
        .unwrap();
        let (mut new, mut learn, mut review) = (0, 0, 0);
        for child in &tree.children {
            new += child.new_count;
            learn += child.learn_count;
            review += child.review_count;
        }
        assert_eq!(ledger["left"], serde_json::json!({"new": new, "learn": learn, "review": review}));
        assert_eq!(ledger["left"], serde_json::json!({"new": 15, "learn": 3, "review": 0}));
        assert_eq!(ledger["due"], serde_json::json!({"new": 20, "learn": 0, "review": 0}));
        assert_eq!(ledger["studied"]["new"], 5);
        assert_eq!(ledger["studied"]["cards"], 5);
        assert_eq!(ledger["studied"]["millis"], 10_000);
        assert_eq!(ledger["exact"], true);
        assert_eq!(ledger["detail"]["left_learning_ids"].as_array().unwrap().len(), 3);
    }

    #[test]
    fn rollover_and_dst_use_calendar_dates() {
        assert_eq!(day(stamp(6, 3), 4).unwrap(), day(stamp(5, 12), 4).unwrap());
        assert_ne!(day(stamp(6, 4), 4).unwrap(), day(stamp(5, 12), 4).unwrap());
        let a = stamp(24, 4);
        let b = stamp(25, 4);
        assert_eq!(day(b, 4).unwrap().signed_duration_since(day(a, 4).unwrap()).num_days(), 1);
    }
}
