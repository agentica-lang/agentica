#lang racket

(require rackunit
         json
         racket/runtime-path
         "vm-diff-common.rkt")

(define-runtime-path peer-file "fixtures/http-peer.py")
(define-runtime-path certs "fixtures/tls")
(define python (find-executable-path "python3"))
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
import "std/http" as Web

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
  response = try Web.get(f.pool, f.url)
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
  pool = Result.unwrap!(Web.client(options(5000, 1, 1000, "")))
  hello = Result.unwrap!(Web.get(pool, plain + "/hello"))
  puts("#{hello.status} #{hello.body} #{Web.header_values(hello.headers, "X-MULTI")}")
  show(Web.get(pool, plain + "/chunked"))
  first = Result.unwrap!(Web.get(pool, plain + "/port")).body
  show(Web.post(pool, plain + "/post", [Header(name: "X-Kind", value: "form")], "a=1&b=ñ"))
  puts(Result.unwrap!(Web.get(pool, plain + "/port")).body == first)
  show(Web.get(pool, plain + "/close"))
  puts(Result.unwrap!(Web.get(pool, plain + "/port")).body != first)
  show(Web.get(pool, plain + "/nothing"))
  Web.close_client(pool)
  slow = Result.unwrap!(Web.client(options(200, 1, 1000, "")))
  show(Web.get(slow, plain + "/slow"))
  one = Result.unwrap!(Web.client(options(5000, 1, 1000, "")))
  a = Task.spawn(&fetch, Fetch(pool: one, url: plain + "/port"))
  b = Task.spawn(&fetch, Fetch(pool: one, url: plain + "/port"))
  c = Task.spawn(&fetch, Fetch(pool: one, url: plain + "/port"))
  puts(same(a, b, c))
  three = Result.unwrap!(Web.client(options(5000, 3, 1000, "")))
  a = Task.spawn(&fetch, Fetch(pool: three, url: plain + "/gate"))
  b = Task.spawn(&fetch, Fetch(pool: three, url: plain + "/gate"))
  c = Task.spawn(&fetch, Fetch(pool: three, url: plain + "/gate"))
  puts(apart(a, b, c))
  closing = Result.unwrap!(Web.client(options(5000, 1, 1000, "")))
  pending = Task.spawn(&fetch, Fetch(pool: closing, url: plain + "/slow"))
  Web.close_client(closing)
  IO.inspect(Task.await(pending))
end
AGC
  )

(define tls-program
  #<<AGC
def main() -> Void
  certs = System.args()[0]
  port = System.args()[2]
  secure = Result.unwrap!(Web.client(options(5000, 1, 1000, certs + "/ca.pem")))
  show(Web.get(secure, "https://localhost:#{port}/hello"))
  show(Web.get(secure, "https://LOCALHOST:#{port}/hello"))
  show(Web.post(secure, "https://127.0.0.1:#{port}/post", [], "over tls"))
  show(Web.get(secure, "http://localhost:#{port}/hello"))
  show(Web.get(Result.unwrap!(Web.client(options(5000, 1, 1000, certs + "/self-signed.pem"))), "https://localhost:#{port}/hello"))
  show(Web.get(Result.unwrap!(Web.client(options(5000, 1, 1000, certs + "/missing.pem"))), "https://localhost:#{port}/hello"))
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
  large = Result.unwrap!(Web.client(options(5000, 1, 8388608, "")))
  show(Web.post(large, raw + "/early", [], upload))
  hostile = Result.unwrap!(Web.client(options(5000, 1, 1000, "")))
  for path in ["/http10", "/status99", "/status600", "/upgrade", "/interim15", "/interim16", "/badchunk", "/atlimit", "/big", "/bigchunks", "/barelf", "/fold", "/twolengths", "/smuggle", "/gzip", "/badtrailer", "/truncated", "/headerless"]
    show(Web.get(hostile, raw + path))
  end
end
AGC
  )

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
                                '(prefix "error reading from stream port | ")
                                "ssl-connect: connect failed (certificate verify failed: unable to get local issuer certificate)"
                                '(prefix "ssl-load-verify-source!: load failed from: "))
                          "tls"))

           (test-case "the VM client against hostile raw responses, and a 413 that comes before the upload ends"
             (check-lines (run-program work "raw" raw-program ports)
                          (list "413 big! 4"
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
                                "http: connection closed before the response was complete")
                          "raw")))))
      (lambda () (delete-directory/files work)))))
