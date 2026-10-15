import {lex, Point as P} from "lib"

export def twice(text: String) -> P
  return P(x: lex(text), y: lex(text))
end
