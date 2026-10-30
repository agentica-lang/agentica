import HTTP from "std/http"

def options(timeout_ms: Int, max_connections: Int) -> HttpClientOptions
  return HttpClientOptions(timeout_ms: timeout_ms, idle_timeout_ms: 30000, max_connections: max_connections,
                           max_body_bytes: 1048576, ca_file: "")
end

def answer(request: HttpRequest) -> Result[HttpResponse]
  return ok(HttpResponse(status: 200, headers: [], body: request.path.bytes))
end

def download_answer(request: HttpRequest) -> Result[HttpResponse]
  if request.path == "/tiny"
    return ok(HttpResponse(status: 200, headers: [Header(name: "X-Total", value: "4")], body: "abcd".bytes))
  end
  if request.path == "/hundred"
    return ok(HttpResponse(status: 200, headers: [], body: "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789".bytes))
  end
  if request.path == "/gone"
    return ok(HttpResponse(status: 404, headers: [], body: "nope".bytes))
  end
  return ok(HttpResponse(status: 200, headers: [], body: request.path.bytes))
end

def main() -> Void
  Test.run([
    Test.test("default client options") do
      Test.eq(HTTP.client_options(), options(30000, 4))
    end,
    Test.test("client options are checked") do
      try Test.eq(HTTP.client(options(0, 4)).message, "http: every option must be positive")
      Test.eq(HTTP.client(options(1000, 65537)).message, "http: max_connections must be at most 65536")
    end,
    Test.test("default server options") do
      Test.eq(HTTP.server_options(), HttpServerOptions(request_timeout_ms: 30000, idle_timeout_ms: 30000, max_connections: 128, max_body_bytes: 1048576))
    end,
    Test.test("server options are checked before listening") do
      bad = HttpServerOptions(request_timeout_ms: 1000, idle_timeout_ms: 0, max_connections: 1, max_body_bytes: 16)
      try Test.eq(HTTP.listen("127.0.0.1", 0, &answer, bad).message, "http: every option must be positive")
      wide = HttpServerOptions(request_timeout_ms: 1000, idle_timeout_ms: 1000, max_connections: 65537, max_body_bytes: 16)
      Test.eq(HTTP.listen_tls("127.0.0.1", 0, "none.pem", "none.pem", &answer, wide).message, "http: max_connections must be at most 65536")
    end,
    Test.test("a live server answers and closes inside a test") do
      server = try HTTP.listen("127.0.0.1", 0, &answer, HTTP.server_options())
      pool = try HTTP.client(HTTP.client_options())
      response = HTTP.get(pool, "http://127.0.0.1:#{HTTP.local_port(server)}/inside")
      HTTP.close_client(pool)
      HTTP.close_server(server)
      try Test.eq(HTTP.wait(server).ok?, true)
      Test.eq(response.unwrap!.body, "/inside".bytes)
    end,
    Test.test("header values match names in any case") do
      headers = [Header(name: "Set-Cookie", value: "a=1"), Header(name: "Content-Type", value: "text/plain"),
                 Header(name: "set-cookie", value: "b=2")]
      try Test.eq(HTTP.header_values(headers, "SET-COOKIE"), ["a=1", "b=2"])
      Test.eq(HTTP.header_values(headers, "x-missing"), [])
    end,
    Test.test("text decodes a body as UTF-8 and nothing else") do
      latin = [Header(name: "Content-Type", value: "text/plain; Charset=\"ISO-8859-1\"")]
      binary = Bytes.from_list([255, 0, 128]).unwrap!
      try Test.eq(HTTP.text("ñandú".bytes).unwrap!, "ñandú")
      try Test.eq(HTTP.text("ñ".bytes, [Header(name: "content-type", value: "text/html; charset=UTF-8")]).unwrap!, "ñ")
      try Test.eq(HTTP.text(binary).message, "http: body is not valid UTF-8")
      try Test.eq(HTTP.text("caf".bytes, latin).ok?, false)
      Test.eq(String.starts_with?(HTTP.text("caf".bytes, latin).message, "http: charset iso-8859-1 is not supported"), true)
    end,
    Test.test("text reads the charset of the first Content-Type header") do
      type = "content-type"
      binary = Bytes.from_list([255, 0, 128]).unwrap!
      try Test.eq(HTTP.text("é".bytes, [Header(name: type, value: "text/plain; charset=utf8")]).unwrap!, "é")
      try Test.eq(HTTP.text("e".bytes, [Header(name: type, value: "text/plain; charset=US-ASCII")]).unwrap!, "e")
      try Test.eq(HTTP.text("é".bytes, [Header(name: type, value: "text/plain; charset=")]).unwrap!, "é")
      try Test.eq(HTTP.text("é".bytes, [Header(name: type, value: "text/plain; format=flowed; charset=utf-8")]).unwrap!, "é")
      try Test.eq(HTTP.text("é".bytes, [Header(name: type, value: "text/plain")]).unwrap!, "é")
      mixed = [Header(name: type, value: "text/plain; charset=utf-8"), Header(name: type, value: "text/plain; charset=latin1")]
      try Test.eq(HTTP.text("é".bytes, mixed).unwrap!, "é")
      try Test.eq(HTTP.text("é".bytes, mixed.reverse).ok?, false)
      try Test.eq(HTTP.text("é".bytes, [Header(name: type, value: "text/plain; format=flowed; charset=latin1")]).ok?, false)
      try Test.eq(HTTP.text(binary, [Header(name: type, value: "text/plain; charset=utf-8")]).ok?, false)
      long = [Header(name: type, value: "text/plain; charset=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")]
      Test.eq(HTTP.text("e".bytes, long).message.length < 150, true)
    end,
    Test.test("bad URLs fail before any connection") do
      pool = try HTTP.client(HTTP.client_options())
      scheme = HTTP.get(pool, "ftp://example.com/")
      port = HTTP.get(pool, "http://example.com:0/")
      HTTP.close_client(pool)
      try Test.eq(scheme.message, "http: the URL must be http:// or https:// with a host, and without user info")
      Test.eq(port.message, "http: the port must be 1..65535")
    end,
    Test.test("download options carry the 256 MiB budget") do
      Test.eq(HTTP.download_options(), HTTP.DownloadOptions(timeout_ms: 30000, max_total_bytes: 268435456))
      Test.eq(HTTP.DownloadOptions(), HTTP.download_options())
    end,
    Test.test("a download writes the body to a new file") do
      server = try HTTP.listen("127.0.0.1", 0, &download_answer, HTTP.server_options())
      pool = try HTTP.client(HTTP.client_options())
      got = HTTP.download(pool, "http://127.0.0.1:#{HTTP.local_port(server)}/tiny", "download-tiny.bin", HTTP.download_options())
      HTTP.close_client(pool)
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
      server = try HTTP.listen("127.0.0.1", 0, &download_answer, HTTP.server_options())
      pool = try HTTP.client(HTTP.client_options())
      got = HTTP.download(pool, "http://127.0.0.1:#{HTTP.local_port(server)}/gone", "download-gone.bin", HTTP.download_options())
      HTTP.close_client(pool)
      HTTP.close_server(server)
      try HTTP.wait(server)
      saved = try got
      try Test.eq(saved.status, 404)
      try Test.eq(saved.bytes_written, 4)
      try Test.eq(try File.read_text("download-gone.bin", 5000), "nope")
      Path.remove("download-gone.bin", 5000)
    end,
    Test.test("a download refuses a body over the budget before reading it") do
      server = try HTTP.listen("127.0.0.1", 0, &download_answer, HTTP.server_options())
      pool = try HTTP.client(HTTP.client_options())
      small = HTTP.DownloadOptions(timeout_ms: 5000, max_total_bytes: 10)
      got = HTTP.download(pool, "http://127.0.0.1:#{HTTP.local_port(server)}/hundred", "download-over.bin", small)
      HTTP.close_client(pool)
      HTTP.close_server(server)
      try HTTP.wait(server)
      try Test.eq(got.message, "http: body exceeds max_body_bytes")
      handle = try File.open("download-over.bin", "read", 5000)
      try Test.eq((try File.read_bytes(handle, 100, 5000)).size, 0)
      try File.close(handle, 5000)
      Path.remove("download-over.bin", 5000)
    end,
    Test.test("a download never overwrites and checks its options first") do
      pool = try HTTP.client(HTTP.client_options())
      bad = HTTP.download(pool, "http://127.0.0.1:1/tiny", "download-never.bin", HTTP.DownloadOptions(timeout_ms: 0, max_total_bytes: 10))
      try Test.eq(bad.message, "http: every download option must be positive")
      huge = HTTP.download(pool, "http://127.0.0.1:1/tiny", "download-never.bin", HTTP.DownloadOptions(timeout_ms: 5000, max_total_bytes: 268435457))
      try Test.eq(huge.message, "http: max_total_bytes must be at most 268435456")
      try File.write_text("download-kept.bin", "old", 5000)
      server = try HTTP.listen("127.0.0.1", 0, &download_answer, HTTP.server_options())
      kept = HTTP.download(pool, "http://127.0.0.1:#{HTTP.local_port(server)}/tiny", "download-kept.bin", HTTP.download_options())
      HTTP.close_client(pool)
      HTTP.close_server(server)
      try HTTP.wait(server)
      try Test.eq(String.starts_with?(kept.message, "open-output-file: error opening file"), true)
      try Test.eq(try File.read_text("download-kept.bin", 5000), "old")
      Path.remove("download-kept.bin", 5000)
    end
  ])
end
