# arena CLI — JSON parse/build helpers
#
# Isolates the episodes-response decoding (scenario_json is null when a
# scoring scenario is withheld) and the submit-body construction (the
# trail is a multi-line JSONL string that must be JSON-escaped).
#
# Effects: none. Pure.

import "std.str" as str
import "std.list" as list
import "std.json" as json

# Episode the CLI uses. scenario_json is the pinned scenario string for
# revealed (practice) episodes. NOTE: json.parse does not coerce JSON
# null into an Option, so this field is typed Str; a withheld scenario
# (scoring seeds) comes back as null and the API only nulls it for
# non-practice episodes, which can't be run locally anyway.
type EpisodeRec = { id :: Str, slug :: Str, scenario_id :: Str, sim_version :: Str, is_practice :: Bool, scenario_json :: Str }

type RawResp = { episodes :: List[EpisodeRec] }

fn parse_episodes(body :: Str) -> Result[List[EpisodeRec], Str] {
  let parsed :: Result[RawResp, Str] := json.parse(body)
  match parsed {
    Err(e) => Err(e),
    Ok(resp) => Ok(resp.episodes),
  }
}

fn find_episode(body :: Str, slug :: Str) -> Result[EpisodeRec, Str] {
  match parse_episodes(body) {
    Err(e) => Err(e),
    Ok(eps) => {
      let matches := list.filter(eps, fn (ep :: EpisodeRec) -> Bool { ep.slug == slug })
      match list.head(matches) {
        None => Err("episode '" + slug + "' not found (try: arena episodes)"),
        Some(ep) => Ok(ep),
      }
    },
  }
}

# ---- submit body ------------------------------------------------------

fn esc(s :: Str) -> Str {
  let a := str.replace(s, "\\", "\\\\")
  let b := str.replace(a, "\"", "\\\"")
  let c := str.replace(b, "\n", "\\n")
  let d := str.replace(c, "\r", "\\r")
  str.replace(d, "\t", "\\t")
}

fn field(key :: Str, val :: Str) -> Str {
  "\"" + key + "\":\"" + esc(val) + "\""
}

fn submit_body(trail :: Str, name :: Str, division :: Str, model :: Str) -> Str {
  "{" + field("trail", trail)
    + "," + field("display_name", name)
    + "," + field("division", division)
    + "," + field("model_name", model)
    + "}"
}
