# Text the writer must encode as UTF-8: a comment with ñ, é, ü and 日本語 and an emoji 😀 stays in the source text.
struct Pair
  left: String
  right: Float
end

enum Mood
  Calm
  Loud(String)
end

def greet(mood: Mood) -> String
  case mood
    Mood.Calm -> return "á é í ó ú ñ ü"
    Mood.Loud(text) -> return text + "¡Hola! €5 → ∑ 日本語 😀 𝔘𝔫𝔦"
  end
end

def main() -> Void
  pair = Pair(left: "héllo wörld, a string long enough to be a chunk of its own: ñññññññññññññññññññññ", right: -0.0)
  puts(pair.left)
  puts(greet(Mood.Loud("ß")))
  puts(greet(Mood.Calm))
  puts("#{0.0} #{-0.0} #{0.1} #{3.141592653589793} #{1234567.125} #{0.000000000000000000000000001}")
end
