#lang racket

(require rackunit "network-support.rkt")

(define (client-program port secure?)
  (format
   #<<AGC
def produce(text: String, writer: HttpWriter) -> Result[Nil]
  try HTTP.write(writer, text, 1000)
  try HTTP.write_bytes(writer, [195, 177], 1000)
  return HTTP.finish(writer, [Header(name: "X-Upload", value: "done")], 1000)
end
def main() -> Nil
  defaults = HTTP.client_options()
  options = HttpClientOptions(timeout_ms: 2000, idle_timeout_ms: defaults.idle_timeout_ms, max_connections: 1, max_body_bytes: defaults.max_body_bytes, ca_file: ~s)
  client = Result.unwrap!(HTTP.client(options))
  first = Result.unwrap!(HTTP.get(client, ~s + "/fixed"))
  puts(Result.unwrap!(HTTP.text(first.body, 1000)))
  second = Result.unwrap!(HTTP.get(client, ~s + "/chunked"))
  puts(Result.unwrap!(HTTP.text(second.body, 1000)))
  IO.inspect(HTTP.header_values(first.headers, "X-CONNECTION")[0] == HTTP.header_values(second.headers, "x-connection")[0])
  IO.inspect(List.size(HTTP.header_values(second.headers, "set-cookie")))
  puts(HTTP.header_values(Result.unwrap!(HTTP.trailers(second.body)), "x-trailer")[0])
  posted = Result.unwrap!(HTTP.post(client, ~s + "/echo", [], "post"))
  puts(Result.unwrap!(HTTP.text(posted.body, 1000)))
  uploaded = Result.unwrap!(HTTP.request_stream(client, "POST", ~s + "/echo", [], -1, &produce, "upload"))
  puts(Result.unwrap!(HTTP.text(uploaded.body, 1000)))
  head = Result.unwrap!(HTTP.request(client, "HEAD", ~s + "/fixed", [], ""))
  IO.inspect(Result.unwrap!(HTTP.read(head.body, 8, 1000)))
  empty = Result.unwrap!(HTTP.get(client, ~s + "/empty"))
  IO.inspect(empty.status)
  IO.inspect(Result.unwrap!(HTTP.read(empty.body, 8, 1000)))
  HTTP.close_body(empty.body)
  after = Result.unwrap!(HTTP.get(client, ~s + "/fixed"))
  IO.inspect(HTTP.header_values(first.headers, "x-connection")[0] == HTTP.header_values(after.headers, "x-connection")[0])
  puts(Result.unwrap!(HTTP.text(after.body, 1000)))
  abandoned = Result.unwrap!(HTTP.get(client, ~s + "/fixed"))
  HTTP.close_body(abandoned.body)
  last = Result.unwrap!(HTTP.get(client, ~s + "/close"))
  puts(Result.unwrap!(HTTP.text(last.body, 1000)))
  HTTP.close_client(client)
  HTTP.close_client(client)
end
AGC
   (if secure? (path->string ca-path) "")
   (format "~a://localhost:~a" (if secure? "https" "http") port)
   (format "~a://localhost:~a" (if secure? "https" "http") port)
   (format "~a://localhost:~a" (if secure? "https" "http") port)
   (format "~a://localhost:~a" (if secure? "https" "http") port)
   (format "~a://localhost:~a" (if secure? "https" "http") port)
   (format "~a://localhost:~a" (if secure? "https" "http") port)
   (format "~a://localhost:~a" (if secure? "https" "http") port)
   (format "~a://localhost:~a" (if secure? "https" "http") port)
   (format "~a://localhost:~a" (if secure? "https" "http") port)))

(define (server-program secure?)
  (format
   #<<AGC
def handler(request: Request, writer: HttpWriter) -> Nil
  if request.path == "/stream"
    Result.unwrap!(HTTP.begin(writer, 200, [Header(name: "Set-Cookie", value: "one=1"), Header(name: "Set-Cookie", value: "two=2"), Header(name: "Trailer", value: "X-Trailer")], -1, 1000))
    Result.unwrap!(HTTP.write(writer, "ñ", 1000))
    Result.unwrap!(HTTP.write_bytes(writer, [240, 159, 152, 128], 1000))
    Result.unwrap!(HTTP.finish(writer, [Header(name: "X-Trailer", value: "finished")], 1000))
  elsif request.path == "/echo"
    Result.unwrap!(HTTP.begin(writer, 200, [], -1, 1000))
    part = Result.unwrap!(HTTP.read(request.body, 65536, 1000))
    while List.size(part) > 0
      Result.unwrap!(HTTP.write_bytes(writer, part, 1000))
      part = Result.unwrap!(HTTP.read(request.body, 65536, 1000))
    end
    Result.unwrap!(HTTP.finish(writer, [], 1000))
  elsif request.path == "/empty"
    Result.unwrap!(HTTP.respond(writer, 204, [], "", 1000))
  else
    Result.unwrap!(HTTP.respond(writer, 404, [], "missing", 1000))
  end
end
def main() -> Nil
  server = Result.unwrap!(~a)
  puts(String.from_int(HTTP.local_port(server)))
  IO.flush()
  IO.gets()
  HTTP.close_server(server)
  Result.unwrap!(HTTP.wait(server))
  HTTP.close_server(server)
end
AGC
   (if secure?
       (format "HTTP.listen_tls(\"127.0.0.1\", 0, ~s, ~s, &handler, HTTP.server_options())"
               (path->string cert-path) (path->string key-path))
       "HTTP.listen(\"127.0.0.1\", 0, &handler, HTTP.server_options())")))

