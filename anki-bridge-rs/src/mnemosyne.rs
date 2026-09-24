use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::Path;

use anki::backend::Backend;
use prost::Message;
use regex::Regex;
use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
struct InspectMnemosyneRequest {
    path: String,
}

#[derive(Deserialize)]
struct ImportMnemosyneRequest {
    path: String,
    deck_name: String,
}

#[derive(Serialize, Debug, PartialEq, Eq)]
struct MnemosyneInspection {
    version: String,
    note_count: u64,
    card_count: u64,
    fact_view_counts: BTreeMap<String, u64>,
}

/// Read facts and card view counts without modifying the Mnemosyne database.
pub(super) fn inspect(input: &[u8]) -> Result<Vec<u8>, String> {
    let request: InspectMnemosyneRequest =
        serde_json::from_slice(input).map_err(|err| format!("bad request json: {err}"))?;
    let connection = open_mnemosyne_read_only(&request.path)?;
    let version = read_version(&connection)?;

    let note_count = count_rows(&connection, "SELECT COUNT(*) FROM facts", "facts")?;
    let card_count = count_rows(&connection, "SELECT COUNT(*) FROM cards", "cards")?;
    let mut fact_view_counts = BTreeMap::new();
    {
        let mut statement = connection
            .prepare("SELECT fact_view_id, COUNT(*) FROM cards GROUP BY fact_view_id")
            .map_err(|err| format!("could not inspect Mnemosyne fact views: {err}"))?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            })
            .map_err(|err| format!("could not inspect Mnemosyne fact views: {err}"))?;
        for row in rows {
            let (fact_view_id, count) =
                row.map_err(|err| format!("could not inspect Mnemosyne fact views: {err}"))?;
            let count = u64::try_from(count).map_err(|_| {
                format!("Mnemosyne fact view {fact_view_id} has an invalid card count: {count}")
            })?;
            fact_view_counts.insert(fact_view_id, count);
        }
    }

    let inspection = MnemosyneInspection {
        version,
        note_count,
        card_count,
        fact_view_counts,
    };
    serde_json::to_vec(&inspection).map_err(|err| format!("encode failed: {err}"))
}

/// Convert a Mnemosyne database to Anki's ForeignData JSON and invoke the
/// upstream JSON importer.
pub(super) fn import_mnemosyne(backend: &Backend, input: &[u8]) -> Result<Vec<u8>, String> {
    let request: ImportMnemosyneRequest =
        serde_json::from_slice(input).map_err(|err| format!("bad request json: {err}"))?;
    let connection = open_mnemosyne_read_only(&request.path)?;
    // Match upstream's schema probe. Unknown versions are intentionally still
    // imported, but a missing/unreadable version is an invalid database.
    let _ = read_version(&connection)?;
    let foreign_data = gather_foreign_data(&connection, &request.deck_name)?;
    drop(connection);
    let json = serde_json::to_string(&foreign_data)
        .map_err(|err| format!("could not encode Mnemosyne ForeignData JSON: {err}"))?;
    let engine_request = anki_proto::generic::String { val: json };
    // ImportExportService (39), ImportJsonString (10).
    let response = super::engine_call::<anki_proto::import_export::ImportResponse>(
        backend,
        39,
        10,
        &engine_request.encode_to_vec(),
    )?;
    Ok(response.encode_to_vec())
}

fn open_mnemosyne_read_only(path: &str) -> Result<Connection, String> {
    let source = Path::new(path);
    let metadata = fs::metadata(source).map_err(|err| {
        if err.kind() == std::io::ErrorKind::NotFound {
            format!("Mnemosyne database not found: {path}")
        } else {
            format!("could not inspect Mnemosyne database {path}: {err}")
        }
    })?;
    if !metadata.is_file() {
        return Err(format!("Mnemosyne database is not a file: {path}"));
    }
    Connection::open_with_flags(
        source,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|err| format!("file is not a readable Mnemosyne SQLite database: {err}"))
}

fn read_version(connection: &Connection) -> Result<String, String> {
    connection
        .query_row(
            "SELECT value FROM global_variables WHERE key = 'version' LIMIT 1",
            [],
            |row| row.get(0),
        )
        .optional()
        .map_err(|err| format!("could not read Mnemosyne version: {err}"))?
        .ok_or_else(|| "Mnemosyne database is missing global_variables.version".to_string())
}

