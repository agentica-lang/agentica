import Levels from "default_levels"

enum Level
  Quiet
  Loud
end

def title(name: String, level: Level = Level.Quiet) -> String
  return "#{name} #{level}"
end

# The default Levels.Tone.Bold is resolved here, so a caller that does not import default_levels can leave it out.
def render(heading: String = "report", rows: Int = 1, tone: Levels.Tone = Levels.Tone.Bold) -> String
  return "#{heading} #{rows} #{tone}"
end

def each_row(name: String, count: Int = 2, f: Fn[String, Void]) -> Void
  f.call("#{name} #{count}")
end
