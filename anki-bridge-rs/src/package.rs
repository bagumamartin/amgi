use std::collections::HashMap;
use std::fs;
use std::fs::File;
use std::io::{self, Read};
use std::path::Path;

use anki_proto::import_export::package_metadata::Version;
use anki_proto::import_export::{MediaEntries, PackageMetadata};
use prost::Message;
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use tempfile::NamedTempFile;
use zip::result::ZipError;
use zip::ZipArchive;

#[derive(Deserialize)]
struct InspectPackageRequest {
    path: String,
}

#[derive(Serialize, Debug, PartialEq, Eq)]
struct PackageInspection {
    format_version: u8,
    note_count: u64,
    card_count: u64,
    notetype_count: u64,
    review_count: u64,
    deck_names: Vec<String>,
    media_count: usize,
    archive_entry_count: usize,
    is_collection_backup: bool,
}

/// Inspect an Anki package without opening or modifying the user's file.
pub(super) fn inspect(input: &[u8]) -> Result<Vec<u8>, String> {
    let request: InspectPackageRequest =
        serde_json::from_slice(input).map_err(|err| format!("bad request json: {err}"))?;
    let inspection = inspect_path(&request.path)?;
    serde_json::to_vec(&inspection).map_err(|err| format!("encode failed: {err}"))
}

fn inspect_path(path: &str) -> Result<PackageInspection, String> {
    let source_path = Path::new(path);
    let metadata = fs::metadata(source_path).map_err(|err| file_open_error(path, &err))?;
    if !metadata.is_file() {
        return Err(format!("Anki package is not a file: {path}"));
    }

    // Swift stages Open-In/share imports into a private temporary directory
    // before calling this method. Open that staged file directly: copying a
    // media-heavy deck a second time would double peak storage and make the
    // review screen unnecessarily slow. The archive and extracted collection
    // are both opened read-only, so the staged source remains unchanged.
    inspect_package(source_path)
}

fn file_open_error(path: &str, err: &io::Error) -> String {
    if err.kind() == io::ErrorKind::NotFound {
        format!("Anki package not found: {path}")
    } else {
        format!("could not open Anki package {path}: {err}")
    }
}

fn inspect_package(path: &Path) -> Result<PackageInspection, String> {
    let file = File::open(path).map_err(|err| format!("could not open Anki package: {err}"))?;
    let mut archive = ZipArchive::new(file).map_err(|err| {
        if matches!(
            err,
            ZipError::InvalidArchive(_) | ZipError::UnsupportedArchive(_)
        ) {
            format!("file is not a valid ZIP-based Anki package: {err}")
        } else {
            format!("could not read Anki package ZIP: {err}")
        }
    })?;

    let archive_entry_count = archive.len();
    // Legacy full-collection backups contain the original on-disk
    // `collection.anki2`; deck exports contain only the normalized
    // `collection.anki21[b]` import database. This lets the UI avoid
    // trusting the user's filename to choose a destructive restore flow.
    let is_collection_backup = contains_entry(&mut archive, "collection.anki2")?;
    let format_version = detect_format_version(&mut archive)?;
    let collection_name = collection_filename(format_version).to_string();
    let media_count = inspect_media_map(&mut archive, format_version)?;
    let (note_count, card_count, notetype_count, review_count, deck_names) =
        inspect_collection(&mut archive, &collection_name, format_version)?;

    Ok(PackageInspection {
        format_version,
        note_count,
        card_count,
        notetype_count,
        review_count,
        deck_names,
        media_count,
        archive_entry_count,
        is_collection_backup,
    })
}

fn detect_format_version(archive: &mut ZipArchive<File>) -> Result<u8, String> {
    let meta_bytes = read_optional_entry(archive, "meta")?;
    if let Some(bytes) = meta_bytes {
        let metadata = PackageMetadata::decode(bytes.as_slice())
            .map_err(|err| format!("package contains an invalid meta entry: {err}"))?;
        return match Version::try_from(metadata.version) {
            Ok(Version::Legacy1) => Ok(1),
            Ok(Version::Legacy2) => Ok(2),
            Ok(Version::Latest) => Ok(3),
            Ok(Version::Unknown) | Err(_) => Err(format!(
                "unsupported Anki package format version {} in meta entry",
                metadata.version
            )),
        };
    }

    // Older packages do not contain protobuf metadata. Newer exports are
    // accepted even without meta so files produced by alternate clients can
    // still be inspected.
    for (filename, version) in [
        ("collection.anki21b", 3),
        ("collection.anki21", 2),
        ("collection.anki2", 1),
    ] {
        if contains_entry(archive, filename)? {
            return Ok(version);
        }
    }

    Err(
        "ZIP is not an Anki package: expected collection.anki2, collection.anki21, or collection.anki21b"
            .to_string(),
    )
}