fn count_rows(connection: &Connection, sql: &str, description: &str) -> Result<u64, String> {
    let count: i64 = connection
        .query_row(sql, [], |row| row.get(0))
        .map_err(|err| format!("could not inspect Mnemosyne {description}: {err}"))?;
    u64::try_from(count)
        .map_err(|_| format!("Mnemosyne {description} has an invalid count: {count}"))
}

struct MnemoFact {
    id: i64,
    fields: HashMap<String, String>,
    cards: Vec<MnemoCard>,
}

struct MnemoCard {
    fact_id: i64,
    fact_view_id: String,
    tags: Option<String>,
    next_rep: i64,
    last_rep: i64,
    easiness: f64,
    acq_reps: i64,
    ret_reps: i64,
    lapses: i64,
    ord: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FactView {
    FrontOnly,
    FrontBack,
    Vocabulary,
    Cloze,
}

impl FactView {
    fn from_fact_view_id(fact_id: i64, id: &str) -> Result<Self, String> {
        if id.starts_with("1.") || id.starts_with("1::") {
            Ok(Self::FrontOnly)
        } else if id.starts_with("2.") || id.starts_with("2::") {
            Ok(Self::FrontBack)
        } else if id.starts_with("3.") || id.starts_with("3::") {
            Ok(Self::Vocabulary)
        } else if id.starts_with("5.1") || id.starts_with("5::1") {
            Ok(Self::Cloze)
        } else {
            Err(format!(
                "Mnemosyne fact {fact_id} has unknown fact view: {id}"
            ))
        }
    }

    fn notetype(self) -> &'static str {
        match self {
            Self::FrontOnly => "Mnemosyne-FrontOnly",
            Self::FrontBack => "Mnemosyne-FrontBack",
            Self::Vocabulary => "Mnemosyne-Vocabulary",
            Self::Cloze => "Mnemosyne-Cloze",
        }
    }

    fn field_keys(self) -> &'static [&'static str] {
        match self {
            Self::FrontOnly | Self::FrontBack => &["f", "b"],
            Self::Vocabulary => &["f", "p_1", "m_1", "n"],
            Self::Cloze => &["text"],
        }
    }

    fn notetype_definition(self) -> ForeignNotetype {
        let fields: Vec<&str> = match self {
            Self::FrontOnly | Self::FrontBack => vec!["Front", "Back"],
            Self::Vocabulary => vec!["Expression", "Pronunciation", "Meaning", "Notes"],
            Self::Cloze => vec!["Text", "Back Extra"],
        };
        let templates = match self {
            Self::FrontOnly => vec![ForeignTemplate {
                name: "Card 1".to_string(),
                qfmt: "{{Front}}".to_string(),
                afmt: "{{FrontSide}}\n\n<hr id=answer>\n\n{{Back}}".to_string(),
            }],
            Self::FrontBack => vec![
                ForeignTemplate {
                    name: "Card 1".to_string(),
                    qfmt: "{{Front}}".to_string(),
                    afmt: "{{FrontSide}}\n\n<hr id=answer>\n\n{{Back}}".to_string(),
                },
                ForeignTemplate {
                    name: "Card 2".to_string(),
                    qfmt: "{{Back}}".to_string(),
                    afmt: "{{FrontSide}}\n\n<hr id=answer>\n\n{{Front}}".to_string(),
                },
            ],
            Self::Vocabulary => vec![
                ForeignTemplate {
                    name: "Recognition".to_string(),
                    qfmt: "{{Expression}}".to_string(),
                    afmt: "{{Expression}}\n\n<hr id=answer>\n\n{{Pronunciation}}<br>\n{{Meaning}}<br>\n{{Notes}}"
                        .to_string(),
                },
                ForeignTemplate {
                    name: "Production".to_string(),
                    qfmt: "{{Meaning}}".to_string(),
                    afmt: "{{Meaning}}\n\n<hr id=answer>\n\n{{Expression}}".to_string(),
                },
            ],
            Self::Cloze => vec![ForeignTemplate {
                name: "Cloze".to_string(),
                qfmt: "{{cloze:Text}}".to_string(),
                afmt: "{{cloze:Text}}<br>\n{{Back Extra}}".to_string(),
            }],
        };
        ForeignNotetype {
            name: self.notetype().to_string(),
            fields: fields.into_iter().map(str::to_string).collect(),
            templates,
            is_cloze: self == Self::Cloze,
        }
    }
}

struct FieldMunger {
    newline: Regex,
    latex: Regex,
    audio: Regex,
}

