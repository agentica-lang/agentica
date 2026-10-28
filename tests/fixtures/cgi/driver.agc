## Test driver of tests/test_std_cgi.py: reads one JSON case per line of stdin, runs one function of std/cgi and prints
## one JSON line with the result.

import CGI from "std/cgi"

# A case holds every input so one type decodes every line: `text` for the HTML and header functions, `cookie` for
# `set_cookie_header`.
struct Case
  op: String
  text: String
  cookie: CGI.Cookie
end

# `message` is empty on success. `text` is the string result and `cookies` the map of `parse_cookies_header`.
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
    "escape_html" -> return text_reply(CGI.escape_html(c.text))
    "unescape_html" -> return text_reply(CGI.unescape_html(c.text))
    "parse_cookies_header" -> return Reply(success: true, message: "", text: "", cookies: CGI.parse_cookies_header(c.text))
    "set_cookie_header" ->
      case CGI.set_cookie_header(c.cookie)
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
      error(message) -> puts(JSON.encode(Reply(success: false, message: "bad case: #{message}", text: "", cookies: {})))
    end
  end
end