fn collection_filename(version: u8) -> &'static str {
    match version {
        1 => "collection.anki2",
        2 => "collection.anki21",
        3 => "collection.anki21b",
        _ => "collection.anki21b",
    }
}

fn inspect_collection(
    archive: &mut ZipArchive<File>,
    collection_name: &str,
    format_version: u8,
) -> Result<(u64, u64, u64, u64, Vec<String>), String> {
    let mut extracted = NamedTempFile::new()
        .map_err(|err| format!("could not create temporary Anki collection file: {err}"))?;
    {
        let mut collection = archive.by_name(collection_name).map_err(|err| {
            if matches!(err, ZipError::FileNotFound) {
                format!(
                    "format version {format_version} is missing required package entry {collection_name}"
                )
            } else {
                format!("could not open package entry {collection_name}: {err}")
            }
        })?;
        if format_version == 3 {
            zstd::stream::copy_decode(&mut collection, &mut extracted).map_err(|err| {
                format!("could not decompress {collection_name} with zstd: {err}")
            })?;
        } else {
            io::copy(&mut collection, &mut extracted).map_err(|err| {
                format!("could not extract {collection_name} from package: {err}")
            })?;
        }
    }

    let connection = open_collection_read_only(extracted.path())?;
    let note_count = table_count(&connection, "notes")?;
    let card_count = table_count(&connection, "cards")?;
    let notetype_count = table_count(&connection, "notetypes")?;
    let review_count = table_count(&connection, "revlog")?;
    let deck_names = deck_names(&connection)?;
    Ok((
        note_count,
        card_count,
        notetype_count,
        review_count,
        deck_names,
    ))
}

fn open_collection_read_only(path: &Path) -> Result<Connection, String> {
    Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|err| format!("collection entry is not a readable SQLite database: {err}"))
}

fn table_count(connection: &Connection, table: &str) -> Result<u64, String> {
    let candidates: &[&str] = match table {
        "notes" => &["notes"],
        "cards" => &["cards"],
        // Very old schema 11 packages called this table `models`.
        "notetypes" => &["notetypes", "models"],
        "revlog" => &["revlog"],
        _ => return Err(format!("unsupported collection count table: {table}")),
    };
    let Some(sql_table) = candidates
        .iter()
        .copied()
        .find(|candidate| table_exists(connection, candidate))
    else {
        // Old schema-10 packages can omit review history, and very old
        // packages store note definitions inside `col` rather than a table.
        if table == "revlog" || table == "notetypes" {
            return Ok(0);
        }
        return Err(format!(
            "Anki collection is missing required table {table} (tried {candidates:?})"
        ));
    };
    let count: i64 = connection
        .query_row(&format!("SELECT COUNT(*) FROM {sql_table}"), [], |row| {
            row.get(0)
        })
        .map_err(|err| format!("could not inspect Anki collection table {sql_table}: {err}"))?;
    u64::try_from(count).map_err(|_| {
        format!("Anki collection table {sql_table} contains an invalid count: {count}")
    })
}

fn table_exists(connection: &Connection, table: &str) -> bool {
    connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1 LIMIT 1",
            [table],
            |_| Ok(()),
        )
        .is_ok()
}

