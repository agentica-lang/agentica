## Test driver of tests/test_std_uri.py: reads one JSON case per line of stdin, runs one function of std/uri and prints
## one JSON line with the result.

import URI from "std/uri"

# A case holds both inputs so one type decodes every line: `text` for the component functions and the query decoder,
# `pairs` for the query encoder.
struct Case
  op: String
  text: String
  pairs: List[URI.Pair]
end

# `message` is empty on success. `text` is the string result and `pairs` the pairs of `decode_www_form`.
struct Reply
  success: Bool
  message: String
  text: String
  pairs: List[URI.Pair]
end

def text_reply(result: Result[String]) -> Reply
  case result
    ok(text) -> return Reply(success: true, message: "", text: text, pairs: [])
    error(message) -> return Reply(success: false, message: message, text: "", pairs: [])
  end
end

def run_case(c: Case) -> Reply
  case c.op
    "encode_www_form_component" -> return text_reply(ok(URI.encode_www_form_component(c.text)))
    "encode_uri_component" -> return text_reply(ok(URI.encode_uri_component(c.text)))
    "decode_www_form_component" -> return text_reply(URI.decode_www_form_component(c.text))
    "decode_uri_component" -> return text_reply(URI.decode_uri_component(c.text))
    "encode_www_form" -> return text_reply(ok(URI.encode_www_form(c.pairs)))
    "decode_www_form" ->
      case URI.decode_www_form(c.text)
        ok(pairs) -> return Reply(success: true, message: "", text: "", pairs: pairs)
        error(message) -> return Reply(success: false, message: message, text: "", pairs: [])
      end
    _ -> return Reply(success: false, message: "unknown op #{c.op}", text: "", pairs: [])
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
      error(message) -> puts(JSON.encode(Reply(success: false, message: "bad case: #{message}", text: "", pairs: [])))
    end
  end
end
