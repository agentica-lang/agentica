## The "did you mean" help of an unknown name: src/builtins.rkt (did-you-mean, edit-distance).

import Ast from "ast"
import Diag from "diagnostic"
import Types from "types"

## The help text for the exported name closest to name, or Absent when none is close. A name of up to 4 characters may differ by 1 edit, a longer one by 2; the nearest wins, and the smaller name breaks a tie.
export def did_you_mean(name: String, candidates: List[String]) -> Ast.Optional[String]
  return did_you_mean_among(name, candidates, [])
end

## did_you_mean for the names of a linked program (src/builtins.rkt, did-you-mean). A linked name starts with "@N::", the prefix of its file; only the candidates of the same file are offered, and without their prefix. shared are extra candidates that have no prefix, such as the builtin names.
export def did_you_mean_among(full_name: String, candidates: List[String], shared: List[String]) -> Ast.Optional[String]
  prefix = file_prefix(full_name)
  name = Types.display_name(full_name)
  limit = 2
  if name.length <= 4
    limit = 1
  end
  pool: List[String] = []
  for candidate in candidates
    if file_prefix(candidate) == prefix
      pool = pool.push(Types.display_name(candidate))
    end
  end
  return nearest(name, pool.concat(shared).sort, limit)
end

## The help of CHECK-IMPORT-NAME for member, which the module key does not export: the fixed texts for the removed std/http functions and std/logger error, or the did-you-mean over the exports (a private name is never suggested).
export def unknown_import_help(key: String, exports: List[String], member: String) -> Diag.Help
  removed = ["respond", "begin", "write", "write_bytes", "finish"].any? do |name| name == member end
  if key == "std/http.agc" and removed
    return Diag.Help.Hint("a handler returns its whole response: return ok(HttpResponse(status: 200, headers: [], body: text))")
  elsif key == "std/logger.agc" and member == "error"
    return Diag.Help.Hint("the function for the error level is Logger.err; error is a reserved name")
  end
  case did_you_mean(member, exports)
    Ast.Optional.Present(text) -> return Diag.Help.Hint(text)
    Ast.Optional.Absent -> return Diag.Help.NoHelp
  end
end

## The "@N::" a linked name starts with, or "".
export def file_prefix(name: String) -> String
  shown = Types.display_name(name)
  return name.slice(0, name.length - shown.length)
end

## The number of single-character edits (insert, delete, replace) from a to b.
export def edit_distance(a: String, b: String) -> Int
  right = b.split("")
  first: List[Int] = (0..right.size).to_a
  return last_row(a.split(""), right, 1, first)
end

# The candidates are sorted, so the first one at the smallest distance is the smaller name of a tie. A candidate whose length differs by more than the limit cannot be near, which skips most of the table.
def nearest(name: String, ordered: List[String], limit: Int) -> Ast.Optional[String]
  best = ""
  best_distance = limit + 1
  for candidate in ordered
    if candidate != name and close_in_length?(candidate, name, limit)
      distance = edit_distance(name, candidate)
      if distance < best_distance
        best = candidate
        best_distance = distance
      end
    end
  end
  if best_distance > limit
    return Ast.Optional.Absent
  end
  return Ast.Optional.Present("did you mean \"" + best + "\"?")
end

# One row of the table per character of the left word; the answer is the end of the last row.
def last_row(left: List[String], right: List[String], index: Int, previous: List[Int]) -> Int
  if index > left.size
    return previous[right.size]
  end
  return last_row(left, right, index + 1, next_row(left[index - 1], right, index, previous))
end

def next_row(character: String, right: List[String], index: Int, previous: List[Int]) -> List[Int]
  row: List[Int] = [index]
  for column in 1..right.size
    cost = 1
    if right[column - 1] == character
      cost = 0
    end
    best = smallest(previous[column] + 1, row[column - 1] + 1, previous[column - 1] + cost)
    row = row.push(best)
  end
  return row
end

def smallest(a: Int, b: Int, c: Int) -> Int
  least = a
  if b < least
    least = b
  end
  if c < least
    least = c
  end
  return least
end

def close_in_length?(a: String, b: String, limit: Int) -> Bool
  return a.length - b.length <= limit and b.length - a.length <= limit
end
