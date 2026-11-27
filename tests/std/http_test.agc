import HTTP from "std/http"

def options(timeout_ms: Int, max_connections: Int) -> HTTP.ClientOptions
  HTTP.ClientOptions(
    timeout_ms: timeout_ms,
    idle_timeout_ms: 30000,
    max_connections: max_connections,
    max_body_bytes: 1048576,
  )
end

def answer(request: HTTP.Request) -> Result[HTTP.Response]
  ok(HTTP.Response(status: 200, headers: [], body: request.path.bytes))
end

def kind_of(result: Result[HTTP.Response]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end

def download_answer(request: HTTP.Request) -> Result[HTTP.Response]
  if request.path == "/tiny"
    return ok(HTTP.Response(status: 200, headers: [HTTP.Header(name: "X-Total", value: "4")], body: "abcd".bytes))
  end
  if request.path == "/hundred"
    return ok(
      HTTP.Response(
        status: 200,
        headers: [],
        body: "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789".bytes,
      ),
    )
  end
  return ok(HTTP.Response(status: 404, headers: [], body: "nope".bytes)) if request.path == "/gone"
  ok(HTTP.Response(status: 200, headers: [], body: request.path.bytes))
end

def main() -> Void
  Test.run([
    Test.test("default client options") do
      # The record holds a TLS.Context (tls), which has no equality: its fields are compared.
      given = HTTP.ClientOptions()
      expected = options(30000, 4)
      try Test.eq(
        [given.timeout_ms, given.idle_timeout_ms, given.max_connections, given.max_body_bytes],
        [expected.timeout_ms, expected.idle_timeout_ms, expected.max_connections, expected.max_body_bytes],
      )

      try Test.eq(given.proxy, "")
      Test.assert(given.tls.none?, "tls is none")
    end,
    Test.test("client options are checked") do
      try Test.eq(HTTP.client(options(0, 4)).message, "http: every option must be positive")
      Test.eq(HTTP.client(options(1000, 65537)).message, "http: max_connections must be at most 65536")
    end,
    Test.test("default server options") do
      Test.eq(
        HTTP.ServerOptions(),
        HTTP.ServerOptions(
          request_timeout_ms: 30000,
          idle_timeout_ms: 30000,
          max_connections: 128,
          max_body_bytes: 1048576,
        ),
      )
    end,
    Test.test("server options are checked before listening") do
      bad = HTTP.ServerOptions(request_timeout_ms: 1000, idle_timeout_ms: 0, max_connections: 1, max_body_bytes: 16)
      try Test.eq(HTTP.serve("127.0.0.1", 0, HTTP.app(&answer), bad).message, "http: every option must be positive")
      wide = HTTP.ServerOptions(
        request_timeout_ms: 1000,
        idle_timeout_ms: 1000,
        max_connections: 65537,
        max_body_bytes: 16,
      )

      Test.eq(
        HTTP.serve("127.0.0.1", 0, HTTP.app(&answer), wide).message,
        "http: max_connections must be at most 65536",
      )
    end,
    Test.test("a live server answers and closes inside a test") do
      server = try HTTP.serve("127.0.0.1", 0, HTTP.app(&answer))
      pool = try HTTP.client()
      response = HTTP.get(pool, "http://127.0.0.1:#{HTTP.local_port(server)}/inside")
      HTTP.close_client(pool)
      HTTP.close_server(server)
      try Test.eq(HTTP.wait(server).ok?, true)
      Test.eq(response.unwrap!.body, "/inside".bytes)
    end,
    Test.test("header values match names in any case") do
      headers = [
        HTTP.Header(name: "Set-Cookie", value: "a=1"),
        HTTP.Header(name: "Content-Type", value: "text/plain"),
        HTTP.Header(name: "set-cookie", value: "b=2"),
      ]

      try Test.eq(HTTP.header_values(headers, "SET-COOKIE"), ["a=1", "b=2"])
      Test.eq(HTTP.header_values(headers, "x-missing"), [])
    end,
    Test.test("text decodes a body in its charset") do
      latin = [HTTP.Header(name: "Content-Type", value: "text/plain; Charset=\"ISO-8859-1\"")]
      windows = [HTTP.Header(name: "Content-Type", value: "text/html; charset=windows-1252")]
      utf16 = [HTTP.Header(name: "Content-Type", value: "text/plain; charset=utf-16")]
      koi8 = [HTTP.Header(name: "Content-Type", value: "text/plain; charset=KOI8-R")]
      binary = Bytes.from_list([255, 0, 128]).unwrap!
      try Test.eq(HTTP.text("ñandú".bytes).unwrap!, "ñandú")
      try Test.eq(
        HTTP.text("ñ".bytes, [HTTP.Header(name: "content-type", value: "text/html; charset=UTF-8")]).unwrap!,
        "ñ",
      )

      try Test.eq(HTTP.text(binary).message, "http: body is not valid UTF-8")
      for spelling in ["UTF8", "Utf-8", "utf_8"]
        typed = [HTTP.Header(name: "content-type", value: "text/plain; charset=#{spelling}")]
        try Test.eq(HTTP.text(binary, typed).message, "http: body is not valid UTF-8")
      end

      ascii = [HTTP.Header(name: "content-type", value: "text/plain; charset=US-ASCII")]
      try Test.eq(HTTP.text("abc".bytes, ascii).unwrap!, "abc")
      try Test.eq(HTTP.text("aé".bytes, ascii).message, "http: invalid ASCII at byte 1")
      try Test.eq(HTTP.text("caf".bytes + Bytes.from_list([233]).unwrap!, latin).unwrap!, "café")
      try Test.eq(HTTP.text(Bytes.from_list([128, 32, 147, 104, 148]).unwrap!, windows).unwrap!, "€ “h”")
      undefined = Bytes.from_list([97, 129]).unwrap!
      try Test.eq(HTTP.text(undefined, windows).message, "http: invalid Windows-1252 at byte 1")
      try Test.eq(HTTP.text(Bytes.from_list([255, 254, 104, 0, 233, 0]).unwrap!, utf16).unwrap!, "hé")
      try Test.eq(HTTP.text("caf".bytes, koi8).ok?, false)
      Test.eq(HTTP.text("caf".bytes, koi8).message.start_with?("http: charset koi8-r is not supported"), true)
    end,
    Test.test("text reads the charset of the first Content-Type header") do
      type = "content-type"
      binary = Bytes.from_list([255, 0, 128]).unwrap!
      try Test.eq(HTTP.text("é".bytes, [HTTP.Header(name: type, value: "text/plain; charset=utf8")]).unwrap!, "é")
      try Test.eq(HTTP.text("e".bytes, [HTTP.Header(name: type, value: "text/plain; charset=US-ASCII")]).unwrap!, "e")
      try Test.eq(HTTP.text("é".bytes, [HTTP.Header(name: type, value: "text/plain; charset=")]).unwrap!, "é")
      try Test.eq(
        HTTP.text("é".bytes, [HTTP.Header(name: type, value: "text/plain; format=flowed; charset=utf-8")]).unwrap!,
        "é",
      )

      try Test.eq(HTTP.text("é".bytes, [HTTP.Header(name: type, value: "text/plain")]).unwrap!, "é")
      mixed = [
        HTTP.Header(name: type, value: "text/plain; charset=utf-8"),
        HTTP.Header(name: type, value: "text/plain; charset=latin1"),
      ]

      try Test.eq(HTTP.text("é".bytes, mixed).unwrap!, "é")
      try Test.eq(HTTP.text("é".bytes, mixed.reverse).unwrap!, "Ã©")
      try Test.eq(
        HTTP.text("é".bytes, [HTTP.Header(name: type, value: "text/plain; format=flowed; charset=latin1")]).unwrap!,
        "Ã©",
      )

      try Test.eq(HTTP.text(binary, [HTTP.Header(name: type, value: "text/plain; charset=utf-8")]).ok?, false)
      long = [
        HTTP.Header(
          name: type,
          value: (
            "text/plain; charset=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
          ),
        ),
      ]

      Test.eq(HTTP.text("e".bytes, long).message.length < 150, true)
    end,
    Test.test("bad URLs fail before any connection") do
      pool = try HTTP.client()
      scheme = HTTP.get(pool, "ftp://example.com/")
      port = HTTP.get(pool, "http://example.com:0/")
      HTTP.close_client(pool)
      try Test.eq(scheme.message, "http: the URL must be http:// or https:// with a host, and without user info")
      Test.eq(port.message, "http: the port must be 1..65535")
    end,
    Test.test("a request that cannot be written fails with its own error before any connect") do
      # Nothing listens on port 1: a connect would fail with a net kind.
      url = "http://127.0.0.1:1/"
      host = HTTP.post_response(url, "x".bytes, [HTTP.Header(name: "Host", value: "other")])
      big = HTTP.post_response(url, "0123456789".bytes, [], HTTP.ClientOptions(max_body_bytes: 5))
      Test.eq([kind_of(host), kind_of(big)], ["http.protocol", "http.too_large"])
    end,
    Test.test("download options have no limit by default") do
      Test.eq(HTTP.DownloadOptions(), HTTP.DownloadOptions(timeout_ms: none, max_total_bytes: none, sha256: none))
    end,
    Test.test("a download writes the body to a new file") do
      server = try HTTP.serve("127.0.0.1", 0, HTTP.app(&download_answer))
      got = HTTP.download("http://127.0.0.1:#{HTTP.local_port(server)}/tiny", "download-tiny.bin")
      HTTP.close_server(server)
      try HTTP.wait(server)
      saved = try got
      try Test.eq(saved.status, 200)
      try Test.eq(saved.bytes_written, 4)
      try Test.eq(HTTP.header_values(saved.headers, "x-total"), ["4"])
      try Test.eq(try File.read_text("download-tiny.bin", 5000), "abcd")
      Path.remove("download-tiny.bin", 5000)
    end,
    Test.test("a download reports a 404 and still writes its body") do
      server = try HTTP.serve("127.0.0.1", 0, HTTP.app(&download_answer))
      got = HTTP.download("http://127.0.0.1:#{HTTP.local_port(server)}/gone", "download-gone.bin")
      HTTP.close_server(server)
      try HTTP.wait(server)
      saved = try got
      try Test.eq(saved.status, 404)
      try Test.eq(saved.bytes_written, 4)
      try Test.eq(try File.read_text("download-gone.bin", 5000), "nope")
      Path.remove("download-gone.bin", 5000)
    end,
    Test.test("a download refuses a body over the budget and leaves no file") do
      server = try HTTP.serve("127.0.0.1", 0, HTTP.app(&download_answer))
      small = HTTP.DownloadOptions(max_total_bytes: some(10))
      got = HTTP.download("http://127.0.0.1:#{HTTP.local_port(server)}/hundred", "download-over.bin", small)
      HTTP.close_server(server)
      try HTTP.wait(server)
      try Test.eq(got.message, "http: body exceeds max_body_bytes")
      Test.eq(File.lstat("download-over.bin", 5000).ok?, false)
    end,
    Test.test("a download checks its options first and replaces a file only at the end") do
      bad = HTTP.download("http://127.0.0.1:1/tiny", "download-never.bin", HTTP.DownloadOptions(timeout_ms: some(0)))
      try Test.eq(bad.message, "http: every download option must be positive")
      digest = HTTP.download(
        "http://127.0.0.1:1/tiny",
        "download-never.bin",
        HTTP.DownloadOptions(sha256: some("abc")),
      )

      try Test.eq(digest.message, "http: sha256 must be 64 hex digits")
      reach = HTTP.download(
        "http://127.0.0.1:1/tiny",
        "download-never.bin",
        HTTP.DownloadOptions(),
        HTTP.ClientOptions(timeout_ms: 0),
      )

      try Test.eq(reach.message, "http: every option must be positive")
      try File.write_text("download-kept.bin", "old", 5000)
      server = try HTTP.serve("127.0.0.1", 0, HTTP.app(&download_answer))
      of_tiny = HTTP.DownloadOptions(sha256: some("88d4266fd4e6338d13b845fcf289579d209c897823b9217da3e161936f031589"))
      refused = HTTP.download("http://127.0.0.1:#{HTTP.local_port(server)}/hundred", "download-kept.bin", of_tiny)
      kept = try File.read_text("download-kept.bin", 5000)
      replaced = HTTP.download("http://127.0.0.1:#{HTTP.local_port(server)}/tiny", "download-kept.bin", of_tiny)
      HTTP.close_server(server)
      try HTTP.wait(server)
      try Test.eq(refused.message, "http: the body does not match the sha256 digest")
      try Test.eq(kept, "old")
      try Test.eq((try replaced).bytes_written, 4)
      try Test.eq(try File.read_text("download-kept.bin", 5000), "abcd")
      Path.remove("download-kept.bin", 5000)
    end,
  ])
end
