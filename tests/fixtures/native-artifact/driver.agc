import Engine from "../../../compiler/io/native_artifact"
import Pure from "../../../compiler/packages/native_artifact"
import Failure from "../../../compiler/modules/link_failure"

# Runs the tracked native artifact engine from the command line, for the hermetic tests of
# tests/test_spec_package_native_artifact.py. Each run prints one line: "OK <text>" or
# "ERR <code> file=<file> key=<key>" (a packed engine failure, unpacked), or "ERR <text>" for a pure check.
# Arguments after the mode are positional, in the order the mode's line below names them.

def show(result: Result[String]) -> Void
  case result
    ok(path) -> puts("OK #{path}")
    error(packed) ->
      failure = Failure.unpack_failure(packed)
      puts("ERR #{failure.diagnostic.code} file=#{failure.file} key=#{failure.key_path}")
  end
end

def show_bool(value: Bool) -> Void
  if value
    puts("true")
  else
    puts("false")
  end
end

def main() -> Void
  args = System.args()
  mode = args[0]
  if mode == "fetch"
    source = Pure.Source(url: args[4], sha256: args[5], member: args[6])
    context = Pure.Context(file: args[2], key: args[3])
    show(Engine.fetch(args[1], source, context, args[7].to_i!))
  elsif mode == "cached"
    context = Pure.Context(file: args[2], key: args[3])
    show(Engine.cached(args[1], args[4], args[5], context, args[6].to_i!))
  elsif mode == "canonical"
    case Pure.canonical_member(args[1])
      ok(canon) -> puts("OK #{canon}")
      error(message) -> puts("ERR #{message}")
    end
  elsif mode == "nul"
    case Pure.canonical_member("a#{String.from_code(0)}b")
      ok(canon) -> puts("OK #{canon}")
      error(_) -> puts("ERR rejected")
    end
  elsif mode == "digest"
    puts(Pure.member_digest_hex(args[1]))
  elsif mode == "allowed"
    show_bool(Pure.url_allowed?(args[1]))
  elsif mode == "resolve"
    case Pure.resolve_location(args[1], args[2])
      ok(found) -> puts("OK #{found}")
      error(_) -> puts("ERR rejected")
    end
  elsif mode == "validsha"
    show_bool(Pure.valid_sha?(args[1]))
  elsif mode == "downgrade"
    show_bool(Pure.downgrade?(args[1], args[2]))
  elsif mode == "redirect"
    show_bool(Pure.redirect_status?(args[1].to_i!))
  elsif mode == "budget"
    case Pure.hop_budget(args[1].to_i!, args[2].to_i!)
      ok(left) -> puts("OK #{left.to_s}")
      error(_) -> puts("ERR spent")
    end
  elsif mode == "layout"
    puts(Pure.archive_path(args[1], args[2]))
    digest = Pure.member_digest_hex(args[3])
    puts(Pure.member_dir(args[1], args[2], digest))
    puts(Pure.payload_path(args[1], args[2], digest, args[3]))
    puts(Pure.receipt_path(args[1], args[2], digest))
  elsif mode == "limits"
    puts(Pure.MAX_REDIRECTS.to_s)
    puts(Pure.TOTAL_BODY_BYTES.to_s)
    puts(Pure.MEMBER_MAX_BYTES.to_s)
    puts(Pure.NAME_LIMIT_BYTES.to_s)
    puts(Pure.SHA_HEX_LENGTH.to_s)
  else
    puts("ERR unknown mode")
  end
end
