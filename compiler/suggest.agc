## The "did you mean" help of an unknown imported name: src/builtins.rkt (did-you-mean, edit-distance) for plain names.

import "ast" as Ast

## The help text for the exported name closest to name, or Absent when none is close. A name of up to 4 characters may differ by 1 edit, a longer one by 2; the nearest wins, and the smaller name breaks a tie.
export def did_you_mean(name: String, candidates: List[String]) -> Ast.Optional[String]
  limit = 2
  if name.length <= 4
    limit = 1
  end
  # sort_by is stable, so sorting the names first makes the distance ties go to the smaller name.
  ordered = candidates.sort.sort_by do |candidate: String| edit_distance(name, candidate) end
  for candidate in ordered
    if candidate != name and edit_distance(name, candidate) <= limit
      return Ast.Optional.Present("did you mean \"" + candidate + "\"?")
    end
  end
  return Ast.Optional.Absent
end

## The number of single-character edits (insert, delete, replace) from a to b.
export def edit_distance(a: String, b: String) -> Int
  right = b.split("")
  first: List[Int] = (0..right.size).to_a
  return last_row(a.split(""), right, 1, first)
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
