//! SCIP (https://github.com/sourcegraph/scip): the index format scip-java writes. A SCIP index lists, per
//! document, every occurrence of a symbol with its range and roles. Only the fields used here are
//! decoded, with a small protobuf reader, so no protobuf dependency. A port of the prototype's `SCIP.swift`.

use anyhow::{anyhow, bail, Result};

#[derive(Clone, Debug, PartialEq)]
pub struct Occurrence {
    /// 1-based, like the rest of the change report (SCIP lines are 0-based).
    pub line: u32,
    pub symbol: String,
    pub roles: i32,
}

impl Occurrence {
    pub fn is_definition(&self) -> bool {
        self.roles & 0x1 != 0
    }
}

#[derive(Clone, Debug, PartialEq, Default)]
pub struct Document {
    /// Relative to the index's project root.
    pub path: String,
    pub occurrences: Vec<Occurrence>,
}

#[derive(Clone, Debug, PartialEq, Default)]
pub struct Index {
    /// A file URI, such as "file:///tmp/head/web".
    pub project_root: Option<String>,
    pub documents: Vec<Document>,
}

/// Modules and packages (symbols that end in a namespace, such as `demo/cache/`) aren't declarations.
pub fn is_declaration(symbol: &str) -> bool {
    !symbol.is_empty() && !symbol.ends_with('/')
}

/// Local symbols ("local 4") are only unique within their document.
pub fn is_local(symbol: &str) -> bool {
    symbol.starts_with("local ")
}

/// The name of a symbol's last descriptor, with "()" for a method:
/// "scip-java maven . . demo/cache/Cache#load()." -> "load()".
pub fn name_of_symbol(symbol: &str) -> String {
    if let Some(rest) = symbol.strip_prefix("local ") {
        return rest.to_string();
    }
    // Scheme, manager, package name, and version, separated by single spaces (a double space is an escaped space).
    let chars: Vec<char> = symbol.chars().collect();
    let mut i = 0;
    let mut fields = 0;
    while i < chars.len() && fields < 4 {
        if chars[i] == ' ' {
            if i + 1 < chars.len() && chars[i + 1] == ' ' {
                i += 2;
                continue;
            }
            fields += 1;
        }
        i += 1;
    }
    let mut last = String::new();
    while i < chars.len() {
        let c = chars[i];
        if c == '(' || c == '[' {
            // A parameter or type parameter: (name) or [name].
            let close = if c == '(' { ')' } else { ']' };
            while i < chars.len() && chars[i] != close {
                i += 1;
            }
            i += 1;
            continue;
        }
        let mut name = String::new();
        if c == '`' {
            i += 1;
            while i < chars.len() {
                if chars[i] == '`' {
                    if i + 1 < chars.len() && chars[i + 1] == '`' {
                        name.push('`');
                        i += 2;
                        continue;
                    }
                    i += 1;
                    break;
                }
                name.push(chars[i]);
                i += 1;
            }
        } else {
            while i < chars.len() && (chars[i].is_alphanumeric() || "_+-$".contains(chars[i])) {
                name.push(chars[i]);
                i += 1;
            }
        }
        if i >= chars.len() {
            last = name;
            break;
        }
        if chars[i] == '(' {
            // A method: name(disambiguator).
            while i < chars.len() && chars[i] != ')' {
                i += 1;
            }
            i += 2;
            last = format!("{name}()");
        } else {
            // Namespace "/", type "#", term ".", meta ":", or macro "!".
            i += 1;
            last = name;
        }
    }
    last
}

// MARK: Decoding

pub fn decode(bytes: &[u8]) -> Result<Index> {
    let mut r = Reader { bytes, pos: 0, end: bytes.len() };
    let mut index = Index::default();
    while let Some((field, wire)) = r.next()? {
        match (field, wire) {
            (1, 2) => {
                let mut m = r.message()?;
                while let Some((f, w)) = m.next()? {
                    if f == 3 && w == 2 {
                        index.project_root = Some(m.string()?);
                    } else {
                        m.skip(w)?;
                    }
                }
            }
            (2, 2) => index.documents.push(document(r.message()?)?),
            _ => r.skip(wire)?,
        }
    }
    Ok(index)
}

fn document(mut r: Reader) -> Result<Document> {
    let mut doc = Document::default();
    while let Some((field, wire)) = r.next()? {
        match (field, wire) {
            (1, 2) => doc.path = r.string()?,
            (2, 2) => {
                if let Some(o) = occurrence(r.message()?)? {
                    doc.occurrences.push(o);
                }
            }
            _ => r.skip(wire)?,
        }
    }
    Ok(doc)
}

