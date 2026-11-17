import Models from "models"

MARK = "ab".bytes

def pick(level: Models.Level = Models.Level.Warn, local: Local = Local.Two, tags: List[String] = []) -> String
  return "#{level} #{local} #{tags.size}"
end

def marked(mark: Bytes = MARK) -> Int = mark.size

private

enum Local
  One
  Two
end
