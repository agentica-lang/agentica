## Module blocks: two named modules in one file, each with its own private helpers.

UNIT = "items"

module Stock
  export enum Change
    Add(Int)
    Take(Int)
  end

  export struct Shelf[T]
    label: T
    count: Int
  end

  export def apply(count: Int, change: Change) -> Int
    case change
      Change.Add(n) -> count + n
      Change.Take(n) -> floor_at_zero(count - n)
    end
  end

  def floor_at_zero(n: Int) -> Int
    return 0 if n < 0

    n
  end
end

module Report
  export def line(shelf: Stock.Shelf[String]) -> String = "#{shelf.label}: #{shelf.count} #{UNIT}"
end

def main() -> Void
  changes = [Stock.Change.Add(5), Stock.Change.Take(2), Stock.Change.Take(9)]
  count = changes.reduce(0) do |total, change| Stock.apply(total, change) end
  puts(Report.line(Stock.Shelf(label: "apples", count: count)))
  puts(Report.line(Stock.Shelf(label: "pears", count: Stock.apply(1, Stock.Change.Add(2)))))
end
