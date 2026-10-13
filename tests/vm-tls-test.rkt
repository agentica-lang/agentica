#lang racket

(require rackunit
         json
         racket/runtime-path
         "vm-diff-common.rkt")

(define-runtime-path peer-file "fixtures/tls-peer.js")
(define-runtime-path python-peer-file "fixtures/tls-peer.py")
(define-runtime-path certs "fixtures/tls")
(define node (find-executable-path "node"))
(define python (find-executable-path "python3"))
(define wait-seconds 30)

(for ([name '(#"AGENTICA_VM_TRACE" #"AGENTICA_VM_TRACE_FILE" #"SSL_CERT_FILE" #"SSL_CERT_DIR")])
  (environment-variables-set! (current-environment-variables) name #f))

(define (peers-ready?)
  (cond
    [(and node python) #t]
    [(getenv "CI") (error 'vm-tls "Node and Python 3 are required in CI")]
    [else (displayln "SKIP VM TLS tests: node or python3 is unavailable") #f]))

(define (next-line port)
  (define line (sync/timeout wait-seconds (read-line-evt port 'linefeed)))
  (unless (string? line) (error 'vm-tls "no line within ~a s: ~s" wait-seconds line))
  line)

(define (stop process . ports)
  (when (eq? (subprocess-status process) 'running) (subprocess-kill process #t))
  (subprocess-wait process)
  (for-each close-input-port ports))

(define (with-peer thunk)
  (define-values (process out in err) (subprocess #f #f (current-error-port) node peer-file "servers"))
  (dynamic-wind
    void
    (lambda ()
      (close-output-port in)
      (thunk (string->jsexpr (next-line out))))
    (lambda () (stop process out))))

(define (compile-text work name text)
  (define source (build-path work (string-append name ".agc")))
  (define bytecode (build-path work (string-append name ".agcb")))
  (display-to-file text source #:exists 'replace)
  (compile-file source bytecode)
  bytecode)

(define (vm-environment [env '()])
  (define environment (environment-variables-copy (current-environment-variables)))
  (for ([pair (in-list (list* (cons #"LC_ALL" #"C.UTF-8") (cons #"LANG" #"C.UTF-8") (cons #"LC_MESSAGES" #f) env))])
    (environment-variables-set! environment (car pair) (cdr pair)))
  environment)

(define (run-bytecode bytecode #:env [env '()] . args)
  (parameterize ([current-environment-variables (vm-environment env)])
    (apply run-process vm-file #:timeout run-timeout "--" (path->string bytecode) args)))

(define (run-vm-text work name text #:env [env '()])
  (run-bytecode (compile-text work name text) #:env env (path->string certs)))

(define (start-vm bytecode . args)
  (parameterize ([current-environment-variables (vm-environment)])
    (apply subprocess #f #f #f vm-file "--" (path->string bytecode) args)))

(define (check-lines text expected message)
  (define lines (string-split text "\n" #:trim? #f))
  (define actual (if (and (pair? lines) (equal? (last lines) "")) (drop-right lines 1) lines))
  (check-equal? (length actual) (length expected) (string-append message "\n" text))
  (for ([line (in-list actual)] [want (in-list expected)])
    (if (string? want)
        (check-equal? line want message)
        (check-true (string-prefix? line (cadr want)) (format "~a: ~s should start with ~s" message line (cadr want))))))

(define (finished? process)
  (and (sync/timeout wait-seconds process) #t))

(define (client-program ports)
  (define (port name) (hash-ref ports (string->symbol name)))
  (define (dial name [host "localhost"]) (format "TLS.connect(~s, ~a, ca, 5000)" host (port name)))
  (string-append
   "def show(r: Result[Socket]) -> Void\n  case r\n    ok(_) -> puts(\"ok\")\n    error(m) -> puts(m)\n  end\nend\n\n"
   "def main() -> Void\n"
   "  ca = \"#{System.args()[0]}/ca.pem\"\n"
   (format "  echo = Result.unwrap!(~a)\n" (dial "echo"))
   "  Result.unwrap!(TCP.send_bytes(echo, [195], 5000))\n"
   "  Result.unwrap!(TCP.send_bytes(echo, [177, 10], 5000))\n"
   "  puts(Result.unwrap!(TCP.read_line(echo, 5000)))\n"
   "  TCP.close(echo)\n"
   (format "  pieces = Result.unwrap!(~a)\n" (dial "fragments" "127.0.0.1"))
   "  puts(Result.unwrap!(TCP.read_line(pieces, 5000)))\n"
   "  IO.inspect(TCP.read_line(pieces, 5000))\n"
   "  IO.inspect(TCP.read_line(pieces, 5000))\n"
   "  IO.inspect(TCP.recv_bytes(pieces, 4, 5000))\n"
   "  TCP.close(pieces)\n"
   (format "  abrupt = Result.unwrap!(~a)\n" (dial "abrupt"))
   "  IO.inspect(TCP.read_line(abrupt, 5000))\n"
   "  IO.inspect(TCP.read_line(abrupt, 5000))\n"
   "  IO.inspect(TCP.read_line(abrupt, 5000))\n"
   (format "  reset = Result.unwrap!(~a)\n" (dial "reset"))
   "  Result.unwrap!(TCP.send(reset, \"x\", 5000))\n"
   "  IO.inspect(TCP.read_line(reset, 5000))\n"
   "  TCP.close(reset)\n"
   (format "  big = Result.unwrap!(~a)\n" (dial "big"))
   "  puts(String.length(Result.unwrap!(TCP.read_line(big, 5000))))\n"
   "  Result.unwrap!(TCP.send(big, String.join(List.repeat(\"b\", 100000), \"\") + \"\\n\", 5000))\n"
   "  puts(Result.unwrap!(TCP.read_line(big, 5000)))\n"
   "  TCP.close(big)\n"
   (format "  long = Result.unwrap!(~a)\n" (dial "long"))
   "  IO.inspect(TCP.read_line(long, 5000))\n"
   "  IO.inspect(TCP.read_line(long, 5000))\n"
   (format "  silent = Result.unwrap!(~a)\n" (dial "silent"))
   "  IO.inspect(TCP.read_line(silent, 100))\n"
   "  IO.inspect(TCP.send(silent, \"x\", 1000))\n"
   (format "  show(~a)\n" (dial "wrong"))
   (format "  show(~a)\n" (dial "expired"))
   (format "  show(~a)\n" (dial "self"))
   (format "  show(~a)\n" (dial "old"))
   (format "  show(~a)\n" (dial "plain"))
   (format "  show(TLS.connect(\"localhost\", ~a, ca, 200))\n" (port "stall"))
   (format "  show(TLS.connect(\"localhost\", ~a, \"\", 5000))\n" (port "echo"))
   "end\n"))

(define server-program
  #<<AGC
def serve(socket: Socket) -> Void
  line = TCP.read_line(socket, 10000)
  while Result.ok?(line)
    Result.unwrap!(TCP.send(socket, "hello #{Result.unwrap!(line)}\n", 10000))
    line = TCP.read_line(socket, 10000)
  end
  TCP.close(socket)
end

def main() -> Void
  dir = System.args()[0]
  listener = Result.unwrap!(TLS.listen("127.0.0.1", 0, "#{dir}/server.pem", "#{dir}/server-key.pem"))
  puts(TCP.local_port(listener))
  IO.flush()
  a = Task.spawn(&serve, Result.unwrap!(TCP.accept(listener, 10000)))
  b = Task.spawn(&serve, Result.unwrap!(TCP.accept(listener, 10000)))
  Task.await(a)
  Task.await(b)
  puts("served")
  IO.flush()
  bad = TCP.accept(listener, 10000)
  puts(Result.message(bad))
  IO.flush()
  serve(Result.unwrap!(TCP.accept(listener, 10000)))
  TCP.close_listener(listener)
  puts("done")
end
AGC
  )

(define python-client-program
  #<<AGC
def main() -> Void
  dir = System.args()[0]
  port = String.to_int!(Result.unwrap!(IO.gets()))
  socket = Result.unwrap!(TLS.connect("localhost", port, "#{dir}/ca.pem", 5000))
  Result.unwrap!(TCP.send(socket, "from agentica\n", 5000))
  puts(Result.unwrap!(TCP.read_line(socket, 5000)))
  IO.inspect(TCP.read_line(socket, 5000))
  TCP.close(socket)
end
AGC
  )

(define https-goodbye-program
  #<<AGC
import "std/http" as HTTP

struct Call
  pool: HttpClient
  url: String
end

def hang(call: Call) -> Result[HttpResponse]
  return HTTP.get(call.pool, call.url)
end

def main() -> Void
  base = "https://localhost:#{Result.unwrap!(IO.gets())}"
  options = HttpClientOptions(timeout_ms: 20000, idle_timeout_ms: 20000, max_connections: 4, max_body_bytes: 1024, ca_file: "#{System.args()[0]}/ca.pem")
  pool = Result.unwrap!(HTTP.client(options))
  puts(Result.unwrap!(HTTP.get(pool, "#{base}/a")).body)
  Task.spawn(&hang, Call(pool: pool, url: "#{base}/hang"))
  puts(Result.unwrap!(HTTP.get(pool, "#{base}/ping")).body)
end
AGC
  )

(define handshake-program
  #<<AGC
struct Dial
  port: Int
  ca: String
end

def dial(d: Dial) -> Result[Socket]
  return TLS.connect("localhost", d.port, d.ca, 5000)
end

def show(dir: String, r: Result[Socket]) -> String
  case r
    ok(_) -> return "ok"
    error(message) -> return String.replace(message, dir, "<tls>")
  end
end

def handshake(dir: String, name: String, ca: String) -> Void
  listener = Result.unwrap!(TLS.listen("127.0.0.1", 0, "#{dir}/#{name}.pem", "#{dir}/#{name}-key.pem"))
  task = Task.spawn(&dial, Dial(port: TCP.local_port(listener), ca: ca))
  accepted = TCP.accept(listener, 5000)
  puts("#{name}: #{show(dir, Task.await(task))}")
  puts("  server: #{show(dir, accepted)}")
  TCP.close_listener(listener)
end

def plain_server(listener: Listener) -> Void
  socket = Result.unwrap!(TCP.accept(listener, 5000))
  Result.unwrap!(TCP.send(socket, "hello\n", 5000))
  TCP.recv_bytes(socket, 4096, 5000)
  TCP.close(socket)
end

def main() -> Void
  dir = System.args()[0]
  ca = "#{dir}/ca.pem"
  handshake(dir, "server", ca)
  handshake(dir, "wrong-host", ca)
  handshake(dir, "server", "#{dir}/self-signed.pem")
  IO.inspect(TLS.listen("127.0.0.1", 0, "#{dir}/server-key.pem", "#{dir}/server-key.pem").ok?)
  IO.inspect(TLS.listen("127.0.0.1", 0, "#{dir}/server.pem", "#{dir}/server.pem").ok?)
  puts(show(dir, TLS.connect("localhost", 443, "#{dir}/missing.pem", 1000)))
  plain = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  server = Task.spawn(&plain_server, plain)
  puts("plain server: #{show(dir, TLS.connect("127.0.0.1", TCP.local_port(plain), ca, 5000))}")
  Task.await(server)
  secure = Result.unwrap!(TLS.listen("127.0.0.1", 0, "#{dir}/server.pem", "#{dir}/server-key.pem"))
  raw = Result.unwrap!(TCP.connect("127.0.0.1", TCP.local_port(secure), 5000))
  Result.unwrap!(TCP.send(raw, "GET / HTTP/1.1\r\nHost: x\r\n\r\n", 5000))
  puts("plain client: #{show(dir, TCP.accept(secure, 5000))}")
end
AGC
  )

(define limits-program
  #<<AGC
def connect(port: Int) -> Socket
  return Result.unwrap!(TLS.connect("localhost", port, "#{System.args()[0]}/ca.pem", 5000))
end

def main() -> Void
  dir = System.args()[0]
  listener = Result.unwrap!(TLS.listen("127.0.0.1", 0, "#{dir}/server.pem", "#{dir}/server-key.pem"))
  task = Task.spawn(&connect, TCP.local_port(listener))
  quiet = Result.unwrap!(TCP.accept(listener, 5000))
  waiting = Task.await(task)
  IO.inspect(TCP.read_line(waiting, 30))
  IO.inspect(TCP.recv_bytes(waiting, 1, 1000))
  raw = Result.unwrap!(TCP.connect("127.0.0.1", TCP.local_port(listener), 5000))
  IO.inspect(TCP.accept(listener, 30))
  TCP.close(raw)
  TCP.close(quiet)
  TCP.close_listener(listener)
  IO.inspect(TCP.accept(listener, 1000))
end
AGC
  )

(define exit-program
  #<<AGC
struct Flood
  socket: Socket
  chunk: String
end

def connect(port: Int) -> Socket
  return Result.unwrap!(TLS.connect("localhost", port, "#{System.args()[0]}/ca.pem", 5000))
end

def hold(socket: Socket) -> Result[String]
  return TCP.read_line(socket, 5000)
end

def wait_accept(listener: Listener) -> Bool
  return Result.ok?(TCP.accept(listener, 5000))
end

def flood(job: Flood) -> Result[Void]
  return TCP.send(job.socket, job.chunk, 5000)
end

def started(n: Int) -> Int
  return n
end

def main() -> Void
  dir = System.args()[0]
  listener = Result.unwrap!(TLS.listen("127.0.0.1", 0, "#{dir}/server.pem", "#{dir}/server-key.pem"))
  port = TCP.local_port(listener)
  first = Task.spawn(&connect, port)
  silent = Result.unwrap!(TCP.accept(listener, 5000))
  quiet = Task.await(first)
  second = Task.spawn(&connect, port)
  sink = Result.unwrap!(TCP.accept(listener, 5000))
  source = Task.await(second)
  raw = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  Task.spawn(&hold, quiet)
  Task.spawn(&wait_accept, listener)
  Task.spawn(&flood, Flood(socket: source, chunk: String.join(List.repeat(String.join(List.repeat("abcdefgh", 128), ""), 8192), "")))
  Task.await(Task.spawn(&started, 0))
  IO.inspect(silent)
  IO.inspect(sink)
  IO.inspect(raw)
  puts("done")
end
AGC
  )

(define trust-program
  #<<AGC
def main() -> Void
  dir = System.args()[0]
  listener = Result.unwrap!(TLS.listen("127.0.0.1", 0, "#{dir}/server.pem", "#{dir}/server-key.pem"))
  task = Task.spawn(&accept_one, listener)
  IO.inspect(Result.ok?(TLS.connect("localhost", TCP.local_port(listener), "", 5000)))
  Task.await(task)
end

def accept_one(listener: Listener) -> Bool
  return Result.ok?(TCP.accept(listener, 5000))
end
AGC
  )

(module+ test
  (when (and (peers-ready?) (vm-built? "VM TLS tests"))
    (define work (make-temporary-directory "agentica-vm-tls~a"))
    (dynamic-wind
      void
      (lambda ()
        (test-case "the VM client against Node TLS servers: data, EOF, resets, limits, timeouts and verify errors"
          (with-peer
           (lambda (ports)
             (define result (run-vm-text work "client" (client-program ports)))
             (check-equal? (first result) 0 (third result))
             (check-lines
              (second result)
              (list
               "ñ"
               "ñ😀"
               "ok(\"tail\")"
               "error(\"network: end of input\")"
               "ok([])"
               "ok(\"abc\")"
               "ok(\"partial\")"
               "error(\"network: end of input\")"
               '(prefix "error(\"error reading from stream port\\n  system error: ")
               "100000"
               "100000 true"
               "error(\"network: line exceeds 1048576 bytes\")"
               "error(\"network: socket is closed\")"
               "error(\"network: operation timed out\")"
               "error(\"network: socket is closed\")"
               "ssl-connect: connect failed (certificate verify failed: hostname mismatch)"
               "ssl-connect: connect failed (certificate verify failed: certificate has expired)"
               "ssl-connect: connect failed (certificate verify failed: self-signed certificate)"
               '(prefix "ssl-connect: connect failed (")
               '(prefix "ssl-connect: connect failed (")
               "network: operation timed out"
               "ssl-connect: connect failed (certificate verify failed: unable to get local issuer certificate)")
              (third result)))))

        (test-case "SSL_CERT_FILE is the trust store when ca_file is empty"
          (define trusted
            (run-vm-text work "trust" trust-program
                         #:env (list (cons #"SSL_CERT_FILE" (path->bytes (build-path certs "ca.pem"))))))
          (check-equal? (take trusted 2) (list 0 "true\n") (third trusted))
          (define untrusted
            (run-vm-text work "trust" trust-program
                         #:env (list (cons #"SSL_CERT_FILE" (path->bytes (build-path certs "self-signed.pem"))))))
          (check-equal? (take untrusted 2) (list 0 "false\n") (third untrusted)))

        (test-case "a VM TLS server serves Node clients (TLS 1.3 and 1.2) and Python, and fails an untrusting client's accept"
          (define bytecode (compile-text work "server" server-program))
          (define-values (process out in err) (start-vm bytecode (path->string certs)))
          (define helpers '())
          (define (helper . args)
            (define-values (started helper-out helper-in helper-err) (apply subprocess #f #f #f args))
            (set! helpers (cons (list started helper-out helper-err) helpers))
            (close-output-port helper-in)
            (check-true (finished? started) (format "~a finishes" args))
            (check-equal? (subprocess-status started) 0 (port->string helper-err))
            (port->string helper-out))
          (dynamic-wind
            void
            (lambda ()
              (close-output-port in)
              (define port (next-line out))
              (check-equal? (helper node peer-file "clients" port) "clients ok\nuntrusting UNABLE_TO_VERIFY_LEAF_SIGNATURE\n")
              (check-equal? (next-line out) "served")
              (check-true (string-prefix? (next-line out) "port->ssl-ports: accept failed ("))
              (check-equal? (helper python python-peer-file "client" port) "hello python TLSv1.3\n")
              (check-equal? (next-line out) "done")
              (check-true (finished? process) "the VM server finishes")
              (check-equal? (subprocess-status process) 0 (port->string err)))
            (lambda ()
              (for ([h helpers]) (apply stop h))
              (stop process out err))))

        (test-case "the VM client against a Python TLS 1.2 server, closed with close_notify"
          (define-values (server server-out server-in server-err)
            (subprocess #f #f (current-error-port) python python-peer-file "server"))
          (dynamic-wind
            void
            (lambda ()
              (close-output-port server-in)
              (define port (next-line server-out))
              (define bytecode (compile-text work "python-client" python-client-program))
              (define result
                (parameterize ([current-environment-variables (vm-environment)])
                  (run-process vm-file #:timeout run-timeout #:input (string->bytes/utf-8 (string-append port "\n"))
                               "--" (path->string bytecode) (path->string certs))))
              (check-equal? (take result 2)
                            (list 0 "python TLSv1.2 FROM AGENTICA\nerror(\"network: end of input\")\n")
                            (third result))
              (check-true (finished? server))
              (check-equal? (subprocess-status server) 0))
            (lambda () (stop server server-out))))

        (test-case "main returns with an idle and an active HTTPS client connection: both get close_notify"
          (define-values (server server-out server-in server-err)
            (subprocess #f #f (current-error-port) python python-peer-file "http"))
          (dynamic-wind
            void
            (lambda ()
              (close-output-port server-in)
              (define port (next-line server-out))
              (define bytecode (compile-text work "https-goodbye" https-goodbye-program))
              (define result
                (parameterize ([current-environment-variables (vm-environment)])
                  (run-process vm-file #:timeout run-timeout #:input (string->bytes/utf-8 (string-append port "\n"))
                               "--" (path->string bytecode) (path->string certs))))
              (check-equal? (take result 2) (list 0 "ok\nok\n") (third result))
              (check-equal? (list (next-line server-out) (next-line server-out))
                            (list "close_notify /hang" "close_notify /ping"))
              (check-true (finished? server))
              (check-equal? (subprocess-status server) 0))
            (lambda () (stop server server-out))))

        (test-case "handshake and load errors on both sides of a VM client and server"
          (define result (run-vm-text work "handshakes" handshake-program))
          (check-equal? (first result) 0 (third result))
          (check-lines (second result)
                       (list "server: ok"
                             "  server: ok"
                             "wrong-host: ssl-connect: connect failed (certificate verify failed: hostname mismatch)"
                             '(prefix "  server: port->ssl-ports: accept failed (")
                             "server: ssl-connect: connect failed (certificate verify failed: unable to get local issuer certificate)"
                             '(prefix "  server: port->ssl-ports: accept failed (")
                             "false"
                             "false"
                             "ssl-load-verify-source!: load failed from: \"<tls>/missing.pem\""
                             '(prefix "  system error: ")
                             '(prefix "plain server: ssl-connect: connect failed (")
                             '(prefix "plain client: port->ssl-ports: accept failed ("))
                       (third result)))

        (test-case "timeouts close a TLS socket, a pending handshake times out, a closed listener stays closed"
          (define result (run-vm-text work "limits" limits-program))
          (check-equal? (take result 2)
                        (list 0
                              (string-append
                               "error(\"network: operation timed out\")\n"
                               "error(\"network: socket is closed\")\n"
                               "error(\"network: operation timed out\")\n"
                               "error(\"network: listener is closed\")\n"))
                        (third result)))

        (test-case "main returns while TLS tasks wait: the run ends without draining them"
          (define trace (build-path work "exit.trace"))
          (define bytecode (compile-text work "exit" exit-program))
          (define result
            (run-bytecode bytecode
                          #:env (list (cons #"AGENTICA_VM_TRACE" #"io,tls")
                                      (cons #"AGENTICA_VM_TRACE_FILE" (path->bytes trace)))
                          (path->string certs)))
          (check-equal? (take result 2) (list 0 "<Socket>\n<Socket>\n<Socket>\ndone\n") (third result))
          (define lines (file->lines trace))
          (define (count rx) (for/sum ([line (in-list lines)]) (if (regexp-match? rx line) 1 0)))
          (check-equal? (count #rx" io end code=0 signal=0$") 1 (string-join lines "\n"))
          (check-equal? (count #rx" tls tls_handshake_done ") 4)
          (check-equal? (count #rx" tls tls_handshake socket=0 listener=[0-9]+ role=server$") 3)))
      (lambda () (delete-directory/files work)))))
