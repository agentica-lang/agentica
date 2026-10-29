## Test driver of tests/test_std_cookie.py: reads one JSON case per line of stdin, runs one function of std/cookie and
## prints one JSON line with the result.

import Cookie from "std/cookie"

# A case holds every input so one type decodes every line: `text` for `parse`, `cookie` for `set_header`.
struct Case
  op: String
  text: String
  cookie: Cookie.Cookie
end

# `message` is empty on success. `text` is the string result and `cookies` the map of `parse`.
struct Reply
  success: Bool
  message: String
  text: String
  cookies: Map[String, String]
end

def text_reply(text: String) -> Reply
  return Reply(success: true, message: "", text: text, cookies: {})
end

def run_case(c: Case) -> Reply
  case c.op
    "parse" -> return Reply(success: true, message: "", text: "", cookies: Cookie.parse(c.text))
    "default_max_age" -> return text_reply("#{Cookie.Cookie(name: "a", value: "b").max_age}")
    "no_max_age" -> return text_reply("#{Cookie.NO_MAX_AGE}")
    "set_header" ->
      case Cookie.set_header(c.cookie)
        ok(header) -> return text_reply(header)
        error(message) -> return Reply(success: false, message: message, text: "", cookies: {})
      end
    _ -> return Reply(success: false, message: "unknown op #{c.op}", text: "", cookies: {})
  end
end

def main() -> Void
  while true
    line = IO.gets()
    if !line.ok?
      return
    end
    case JSON.decode(line.unwrap!, Case)
      ok(c) -> puts(JSON.encode(run_case(c)))
      error(message) ->
        puts(JSON.encode(Reply(success: false, message: "bad case: #{message}", text: "", cookies: {})))
    end
  end
end
