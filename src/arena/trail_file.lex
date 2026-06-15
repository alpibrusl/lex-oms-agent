# lex-arena — trail file format (the submission artifact)
#
# One event per line, canonical lex-trail fields. parent is "" for root
# events (instead of JSON null) so a single record type parses every
# line. The event id is recomputable from the other fields, so a trail
# file is self-verifying: tampering with any field breaks its line.
#
#   {"id":"<sha256>","kind":"...","parent":"","payload_json":"...","ts_ms":1700000000000}
#
# Effects: pure builders/parsers; read/write helpers carry [fs_read] /
# [fs_write] via std.io.

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.json" as json

# A parsed trail-file line. Mirrors lex-trail's Event with parent
# flattened to Str ("" = no parent).
type Line = { id :: Str, kind :: Str, parent :: Str, payload_json :: Str, ts_ms :: Int }

# ---- Export ----------------------------------------------------------
fn esc(s :: Str) -> Str {
  str.replace(str.replace(s, "\\", "\\\\"), "\"", "\\\"")
}

fn line_json(l :: Line) -> Str {
  "{\"id\":\"" + l.id + "\",\"kind\":\"" + l.kind + "\",\"parent\":\"" + l.parent + "\",\"payload_json\":\"" + esc(l.payload_json) + "\",\"ts_ms\":" + int.to_str(l.ts_ms) + "}"
}

fn to_jsonl(lines :: List[Line]) -> Str {
  str.join(list.map(lines, line_json), "\n")
}

# ---- Parse -----------------------------------------------------------
fn parse_line(s :: Str) -> Result[Line, Str] {
  let parsed :: Result[Line, Str] := json.parse(s)
  parsed
}

fn parse_jsonl(content :: Str) -> Result[List[Line], Str] {
  let raw_lines := str.split(content, "\n")
  let non_empty := list.filter(raw_lines, fn (s :: Str) -> Bool {
    not str.is_empty(str.trim(s))
  })
  list.fold(non_empty, Ok([]), fn (acc :: Result[List[Line], Str], s :: Str) -> Result[List[Line], Str] {
    match acc {
      Err(e) => Err(e),
      Ok(ls) => match parse_line(s) {
        Err(e) => Err("bad trail line: " + e),
        Ok(l) => Ok(list.concat(ls, [l])),
      },
    }
  })
}

