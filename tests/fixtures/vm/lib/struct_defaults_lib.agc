import Levels from "struct_levels"

export enum Level
  Quiet
  Loud
end

# Every kind of constant default. The Levels.Tone.Bold default is resolved here, so a file that does not import
# struct_levels can leave the field out.
export struct Options
  name: String
  retries: Int = 3
  ratio: Float = -0.5
  label: String = "none"
  verbose: Bool = false
  tags: List[String] = []
  limits: Map[String, Int] = {}
  level: Level = Level.Quiet
  tone: Levels.Tone = Levels.Tone.Bold
end

# Every field has a default, so a parameter can default to Limits(); its Levels.Tone.Bold resolves here too.
export struct Limits
  count: Int = 3
  tone: Levels.Tone = Levels.Tone.Bold
end

export def limits_text(l: Limits = Limits()) -> String
  return "#{l.count} #{l.tone}"
end

export def describe(o: Options) -> String
  head = "#{o.name} #{o.retries} #{o.ratio} #{o.label} #{o.verbose}"
  return "#{head} #{o.tags.size} #{o.limits.size} #{o.level} #{o.tone}"
end
