# The kind and the code of one failure per family of the std/ modules (#671). A std/ function that passes on an
# error of a builtin keeps its kind and code: the archive of a missing file is io.not_found with ENOENT (2).
import Actor from "std/actor"
import Archive from "std/archive"
import Binary from "std/binary"
import Cookie from "std/cookie"
import HTTP from "std/http"
import OP from "std/option_parser"
import Regex from "std/regex"
import Toml from "std/toml"
import URI from "std/uri"

def at(dir: String, name: String) -> String = Path.join([dir, name]).unwrap!

def show[T](label: String, family: String, result: Result[T]) -> Void
  case result
    ok(_) -> puts("#{label}: ok")
    error(e) ->
      code = case e.code
        some(n) -> n.to_s
        none -> "none"
      end
      puts("#{label}: #{e.kind} code=#{code} #{family}=#{e.is_a?(family)}")
  end
end

def main() -> Void
  dir: String = System.args()[0]
  show("regex syntax", "regex", Regex.compile("a(b"))
  show("regex template", "regex", Regex.replace("ab", Regex.compile("a").unwrap!, "$9"))
  show("toml text", "toml", Toml.parse("a = = 1"))
  doc = Toml.parse("a = 1").unwrap!
  show("toml wrong type", "toml", Toml.get(doc, "a.b"))
  show("toml encode", "argument", Toml.encode(Toml.Value.Int(1)))
  parser = OP.new("prog", "test", [], [OP.Opt(name: "port", kind: OP.Kind.Int)])
  show("unknown option", "option_parser", OP.parse(parser, ["--nope"]))
  show("help", "option_parser", OP.parse(parser, ["--help"]))
  show("bad specification", "argument", OP.parse(OP.new("", "test", [], []), []))
  tar = at(dir, "short.tar")
  _ = File.write_text(tar, "not a tar header", 5000)
  show("truncated tar", "archive", Archive.extract_tar(tar, ["a.txt"], at(dir, "out1")))
  show("member with ..", "argument", Archive.extract_tar(tar, ["../a.txt"], at(dir, "out2")))
  show("missing tar", "io", Archive.extract_tar(at(dir, "missing.tar"), ["a.txt"], at(dir, "out3")))
  show("short zip", "archive", Archive.extract_zip(tar, ["a.txt"], at(dir, "out4")))
  show("frame over the limit", "binary", Binary.read_frame_length(Binary.frame("abc".bytes).unwrap!, 0, 2))
  show("read past the end", "argument", Binary.read_u32_be("ab".bytes, 0))
  show("cookie name", "argument", Cookie.set_header(Cookie.Cookie(name: "a b", value: "c")))
  show("uri escape", "argument", URI.decode_uri_component("%zz"))
  show("uri utf-8", "text", URI.decode_uri_component("%ff"))
  pool = HTTP.client().unwrap!
  show("http url", "argument", HTTP.get(pool, "ftp://x/"))
  show("http body text", "text", HTTP.text(Bytes.from_list([255]).unwrap!))
  HTTP.close_client(pool)
  show("http closed client", "http", HTTP.get(pool, "http://127.0.0.1:9/"))
  behaviour: Actor.Behaviour[Int, Int] = Actor.Behaviour(
    init: -> { 0 },
    handle: ->(count, n) { Actor.continue(count + n) },
    terminate: none,
  )
  actor = Actor.start(behaviour)
  _ = Actor.stop(actor, 5000)
  show("actor gone", "channel", Actor.cast(actor.address, 1))
end