fn occurrence(mut r: Reader) -> Result<Option<Occurrence>> {
    let mut range: Vec<i32> = Vec::new();
    let mut symbol = String::new();
    let mut roles = 0i32;
    while let Some((field, wire)) = r.next()? {
        match (field, wire) {
            (1, 2) => {
                let mut packed = r.message()?;
                while !packed.at_end() {
                    range.push(packed.varint()? as i32);
                }
            }
            (1, 0) => range.push(r.varint()? as i32),
            (8, 2) => {
                // A typed range: start line, start character, end... The start line is 0 when left out.
                let mut typed = r.message()?;
                let mut line = 0i32;
                while let Some((f, w)) = typed.next()? {
                    if (f, w) == (1, 0) {
                        line = typed.varint()? as i32;
                    } else {
                        typed.skip(w)?;
                    }
                }
                range = vec![line];
            }
            (2, 2) => symbol = r.string()?,
            (3, 0) => roles = r.varint()? as i32,
            _ => r.skip(wire)?,
        }
    }
    Ok(range.first().map(|start| Occurrence { line: (*start).max(0) as u32 + 1, symbol, roles }))
}

/// Reads protobuf fields from a range of bytes.
#[derive(Clone, Copy)]
struct Reader<'b> {
    bytes: &'b [u8],
    pos: usize,
    end: usize,
}

impl<'b> Reader<'b> {
    fn at_end(&self) -> bool {
        self.pos >= self.end
    }

    /// The next field number and wire type, or None at the end.
    fn next(&mut self) -> Result<Option<(u64, u8)>> {
        if self.at_end() {
            return Ok(None);
        }
        let key = self.varint()?;
        Ok(Some((key >> 3, (key & 7) as u8)))
    }

    fn varint(&mut self) -> Result<u64> {
        let mut result = 0u64;
        let mut shift = 0u32;
        loop {
            if self.pos >= self.end || shift >= 64 {
                bail!("Truncated varint at byte {}.", self.pos);
            }
            let b = self.bytes[self.pos];
            self.pos += 1;
            result |= ((b & 0x7f) as u64) << shift;
            if b & 0x80 == 0 {
                return Ok(result);
            }
            shift += 7;
        }
    }

    /// A length-delimited field's bytes, as a reader of their own.
    fn message(&mut self) -> Result<Reader<'b>> {
        let length = self.varint()? as usize;
        if self.pos + length > self.end {
            return Err(anyhow!("Field runs past the end at byte {}.", self.pos));
        }
        let m = Reader { bytes: self.bytes, pos: self.pos, end: self.pos + length };
        self.pos += length;
        Ok(m)
    }

    fn string(&mut self) -> Result<String> {
        let m = self.message()?;
        Ok(String::from_utf8_lossy(&self.bytes[m.pos..m.end]).into_owned())
    }

    fn skip(&mut self, wire: u8) -> Result<()> {
        match wire {
            0 => {
                self.varint()?;
            }
            1 => self.pos += 8,
            2 => {
                self.message()?;
            }
            5 => self.pos += 4,
            _ => bail!("Unsupported wire type {wire} at byte {}.", self.pos),
        }
        if self.pos > self.end {
            bail!("Field runs past the end.");
        }
        Ok(())
    }
}

#[cfg(test)]
pub mod testing {
    //! Writes SCIP indexes field by field, for tests that need one without an indexer.
    fn varint(mut v: u64, out: &mut Vec<u8>) {
        loop {
            let b = (v & 0x7f) as u8;
            v >>= 7;
            if v == 0 {
                out.push(b);
                return;
            }
            out.push(b | 0x80);
        }
    }

    fn field(number: u64, body: &[u8], out: &mut Vec<u8>) {
        varint(number << 3 | 2, out);
        varint(body.len() as u64, out);
        out.extend_from_slice(body);
    }

    /// `documents`: (path, [(0-based line, symbol, roles)]).
    pub fn encode(documents: &[(&str, Vec<(u32, &str, i32)>)]) -> Vec<u8> {
        let mut out = Vec::new();
        for (path, occurrences) in documents {
            let mut doc = Vec::new();
            field(1, path.as_bytes(), &mut doc);
            for (line, symbol, roles) in occurrences {
                let mut occ = Vec::new();
                let mut range = Vec::new();
                for v in [*line as u64, 0, 1] {
                    varint(v, &mut range);
                }
                field(1, &range, &mut occ);
                field(2, symbol.as_bytes(), &mut occ);
                varint(3 << 3, &mut occ);
                varint(*roles as u64, &mut occ);
                field(2, &occ, &mut doc);
            }
            field(2, &doc, &mut out);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        assert_eq!(name_of_symbol("scip-java maven . . demo/cache/Cache#load()."), "load()");
        assert_eq!(name_of_symbol("scip-java maven . . demo/cache/Cache#"), "Cache");
        assert_eq!(name_of_symbol("scip-java maven . . demo/app/warm."), "warm");
        assert_eq!(name_of_symbol("local 4"), "4");
        assert!(!is_declaration("scip-java maven . . demo/cache/"));
    }

    #[test]
    fn round_trip() {
        let bytes = testing::encode(&[("app/Main.kt", vec![(2, "scip-java maven . . demo/app/start().", 1), (4, "scip-java maven . . demo/cache/Cache#", 0)])]);
        let index = decode(&bytes).unwrap();
        assert_eq!(index.documents.len(), 1);
        assert_eq!(index.documents[0].path, "app/Main.kt");
        assert_eq!(index.documents[0].occurrences[0], Occurrence { line: 3, symbol: "scip-java maven . . demo/app/start().".into(), roles: 1 });
        assert!(!index.documents[0].occurrences[1].is_definition());
    }
}
