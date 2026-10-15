# Module constants: values fixed for the whole run, written in capitals.

# A literal is part of the bytecode; the other values are built once, before main.
WIDTH = 8
PAGE_SIZE = WIDTH * 4
SEPARATOR = " | "

# A table built once; a function that runs many times only reads it.
PRICES = {"tea": 3, "cocoa": 5, "kiwi": 2}
FRUITS = Set.new(["kiwi", "apple"])
LABELS = PRICES.keys().map do |name| name.upcase() end

# A constant may read one that is declared later in the file.
SUMMARY = "#{WIDTH}#{SEPARATOR}#{PAGE_SIZE}"

def kind(name: String) -> String
  if FRUITS.include?(name)
    return "fruit"
  end
  return "drink"
end

def main() -> Void
  puts(SUMMARY)
  puts(PRICES.get("cocoa", 0))
  puts(kind("kiwi") + SEPARATOR + kind("tea"))
  puts(LABELS.size)
end
