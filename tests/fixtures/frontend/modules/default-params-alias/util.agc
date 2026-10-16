import Models from "models"

enum Local
  One
  Two
end

export def pick(level: Models.Level = Models.Level.Warn, local: Local = Local.Two, tags: List[String] = []) -> String
  return "#{level} #{local} #{tags.size}"
end