impl FieldMunger {
    fn new() -> Result<Self, String> {
        Ok(Self {
            newline: Regex::new(r"\r?\n")
                .map_err(|err| format!("could not initialize newline field conversion: {err}"))?,
            latex: Regex::new(r"(?i)<(/?(?:\$\$|\$|latex))>")
                .map_err(|err| format!("could not initialize LaTeX field conversion: {err}"))?,
            audio: Regex::new(r#"<audio src="(.+?)">(?:</audio>)?"#)
                .map_err(|err| format!("could not initialize audio field conversion: {err}"))?,
        })
    }

    fn munge<'a>(&'a self, field: &'a str) -> String {
        let field = self.newline.replace_all(field, "<br>");
        let field = self.latex.replace_all(&field, "[$1]");
        self.audio.replace_all(&field, "[sound:$1]").into_owned()
    }
}

#[derive(Serialize, Debug, PartialEq)]
struct ForeignData {
    notes: Vec<ForeignNote>,
    notetypes: Vec<ForeignNotetype>,
    default_deck: String,
}

#[derive(Serialize, Debug, PartialEq)]
struct ForeignNote {
    fields: Vec<String>,
    tags: Vec<String>,
    notetype: String,
    deck: String,
    cards: Vec<ForeignCard>,
}

#[derive(Serialize, Debug, PartialEq)]
struct ForeignCard {
    due: i64,
    interval: u32,
    ease_factor: f32,
    reps: u32,
    lapses: u32,
}

#[derive(Serialize, Debug, PartialEq, Eq)]
struct ForeignNotetype {
    name: String,
    fields: Vec<String>,
    templates: Vec<ForeignTemplate>,
    is_cloze: bool,
}

#[derive(Serialize, Debug, PartialEq, Eq)]
struct ForeignTemplate {
    name: String,
    qfmt: String,
    afmt: String,
}

fn gather_foreign_data(connection: &Connection, deck_name: &str) -> Result<ForeignData, String> {
    let munger = FieldMunger::new()?;
    let mut facts: Vec<MnemoFact> = Vec::new();
    let mut fact_indexes = HashMap::<i64, usize>::new();
    {
        let mut statement = connection
            .prepare(
                "SELECT facts._id, data_for_fact.key, data_for_fact.value
                 FROM facts, data_for_fact
                 WHERE facts._id = data_for_fact._fact_id",
            )
            .map_err(|err| format!("could not read Mnemosyne facts: {err}"))?;
        let rows = statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .map_err(|err| format!("could not read Mnemosyne facts: {err}"))?;
        for row in rows {
            let (fact_id, key, value) =
                row.map_err(|err| format!("could not read Mnemosyne fact data: {err}"))?;
            let index = *fact_indexes.entry(fact_id).or_insert_with(|| {
                facts.push(MnemoFact {
                    id: fact_id,
                    fields: HashMap::new(),
                    cards: Vec::new(),
                });
                facts.len() - 1
            });
            facts[index].fields.insert(key, value);
        }
    }

    {
        let mut statement = connection
            .prepare(
                "SELECT _fact_id, fact_view_id, tags, next_rep, last_rep, easiness,
                        acq_reps, ret_reps, lapses
                 FROM cards",
            )
            .map_err(|err| format!("could not read Mnemosyne cards: {err}"))?;
        let rows = statement
            .query_map([], |row| {
                Ok(MnemoCard {
                    fact_id: row.get(0)?,
                    fact_view_id: row.get(1)?,
                    tags: row.get(2)?,
                    next_rep: row.get(3)?,
                    last_rep: row.get(4)?,
                    easiness: row.get(5)?,
                    acq_reps: row.get(6)?,
                    ret_reps: row.get(7)?,
                    lapses: row.get(8)?,
                    ord: 0,
                })
            })
            .map_err(|err| format!("could not read Mnemosyne cards: {err}"))?;
        for row in rows {
            let card = row.map_err(|err| format!("could not read Mnemosyne card: {err}"))?;
            let fact_index = fact_indexes.get(&card.fact_id).copied().ok_or_else(|| {
                format!("Mnemosyne card references missing fact {}", card.fact_id)
            })?;
            facts[fact_index].cards.push(card);
        }
    }

    let mut notes = Vec::with_capacity(facts.len());
    let mut used_fact_views = Vec::<FactView>::new();
    for fact in facts {
        let fact_id = fact.id;
        let mut cards = fact.cards;
        for card in &mut cards {
            card.ord = card_ord(&card.fact_view_id)?;
        }
        cards.sort_by_key(|card| card.ord);

        let fact_view = match cards.first() {
            Some(card) => FactView::from_fact_view_id(fact_id, &card.fact_view_id)?,
            None => FactView::FrontOnly,
        };
        if !used_fact_views.contains(&fact_view) {
            used_fact_views.push(fact_view);
        }

        let fields = fact_view
            .field_keys()
            .iter()
            .map(|key| munger.munge(fact.fields.get(*key).map(String::as_str).unwrap_or("")))
            .collect();
        let mut tags = Vec::new();
        for card in &cards {
            if let Some(raw_tags) = card.tags.as_deref().filter(|tags| !tags.is_empty()) {
                tags.extend(
                    raw_tags
                        .split(", ")
                        .map(|tag| tag.replace([' ', '\u{3000}'], "_")),
                );
            }
        }
        let cards = cards
            .into_iter()
            .filter(|card| card.last_rep != -1)
            .map(foreign_card)
            .collect::<Result<Vec<_>, _>>()?;

        notes.push(ForeignNote {
            fields,
            tags,
            notetype: fact_view.notetype().to_string(),
            deck: String::new(),
            cards,
        });
    }

    Ok(ForeignData {
        notes,
        notetypes: used_fact_views
            .into_iter()
            .map(FactView::notetype_definition)
            .collect(),
        default_deck: deck_name.to_string(),
    })
}

