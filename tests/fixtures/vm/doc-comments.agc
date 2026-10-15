## Doc comments reach only the parser.
##
## This program documents everything it declares, and the VM runs it as if the comments were not there.

import Queue from "std/queue"

## A point on a grid.
export struct Point
  ## The column.
  x: Int
  ## The row.
  y: Int
end

## How a move ends.
### Variants
enum Outcome
  ## The move worked, with the new place.
  Moved(Point)
  ## The move was blocked.
  Blocked
end

# An ordinary comment is not a doc block.
## Says how a move ended.
export def describe(outcome: Outcome) -> String
  case outcome
    Outcome.Moved(p) -> return "moved to #{p.x},#{p.y}"
    Outcome.Blocked -> return "blocked"
  end
  return ""
end

## Moves a point one column to the right.
##
## The grid is three columns wide, so a point at `x: 2` is blocked.
def step(p: Point) -> Outcome
  if p.x >= 2
    return Outcome.Blocked
  end
  return Outcome.Moved(Point(x: p.x + 1, y: p.y))
end

## Walks a point to the edge and prints each move.
def main() -> Void
  note = "## not a doc line" ## nor is this
  puts(note)
  p = Point(x: 0, y: 1)
  moves = Queue.new()
  while true
    outcome = step(p)
    moves = Queue.push(moves, describe(outcome))
    case outcome
      Outcome.Moved(next) -> p = next
      Outcome.Blocked -> break
    end
  end
  puts(Queue.size(moves))
  while not Queue.empty?(moves)
    popped = Result.unwrap!(Queue.pop(moves))
    puts(popped.value)
    moves = popped.remaining
  end
end
