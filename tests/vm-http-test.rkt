#lang racket

(require rackunit
         json
         racket/runtime-path
         "vm-diff-common.rkt")

(define-runtime-path peer-file "fixtures/http-peer.py")
(define-runtime-path server-peer-file "fixtures/http-server-peer.py")
(define-runtime-path server-node-file "fixtures/http-server-peer.js")
(define-runtime-path certs "fixtures/tls")
(define python (find-executable-path "python3"))
(define node (find-executable-path "node"))
(define wait-seconds 30)

(for ([name '(#"AGENTICA_VM_TRACE" #"AGENTICA_VM_TRACE_FILE" #"SSL_CERT_FILE" #"SSL_CERT_DIR")])
  (environment-variables-set! (current-environment-variables) name #f))

(define (peer-ready?)
  (cond
    [python #t]
    [(getenv "CI") (error 'vm-http "Python 3 is required in CI")]
    [else (displayln "SKIP VM HTTP tests: python3 is unavailable") #f]))

(define (with-peer thunk)
  (define-values (process out in err) (subprocess #f #f (current-error-port) python peer-file))
  (dynamic-wind
    void
    (lambda ()
      (define line (sync/timeout wait-seconds (read-line-evt out 'linefeed)))
      (unless (string? line) (error 'vm-http "the peer printed no ports: ~s" line))
      (thunk (string->jsexpr line)))
    (lambda ()
      (close-output-port in)
      (unless (sync/timeout 5 process) (subprocess-kill process #t))
      (subprocess-wait process)
      (close-input-port out))))

(define (node-ready?)
  (cond
    [node #t]
    [(getenv "CI") (error 'vm-http "Node is required in CI")]
    [else (displayln "SKIP VM HTTP server tests with Node: node is unavailable") #f]))

(define (next-line port)
  (define line (sync/timeout wait-seconds (read-line-evt port 'linefeed)))
  (unless (string? line) (error 'vm-http "no line within ~a s: ~s" wait-seconds line))
  line)

(define (run-peer program . arguments)
  (define-values (process out in err) (apply subprocess #f #f #f program arguments))
  (close-output-port in)
  (define output (box ""))
  (define errors (box ""))
  (define readers
    (list (thread (lambda () (set-box! output (port->string out))))
          (thread (lambda () (set-box! errors (port->string err))))))
  (dynamic-wind
    void
    (lambda ()
      (unless (sync/timeout 120 process) (error 'vm-http "the peer did not finish"))
      (for-each thread-wait readers)
      (list (subprocess-status process) (string-split (unbox output) "\n") (unbox errors)))
    (lambda ()
      (when (eq? (subprocess-status process) 'running) (subprocess-kill process #t))
      (subprocess-wait process)
      (close-input-port out)
      (close-input-port err))))

(define (vm-environment)
  (define environment (environment-variables-copy (current-environment-variables)))
  (for ([pair (in-list (list (cons #"LC_ALL" #"C.UTF-8") (cons #"LANG" #"C.UTF-8") (cons #"LC_MESSAGES" #f)))])
    (environment-variables-set! environment (car pair) (cdr pair)))
  environment)

(define (run-program work name text ports)
  (define source (build-path work (string-append name ".agc")))
  (define bytecode (build-path work (string-append name ".agcb")))
  (display-to-file (string-append prelude text) source #:exists 'replace)
  (compile-file source bytecode)
  (parameterize ([current-environment-variables (vm-environment)])
    (apply run-process vm-file #:timeout run-timeout "--" (path->string bytecode) (path->string certs)
           (for/list ([key '(plain tls raw)]) (number->string (hash-ref ports key))))))

(define (check-lines result expected message)
  (check-equal? (first result) 0 (third result))
  (define lines (string-split (second result) "\n"))
  (check-equal? (length lines) (length expected) (string-append message "\n" (second result)))
  (for ([line (in-list lines)] [want (in-list expected)])
    (if (string? want)
        (check-equal? line want message)
        (check-true (string-prefix? line (cadr want)) (format "~a: ~s should start with ~s" message line (cadr want))))))

(define prelude
  #<<AGC
import "std/http" as HTTP

struct Fetch
  pool: HttpClient
  url: String
end

def options(timeout: Int, connections: Int, body: Int, ca: String) -> HttpClientOptions
  return HttpClientOptions(timeout_ms: timeout, idle_timeout_ms: 5000, max_connections: connections, max_body_bytes: body, ca_file: ca)
end

def short(body: String) -> String
  if String.length(body) > 20
    return String.slice(body, 0, 20)
  end
  return body
end

def show(r: Result[HttpResponse]) -> Void
  case r
    ok(response) -> puts("#{response.status} #{short(response.body)} #{String.length(response.body)}")
    error(message) -> puts(String.replace(message, "\n", " | "))
  end
end

def fetch(f: Fetch) -> Result[String]
  response = try HTTP.get(f.pool, f.url)
  return ok(response.body)
end

def same(a: Task[Result[String]], b: Task[Result[String]], c: Task[Result[String]]) -> Bool
  x = Result.unwrap!(Task.await(a))
  y = Result.unwrap!(Task.await(b))
  z = Result.unwrap!(Task.await(c))
  return x == y and y == z
end

def apart(a: Task[Result[String]], b: Task[Result[String]], c: Task[Result[String]]) -> Bool
  x = Result.unwrap!(Task.await(a))
  y = Result.unwrap!(Task.await(b))
  z = Result.unwrap!(Task.await(c))
  return x != y and y != z and x != z
end


AGC
  )

(define plain-program
  #<<AGC
def main() -> Void
  plain = "http://127.0.0.1:#{System.args()[1]}"
  pool = Result.unwrap!(HTTP.client(options(5000, 1, 1000, "")))
  hello = Result.unwrap!(HTTP.get(pool, plain + "/hello"))
  puts("#{hello.status} #{hello.body} #{HTTP.header_values(hello.headers, "X-MULTI")}")
  show(HTTP.get(pool, plain + "/chunked"))
  first = Result.unwrap!(HTTP.get(pool, plain + "/port")).body
  show(HTTP.post(pool, plain + "/post", [Header(name: "X-Kind", value: "form")], "a=1&b=ñ"))
  puts(Result.unwrap!(HTTP.get(pool, plain + "/port")).body == first)
  show(HTTP.get(pool, plain + "/close"))
  puts(Result.unwrap!(HTTP.get(pool, plain + "/port")).body != first)
  show(HTTP.get(pool, plain + "/nothing"))
  HTTP.close_client(pool)
  slow = Result.unwrap!(HTTP.client(options(200, 1, 1000, "")))
  show(HTTP.get(slow, plain + "/slow"))
  one = Result.unwrap!(HTTP.client(options(5000, 1, 1000, "")))
  a = Task.spawn(&fetch, Fetch(pool: one, url: plain + "/port"))
  b = Task.spawn(&fetch, Fetch(pool: one, url: plain + "/port"))
  c = Task.spawn(&fetch, Fetch(pool: one, url: plain + "/port"))
  puts(same(a, b, c))
  three = Result.unwrap!(HTTP.client(options(5000, 3, 1000, "")))
  a = Task.spawn(&fetch, Fetch(pool: three, url: plain + "/gate"))
  b = Task.spawn(&fetch, Fetch(pool: three, url: plain + "/gate"))
  c = Task.spawn(&fetch, Fetch(pool: three, url: plain + "/gate"))
  puts(apart(a, b, c))
  closing = Result.unwrap!(HTTP.client(options(5000, 1, 1000, "")))
  pending = Task.spawn(&fetch, Fetch(pool: closing, url: plain + "/hold"))
  watcher = Result.unwrap!(HTTP.client(options(5000, 1, 1000, "")))
  while Result.unwrap!(HTTP.get(watcher, plain + "/held")).body == "0"
    Task.sleep(1)
  end
  HTTP.close_client(closing)
  IO.inspect(Task.await(pending))
end
AGC
  )

(define tls-program
  #<<AGC
def main() -> Void
  certs = System.args()[0]
  port = System.args()[2]
  secure = Result.unwrap!(HTTP.client(options(5000, 1, 1000, certs + "/ca.pem")))
  show(HTTP.get(secure, "https://localhost:#{port}/hello"))
  show(HTTP.get(secure, "https://LOCALHOST:#{port}/hello"))
  show(HTTP.post(secure, "https://127.0.0.1:#{port}/post", [], "over tls"))
  show(HTTP.get(secure, "https://localhost:#{port}/notify"))
  show(HTTP.get(secure, "https://localhost:#{port}/close"))
  show(HTTP.get(secure, "http://localhost:#{port}/hello"))
  show(HTTP.get(Result.unwrap!(HTTP.client(options(5000, 1, 1000, certs + "/self-signed.pem"))), "https://localhost:#{port}/hello"))
  show(HTTP.get(Result.unwrap!(HTTP.client(options(5000, 1, 1000, certs + "/missing.pem"))), "https://localhost:#{port}/hello"))
end
AGC
  )

(define raw-program
  #<<AGC
def main() -> Void
  raw = "http://127.0.0.1:#{System.args()[3]}"
  upload = "x"
  while String.length(upload) < 4194304
    upload = upload + upload
  end
  large = Result.unwrap!(HTTP.client(options(5000, 1, 8388608, "")))
  show(HTTP.post(large, raw + "/early", [], upload))
  hostile = Result.unwrap!(HTTP.client(options(5000, 1, 1000, "")))
  stale = Result.unwrap!(HTTP.client(options(5000, 1, 1000, "")))
  show(HTTP.get(stale, raw + "/stale"))
  show(HTTP.post(stale, raw + "/after", [], "x"))
  show(HTTP.get(stale, raw + "/stale"))
  show(HTTP.get(stale, raw + "/after"))
  show(HTTP.request(stale, "HEAD", raw + "/headlength", [], ""))
  show(HTTP.get(stale, raw + "/after"))
  for path in ["/http10", "/status99", "/status600", "/upgrade", "/interim15", "/interim16", "/badchunk", "/atlimit", "/big", "/bigchunks", "/barelf", "/fold", "/twolengths", "/smuggle", "/gzip", "/badtrailer", "/truncated", "/headerless", "/nocontent", "/after"]
    show(HTTP.get(hostile, raw + path))
  end
end
AGC
  )

(define server-program
  #<<AGC
import "std/http" as HTTP

def handle(request: HttpRequest) -> Result[HttpResponse]
  if request.path == "/big"
    big = "x"
    while String.length(big) < 8388608
      big = big + big
    end
    return ok(HttpResponse(status: 200, headers: [], body: big))
  end
  return ok(HttpResponse(status: 200, headers: [], body: "#{request.method} #{request.path} #{request.body}"))
end

def main() -> Void
  options = HttpServerOptions(request_timeout_ms: 2000, idle_timeout_ms: 10000, max_connections: 2, max_body_bytes: 1024)
  server = Result.unwrap!(HTTP.listen("127.0.0.1", 0, &handle, options))
  certs = System.args()[0]
  secure = Result.unwrap!(HTTP.listen_tls("127.0.0.1", 0, certs + "/server.pem", certs + "/server-key.pem", &handle, options))
  puts("#{HTTP.local_port(server)} #{HTTP.local_port(secure)}")
  IO.flush()
  IO.read()
  HTTP.close_server(server)
  HTTP.close_server(secure)
  IO.inspect(HTTP.wait(server))
  IO.inspect(HTTP.wait(secure))
end
AGC
  )

(define server-python-lines
  '("length-and-chunked 400 closed"
    "two-lengths 400 closed"
    "equal-lengths 200 closed"
    "equal-length-list 200 closed"
    "gzip 501 closed"
    "gzip-chunked 501 closed"
    "two-encodings 501 closed"
    "huge-chunk 413 closed"
    "bad-chunk 400 closed"
    "bare-lf 400 closed"
    "long-line 431 closed"
    "long-head 431 closed"
    "headers-100 200 closed"
    "headers-101 431 closed"
    "headers-150 431 closed"
    "long-trailer 431 closed"
    "many-trailers 431 closed"
    "bad-trailer 400 closed"
    "http-1 505 closed"
    "http-2 505 closed"
    "http-1.10 505 closed"
    "http-2.0 505 closed"
    "http-1.0 505 closed"
    "http-2.0-headers 505 closed"
    "bad-version 400 closed"
    "leading-crlf 200 closed"
    "absolute-target 400 closed"
    "non-ascii-target 400 closed"
    "star-get 400 closed"
    "star-options 200 closed"
    "bad-method 400 closed"
    "connect 501 closed"
    "upgrade 501 closed"
    "fold 400 closed"
    "expect-other 417 closed"
    "over-limit 413 closed"
    "chunked-over-limit 413 closed"
    "non-utf8 400 closed"
    "no-host 400 closed"
    "two-hosts 400 closed"
    "short-505 505 closed quick"
    "bad-line-open 400 closed quick"
    "partial-head none closed bounded"
    "expect-over-limit HTTP/1.1 413 Content Too Large False closed"
    "expect-continue HTTP/1.1 100 Continue 200 POST /expect hello closed"
    "pipelined ['GET /one ', 'POST /two abc', 'GET /three '] closed"
    "client-chunked 200 POST /chunked abñcd"
    "client-head 200 11 b''"
    "client-again 200 GET /again  True"
    "slots 2 waiting"
    "slot-freed 200 GET /waiting  closed"
    "tls-keep-alive 200 GET /one  200 POST /two over tls True"
    "tls-silent closed bounded"
    "tls-plain closed"
    "flood bounded"))

(define server-node-lines
  '("node-chunked 200 true POST /chunked abñcd"
    "node-expect true 200 POST /expect hello"
    "node-keep-alive GET /first  GET /again  true true"
    "node-head 200 11 \"\""
    "node-concurrent 3 true"))

(define (check-server work)
  (define source (build-path work "server.agc"))
  (define bytecode (build-path work "server.agcb"))
  (display-to-file server-program source #:exists 'replace)
  (compile-file source bytecode)
  (define-values (process out in err)
    (parameterize ([current-environment-variables (vm-environment)])
      (subprocess #f #f #f vm-file "--" (path->string bytecode) (path->string certs))))
  (dynamic-wind
    void
    (lambda ()
      (define ports (string-split (next-line out)))
      (define port (first ports))
      (define python-run (run-peer python server-peer-file port "2" (second ports) (path->string certs)))
      (check-equal? (first python-run) 0 (third python-run))
      (check-equal? (second python-run) server-python-lines)
      (when (node-ready?)
        (define node-run (run-peer node server-node-file port "2"))
        (check-equal? (first node-run) 0 (third node-run))
        (check-equal? (second node-run) server-node-lines))
      (close-output-port in)
      (check-not-false (sync/timeout wait-seconds process) "the VM server finishes")
      (check-equal? (next-line out) "ok()")
      (check-equal? (next-line out) "ok()")
      (check-equal? (subprocess-status process) 0)
      (check-equal? (port->string err) ""))
    (lambda ()
      (unless (port-closed? in) (close-output-port in))
      (when (eq? (subprocess-status process) 'running) (subprocess-kill process #t))
      (subprocess-wait process)
      (close-input-port out)
      (close-input-port err))))

(module+ test
  (when (and (peer-ready?) (vm-built? "VM HTTP tests"))
    (define work (make-temporary-directory "agentica-vm-http~a"))
    (dynamic-wind
      void
      (lambda ()
        (with-peer
         (lambda (ports)
           (test-case "the VM client against ThreadingHTTPServer: keep-alive, chunked, close-delimited, timeout, pool limits"
             (check-lines (run-program work "plain" plain-program ports)
                          (list "200 hello 127.0.0.1 [\"a\", \"b\"]"
                                "200 ñandú chunks 12"
                                "200 form 8 a=1&b=ñ 14"
                                "true"
                                "200 until the end 13"
                                "true"
                                "404 missing 7"
                                "network: operation timed out"
                                "true"
                                "true"
                                "error(\"http: client is closed\")")
                          "plain"))

           (test-case "the VM client against a Python ssl server, with the client's ca_file"
             (check-lines (run-program work "tls" tls-program ports)
                          (list "200 hello localhost 15"
                                "200 hello localhost 15"
                                "200 None 8 over tls 15"
                                "200 closed cleanly 14"
                                "http: truncated HTTP body"
                                '(prefix "error reading from stream port | ")
                                '(prefix "ssl-connect: connect failed (certificate verify failed")
                                '(prefix "ssl-load-verify-source!: load failed from: "))
                          "tls"))

           (test-case "the VM client against hostile raw responses, and a 413 that comes before the upload ends"
             (check-lines (run-program work "raw" raw-program ports)
                          (list "413 big! 4"
                                "200 stale 5"
                                "http: connection closed before the response was complete"
                                "200 stale 5"
                                "200 ok 2"
                                "200  0"
                                "200 reused 6"
                                "http: HTTP version is unsupported"
                                "http: invalid HTTP head"
                                "http: invalid response status"
                                "http: protocol upgrades are unsupported"
                                "200 ok 2"
                                "http: too many interim responses"
                                "http: invalid chunk size"
                                "200 xxxxxxxxxxxxxxxxxxxx 1000"
                                "http: body exceeds max_body_bytes"
                                "http: body exceeds max_body_bytes"
                                "http: HTTP requires CRLF"
                                "http: folded HTTP header lines are not allowed"
                                "http: invalid content length"
                                "http: ambiguous HTTP body framing"
                                "http: unsupported transfer encoding"
                                "http: invalid trailer"
                                "http: truncated HTTP body"
                                "http: connection closed before the response was complete"
                                "204  0"
                                "200 ok 2")
                          "raw"))))
        (test-case "the VM server against Python raw sockets, Python http.client and Node http clients"
          (check-server work)))
      (lambda () (delete-directory/files work)))))