(module+ test
  (when (node-available?)
    (test-case "Buffered POST receives a large echo while uploading under backpressure"
      (with-peers
       (lambda (ports)
         (check-equal?
          (run-program
           (format
            #<<AGC
def main() -> Nil
  defaults = HTTP.client_options()
  options = HttpClientOptions(timeout_ms: 15000, idle_timeout_ms: defaults.idle_timeout_ms, max_connections: 1, max_body_bytes: defaults.max_body_bytes, ca_file: "")
  client = Result.unwrap!(HTTP.client(options))
  payload = String.join(List.repeat("abcdefgh", 1048576), "")
  response = Result.unwrap!(HTTP.post(client, "http://localhost:~a/echo", [], payload))
  total = 0
  part = Result.unwrap!(HTTP.read(response.body, 65536, 15000))
  while List.size(part) > 0
    total = total + List.size(part)
    part = Result.unwrap!(HTTP.read(response.body, 65536, 15000))
  end
  IO.inspect(total)
  HTTP.close_client(client)
end
AGC
            (hash-ref ports 'http)))
          "8388608\n"))))
    (test-case "HTTP clients reuse fixed and chunked connections and stream uploads over HTTP and verified HTTPS"
      (with-peers
       (lambda (ports)
         (for ([name '(http https)] [secure? '(#f #t)])
           (check-equal? (run-program (client-program (hash-ref ports name) secure?))
                         "hello\nñ😀\ntrue\n2\nfinished\npost\nuploadñ\n[]\n204\n[]\ntrue\nhello\nclose\n")))))
    (test-case "HTTP rejects framing errors, truncation, legacy versions and untrusted certificates locally"
      (with-peers
       (lambda (ports)
         (check-equal?
          (run-program
           (format
            #<<AGC
def main() -> Nil
  client = Result.unwrap!(HTTP.client())
  IO.inspect(Result.ok?(HTTP.get(client, "http://localhost:~a/ambiguous")))
  IO.inspect(Result.ok?(HTTP.get(client, "http://localhost:~a/version")))
  truncated = Result.unwrap!(HTTP.get(client, "http://localhost:~a/truncated"))
  IO.inspect(Result.ok?(HTTP.text(truncated.body, 1000)))
  eof = Result.unwrap!(HTTP.get(client, "http://localhost:~a/eof"))
  puts(Result.unwrap!(HTTP.text(eof.body, 1000)))
  IO.inspect(Result.ok?(HTTP.get(client, "https://localhost:~a/fixed")))
  HTTP.close_client(client)
end
AGC
            (hash-ref ports 'raw) (hash-ref ports 'raw) (hash-ref ports 'raw)
            (hash-ref ports 'raw) (hash-ref ports 'https)))
          "false\nfalse\nfalse\nuntil eof\nfalse\n"))))
    (test-case "pool waits and body timeouts are recoverable without corrupting other exchanges"
      (with-peers
       (lambda (ports)
         (check-equal?
          (run-program
           (format
            #<<AGC
def main() -> Nil
  opts = HttpClientOptions(timeout_ms: 100, idle_timeout_ms: 1000, max_connections: 1, max_body_bytes: 100, ca_file: "")
  client = Result.unwrap!(HTTP.client(opts))
  first = Result.unwrap!(HTTP.get(client, "http://localhost:~a/fixed"))
  IO.inspect(Result.ok?(HTTP.get(client, "http://localhost:~a/fixed")))
  puts(Result.unwrap!(HTTP.text(first.body, 1000)))
  IO.inspect(Result.ok?(HTTP.get(client, "http://localhost:~a/slow")))
  stalled = Result.unwrap!(HTTP.get(client, "http://localhost:~a/stalled"))
  IO.inspect(Result.ok?(HTTP.read(stalled.body, 8, 20)))
  final = Result.unwrap!(HTTP.get(client, "http://localhost:~a/fixed"))
  puts(Result.unwrap!(HTTP.text(final.body, 1000)))
  IO.inspect(Result.ok?(HTTP.request(client, "GET", "http://localhost:~a/fixed", [Header(name: "X-Test", value: "bad\r\nInjected: yes")], "")))
  HTTP.close_client(client)
end
AGC
            (hash-ref ports 'http) (hash-ref ports 'http) (hash-ref ports 'http) (hash-ref ports 'http)
            (hash-ref ports 'http) (hash-ref ports 'http)))
          "false\nhello\nfalse\nfalse\nhello\nfalse\n"))))
    (test-case "client receives progressive response bytes before a blocked upload finishes"
      (with-peers
       (lambda (ports)
         (with-program-server
          (format
           #<<AGC
def produce(n: Int, writer: HttpWriter) -> Result[Nil]
  try HTTP.write(writer, "first", 1000)
  IO.gets!()
  return HTTP.write(writer, "last", 1000)
end
def main() -> Nil
  client = Result.unwrap!(HTTP.client())
  response = Result.unwrap!(HTTP.request_stream(client, "POST", "http://localhost:~a/duplex", [], -1, &produce, 0))
  bytes: List[Int] = []
  while List.size(bytes) < 5
    part = Result.unwrap!(HTTP.read(response.body, 5 - List.size(bytes), 1000))
    for byte in part
      bytes = List.append(bytes, byte)
    end
  end
  if Result.unwrap!(String.from_bytes(bytes)) != "first"
    System.exit(3)
  end
  puts(String.from_int(List.size(bytes)))
  IO.flush()
  if Result.unwrap!(HTTP.text(response.body, 2000)) != "last"
    System.exit(4)
  end
  HTTP.close_client(client)
end
AGC
           (hash-ref ports 'http))
          (lambda (count) (check-equal? count 5))))))
    (test-case "independent Node clients check HTTP and HTTPS servers, chunked uploads and persistent connections through CLI"
      (for ([secure? '(#f #t)])
        (with-program-server (server-program secure?)
          (lambda (port) (check-equal? (node-client "client" port secure?) "clients ok\n")))))))