fn deck_names(connection: &Connection) -> Result<Vec<String>, String> {
    let mut names = if table_exists(connection, "decks") {
        let mut statement = connection
            .prepare("SELECT name FROM decks")
            .map_err(|err| format!("could not inspect Anki collection decks: {err}"))?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|err| format!("could not inspect Anki collection decks: {err}"))?;
        let mut values = Vec::new();
        for row in rows {
            values.push(
                row.map_err(|err| format!("Anki collection contains an invalid deck name: {err}"))?,
            );
        }
        values
    } else if table_exists(connection, "col") {
        let json: String = connection
            .query_row("SELECT decks FROM col", [], |row| row.get(0))
            .map_err(|err| format!("could not inspect legacy Anki collection decks: {err}"))?;
        let decks: serde_json::Value = serde_json::from_str(&json)
            .map_err(|err| format!("Anki collection contains invalid legacy deck data: {err}"))?;
        decks
            .as_object()
            .map(|values| {
                values
                    .values()
                    .filter_map(|deck| deck.get("name").and_then(serde_json::Value::as_str))
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default()
    } else {
        Vec::new()
    };
    for name in &mut names {
        *name = name.replace('\u{1f}', "::");
    }
    names.sort();
    Ok(names)
}

fn inspect_media_map(archive: &mut ZipArchive<File>, format_version: u8) -> Result<usize, String> {
    let Some(bytes) = read_optional_entry(archive, "media")? else {
        // Some older AnkiDroid exports omitted an empty media map.
        return Ok(0);
    };

    if format_version < 3 {
        let media: HashMap<String, String> = serde_json::from_slice(&bytes)
            .map_err(|err| format!("package contains an invalid legacy media map: {err}"))?;
        Ok(media.len())
    } else {
        let decoded = zstd::stream::decode_all(bytes.as_slice())
            .map_err(|err| format!("could not decompress current media map with zstd: {err}"))?;
        let media = MediaEntries::decode(decoded.as_slice())
            .map_err(|err| format!("package contains an invalid current media map: {err}"))?;
        Ok(media.entries.len())
    }
}

fn read_optional_entry(
    archive: &mut ZipArchive<File>,
    name: &str,
) -> Result<Option<Vec<u8>>, String> {
    let mut entry = match archive.by_name(name) {
        Ok(entry) => entry,
        Err(ZipError::FileNotFound) => return Ok(None),
        Err(err) => return Err(format!("could not open package entry {name}: {err}")),
    };
    let mut bytes = Vec::new();
    entry
        .read_to_end(&mut bytes)
        .map_err(|err| format!("could not read package entry {name}: {err}"))?;
    Ok(Some(bytes))
}

fn contains_entry(archive: &mut ZipArchive<File>, name: &str) -> Result<bool, String> {
    match archive.by_name(name) {
        Ok(_) => Ok(true),
        Err(ZipError::FileNotFound) => Ok(false),
        Err(err) => Err(format!("could not inspect package entry {name}: {err}")),
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use anki_proto::import_export::media_entries::MediaEntry;
    use tempfile::tempdir;
    use zip::write::SimpleFileOptions;
    use zip::ZipWriter;

    use super::*;

    fn make_collection(path: &Path) {
        let connection = Connection::open(path).expect("create collection");
        connection
            .execute_batch(
                "CREATE TABLE notes (id INTEGER PRIMARY KEY);
                 CREATE TABLE cards (id INTEGER PRIMARY KEY);
                 CREATE TABLE notetypes (id INTEGER PRIMARY KEY);
                 CREATE TABLE revlog (id INTEGER PRIMARY KEY);
                 CREATE TABLE decks (id INTEGER PRIMARY KEY, name TEXT NOT NULL);",
            )
            .expect("create collection schema");
        connection
            .execute("INSERT INTO notes VALUES (1)", [])
            .expect("insert note");
        connection
            .execute("INSERT INTO cards VALUES (1)", [])
            .expect("insert card");
        connection
            .execute("INSERT INTO notetypes VALUES (1)", [])
            .expect("insert notetype");
        connection
            .execute("INSERT INTO revlog VALUES (1)", [])
            .expect("insert review");
        connection
            .execute("INSERT INTO decks VALUES (2, 'Zulu')", [])
            .expect("insert deck");
        connection
            .execute(
                "INSERT INTO decks VALUES (3, 'Parent' || char(31) || 'Child')",
                [],
            )
            .expect("insert child deck");
    }

    #[test]
    fn inspects_current_compressed_package_and_media_map() {
        let directory = tempdir().expect("temp directory");
        let collection_path = directory.path().join("collection.anki21");
        make_collection(&collection_path);
        let collection_bytes = fs::read(&collection_path).expect("read collection");
        let compressed_collection =
            zstd::stream::encode_all(collection_bytes.as_slice(), 0).expect("compress collection");
        let media = MediaEntries {
            entries: vec![MediaEntry {
                name: "sound.mp3".to_string(),
                size: 12,
                sha1: vec![1, 2, 3],
                legacy_zip_filename: None,
            }],
        };
        let compressed_media = zstd::stream::encode_all(media.encode_to_vec().as_slice(), 0)
            .expect("compress media map");
        let meta = PackageMetadata {
            version: Version::Latest as i32,
        }
        .encode_to_vec();

        let package_path = directory.path().join("collection.apkg");
        let file = File::create(&package_path).expect("create package");
        let mut zip = ZipWriter::new(file);
        let options = SimpleFileOptions::default();
        zip.start_file("meta", options).expect("start meta");
        zip.write_all(&meta).expect("write meta");
        zip.start_file("collection.anki21b", options)
            .expect("start collection");
        zip.write_all(&compressed_collection)
            .expect("write collection");
        zip.start_file("media", options).expect("start media");
        zip.write_all(&compressed_media).expect("write media");
        zip.finish().expect("finish package");

        let result = inspect_path(package_path.to_str().expect("UTF-8 path"));
        assert_eq!(
            result,
            Ok(PackageInspection {
                format_version: 3,
                note_count: 1,
                card_count: 1,
                notetype_count: 1,
                review_count: 1,
                deck_names: vec!["Parent::Child".to_string(), "Zulu".to_string()],
                media_count: 1,
                archive_entry_count: 3,
                is_collection_backup: false,
            })
        );
    }

    #[test]
    fn inspects_legacy_package_and_media_map() {
        let directory = tempdir().expect("temp directory");
        let collection_path = directory.path().join("collection.anki21");
        make_collection(&collection_path);
        let collection_bytes = fs::read(&collection_path).expect("read collection");
        let media = serde_json::to_vec(&serde_json::json!({
            "0": "first.jpg",
            "2": "second.mp3"
        }))
        .expect("encode media map");

        let package_path = directory.path().join("collection.colpkg");
        let file = File::create(&package_path).expect("create package");
        let mut zip = ZipWriter::new(file);
        let options = SimpleFileOptions::default();
        zip.start_file("collection.anki21", options)
            .expect("start collection");
        zip.write_all(&collection_bytes).expect("write collection");
        zip.start_file("media", options).expect("start media");
        zip.write_all(&media).expect("write media");
        zip.finish().expect("finish package");

        let result = inspect_path(package_path.to_str().expect("UTF-8 path"))
            .expect("inspect legacy package");
        assert_eq!(result.format_version, 2);
        assert_eq!(result.media_count, 2);
        assert_eq!(result.archive_entry_count, 2);
        assert_eq!(result.note_count, 1);
        assert_eq!(result.card_count, 1);
    }

    #[test]
    fn identifies_legacy_full_collection_backup_by_contents() {
        let directory = tempdir().expect("temp directory");
        let collection_path = directory.path().join("collection.anki2");
        make_collection(&collection_path);
        let collection_bytes = fs::read(&collection_path).expect("read collection");
        let media = serde_json::to_vec(&serde_json::json!({})).expect("encode media map");

        // Filename intentionally does not use `collection.apkg`; classification
        // must come from the archive contents rather than a naming convention.
        let package_path = directory.path().join("renamed-backup.apkg");
        let file = File::create(&package_path).expect("create package");
        let mut zip = ZipWriter::new(file);
        let options = SimpleFileOptions::default();
        zip.start_file("collection.anki2", options)
            .expect("start collection");
        zip.write_all(&collection_bytes).expect("write collection");
        zip.start_file("media", options).expect("start media");
        zip.write_all(&media).expect("write media");
        zip.finish().expect("finish package");

        let inspection = inspect_path(package_path.to_str().expect("UTF-8 path"))
            .expect("inspect collection backup");
        assert!(inspection.is_collection_backup);
    }

    #[test]
    fn inspects_upstream_media_package_fixture() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../anki-upstream/pylib/tests/support/media.apkg");
        let inspection = inspect_path(path.to_str().expect("UTF-8 path"))
            .expect("inspect upstream package fixture");
        assert!(inspection.note_count > 0);
        assert!(inspection.card_count > 0);
        assert!(inspection.media_count > 0);
        assert!(!inspection.deck_names.is_empty());
    }

    #[test]
    fn rejects_non_zip_input_with_useful_error() {
        let directory = tempdir().expect("temp directory");
        let path = directory.path().join("bad.apkg");
        fs::write(&path, b"not a zip").expect("write invalid package");
        let error =
            inspect_path(path.to_str().expect("UTF-8 path")).expect_err("non-ZIP should fail");
        assert!(error.contains("not a valid ZIP-based Anki package"));
    }

    #[test]
    fn legacy_deck_names_are_humanized() {
        let directory = tempdir().expect("temp directory");
        let connection =
            Connection::open(directory.path().join("collection.anki2")).expect("create collection");
        connection
            .execute_batch(
                "CREATE TABLE notes (id INTEGER);
                 CREATE TABLE cards (id INTEGER);
                 CREATE TABLE notetypes (id INTEGER);
                 CREATE TABLE revlog (id INTEGER);
                 CREATE TABLE decks (name TEXT);",
            )
            .expect("create schema");
        connection
            .execute("INSERT INTO decks VALUES ('B' || char(31) || 'C')", [])
            .expect("insert deck");
        drop(connection);

        let names = deck_names(
            &Connection::open(directory.path().join("collection.anki2")).expect("reopen"),
        )
        .expect("read deck names");
        assert_eq!(names, vec!["B::C".to_string()]);
    }
}