fn card_ord(fact_view_id: &str) -> Result<i64, String> {
    let ord = fact_view_id
        .rsplit(|character| character == '.' || character == ':')
        .next()
        .ok_or_else(|| format!("Mnemosyne fact view id '{fact_view_id}' has unknown format"))?;
    let ord = ord
        .parse::<i64>()
        .map_err(|_| format!("Mnemosyne fact view id '{fact_view_id}' has unknown format"))?;
    ord.checked_sub(1)
        .ok_or_else(|| format!("Mnemosyne fact view id '{fact_view_id}' has unknown format"))
}

fn foreign_card(card: MnemoCard) -> Result<ForeignCard, String> {
    let interval = (i128::from(card.next_rep) - i128::from(card.last_rep)) / 86_400;
    let interval = u32::try_from(interval.max(1))
        .map_err(|_| format!("Mnemosyne card interval is too large: {interval}"))?;
    let ease_factor = card.easiness as f32;
    if !ease_factor.is_finite() {
        return Err(format!(
            "Mnemosyne card has an invalid ease factor: {}",
            card.easiness
        ));
    }
    let reps = card
        .acq_reps
        .checked_add(card.ret_reps)
        .ok_or_else(|| "Mnemosyne card repetition count overflowed".to_string())?;
    Ok(ForeignCard {
        due: card.next_rep,
        interval,
        ease_factor,
        reps: u32::try_from(reps)
            .map_err(|_| format!("Mnemosyne card repetition count is invalid: {reps}"))?,
        lapses: u32::try_from(card.lapses)
            .map_err(|_| format!("Mnemosyne card lapse count is invalid: {}", card.lapses))?,
    })
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;

    #[test]
    fn inspection_reports_version_fact_and_card_counts() {
        let directory = tempdir().expect("temp directory");
        let path = directory.path().join("mnemo.db");
        let connection = Connection::open(&path).expect("create Mnemosyne database");
        connection
            .execute_batch(
                "CREATE TABLE global_variables (key TEXT, value TEXT);
                 CREATE TABLE facts (_id INTEGER PRIMARY KEY);
                 CREATE TABLE cards (fact_view_id TEXT);",
            )
            .expect("create Mnemosyne schema");
        connection
            .execute("INSERT INTO facts VALUES (1), (2)", [])
            .expect("insert facts");
        connection
            .execute("INSERT INTO cards VALUES ('1.1'), ('1.1'), ('2.1')", [])
            .expect("insert cards");
        connection
            .execute("INSERT INTO global_variables VALUES ('version', '2')", [])
            .expect("insert version");
        drop(connection);

        let request = serde_json::to_vec(&serde_json::json!({
            "path": path.to_str().expect("UTF-8 path")
        }))
        .expect("encode request");
        let json = inspect(&request).expect("inspect Mnemosyne database");
        let value: serde_json::Value = serde_json::from_slice(&json).expect("decode response");
        assert_eq!(value["version"], "2");
        assert_eq!(value["note_count"], 2);
        assert_eq!(value["card_count"], 3);
        assert_eq!(value["fact_view_counts"]["1.1"], 2);
        assert_eq!(value["fact_view_counts"]["2.1"], 1);
    }

    #[test]
    fn inspects_upstream_mnemosyne_fixture() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../anki-upstream/pylib/tests/support/mnemo.db");
        let request = serde_json::to_vec(&serde_json::json!({
            "path": path.to_str().expect("UTF-8 path")
        }))
        .expect("encode request");
        let json = inspect(&request).expect("inspect upstream Mnemosyne fixture");
        let inspection: serde_json::Value =
            serde_json::from_slice(&json).expect("decode inspection response");
        assert_eq!(inspection["note_count"], 5);
        assert_eq!(inspection["card_count"], 7);

        let path_string = path.to_str().expect("UTF-8 path");
        let connection =
            open_mnemosyne_read_only(path_string).expect("open upstream Mnemosyne fixture");
        let converted = gather_foreign_data(&connection, "Mnemosyne")
            .expect("convert upstream Mnemosyne fixture");
        assert_eq!(converted.notes.len(), 5);
        assert!(!converted.notetypes.is_empty());
    }

    #[test]
    fn field_munging_matches_mnemosyne_conversions() {
        let munger = FieldMunger::new().expect("field munger");
        assert_eq!(
            munger.munge("one\r\ntwo\n<$> <$$> <LaTeX> </LATEX> <audio src=\"sound.mp3\"></audio>"),
            "one<br>two<br>[$] [$$] [LaTeX] [/LATEX] [sound:sound.mp3]"
        );
    }

    #[test]
    fn gathers_munged_notes_tags_types_and_reviewed_cards() {
        let directory = tempdir().expect("temp directory");
        let connection =
            Connection::open(directory.path().join("mnemo.db")).expect("create Mnemosyne database");
        connection
            .execute_batch(
                "CREATE TABLE facts (_id INTEGER PRIMARY KEY, id TEXT);
                 CREATE TABLE data_for_fact (_fact_id INTEGER, key TEXT, value TEXT);
                 CREATE TABLE cards (
                     _fact_id INTEGER,
                     fact_view_id TEXT,
                     tags TEXT,
                     next_rep INTEGER,
                     last_rep INTEGER,
                     easiness REAL,
                     acq_reps INTEGER,
                     ret_reps INTEGER,
                     lapses INTEGER
                 );",
            )
            .expect("create Mnemosyne schema");
        connection
            .execute("INSERT INTO facts VALUES (1, 'one')", [])
            .expect("insert fact");
        connection
            .execute("INSERT INTO facts VALUES (2, 'two')", [])
            .expect("insert fact");
        connection
            .execute("INSERT INTO facts VALUES (3, 'three')", [])
            .expect("insert fact");
        for (fact_id, key, value) in [
            (1, "f", "front\nline"),
            (1, "b", "back"),
            (2, "f", "only front"),
            (3, "text", "keep [this] verbatim"),
        ] {
            connection
                .execute(
                    "INSERT INTO data_for_fact VALUES (?1, ?2, ?3)",
                    rusqlite::params![fact_id, key, value],
                )
                .expect("insert fact field");
        }
        for card in [
            (
                1,
                "1.2",
                "two words, ideographic\u{3000}space",
                200_000,
                100_000,
                2.5,
                2,
                3,
                1,
            ),
            (1, "1.1", "", -1, -1, 2.5, 0, 0, 0),
            (3, "5.1.1", "cloze tags", 300_000, 200_000, 2.5, 1, 0, 0),
        ] {
            connection
                .execute(
                    "INSERT INTO cards VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                    rusqlite::params![
                        card.0, card.1, card.2, card.3, card.4, card.5, card.6, card.7, card.8
                    ],
                )
                .expect("insert card");
        }

        let data =
            gather_foreign_data(&connection, "Imported::Mnemosyne").expect("gather Mnemosyne data");
        assert_eq!(data.default_deck, "Imported::Mnemosyne");
        assert_eq!(data.notes[0].fields, vec!["front<br>line", "back"]);
        assert_eq!(data.notes[0].tags, vec!["two_words", "ideographic_space"]);
        assert_eq!(data.notes[0].cards.len(), 1);
        assert_eq!(data.notes[0].cards[0].interval, 1);
        assert_eq!(data.notes[0].cards[0].reps, 5);
        assert_eq!(data.notes[0].cards[0].lapses, 1);
        assert_eq!(data.notes[1].notetype, "Mnemosyne-FrontOnly");
        assert_eq!(data.notes[2].fields, vec!["keep [this] verbatim"]);
        assert_eq!(data.notes[2].notetype, "Mnemosyne-Cloze");
        assert!(!data.notetypes[0].is_cloze);
        assert!(data.notetypes[1].is_cloze);
        assert_eq!(data.notetypes[1].fields, ["Text", "Back Extra"]);
    }
}
