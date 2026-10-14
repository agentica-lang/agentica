#lang racket

(require rackunit
         json
         racket/runtime-path
         "vm-diff-common.rkt")

(define-runtime-path peer-file "fixtures/tcp-peer.js")
(define node (find-executable-path "node"))
(define wait-seconds 30)

(define (node-ready?)
  (cond
    [node #t]
    [(getenv "CI") (error 'vm-tcp "Node is required in CI")]
    [else (displayln "SKIP VM TCP tests: node is unavailable") #f]))

(define (next-line port)
  (define line (sync/timeout wait-seconds (read-line-evt port 'linefeed)))
  (unless (string? line) (error 'vm-tcp "no line within ~a s: ~s" wait-seconds line))
  line)

(define (with-peer thunk)
  (define-values (process out in err) (subprocess #f #f (current-error-port) node peer-file "servers"))
  (dynamic-wind
    void
    (lambda ()
      (close-output-port in)
      (thunk (string->jsexpr (next-line out)) out))
    (lambda ()
      (when (eq? (subprocess-status process) 'running) (subprocess-kill process #t))
      (subprocess-wait process)
      (close-input-port out))))

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

(define (run-vm-text work name text #:env [env '()])
  (define bytecode (compile-text work name text))
  (parameterize ([current-environment-variables (vm-environment env)])
    (run-process vm-file #:timeout run-timeout "--" (path->string bytecode))))

(define (start-vm bytecode)
  (parameterize ([current-environment-variables (vm-environment)])
    (subprocess #f #f #f vm-file "--" (path->string bytecode))))

(define (stop process . ports)
  (when (eq? (subprocess-status process) 'running) (subprocess-kill process #t))
  (subprocess-wait process)
  (for-each close-input-port ports))

(define (finished? process)
  (and (sync/timeout wait-seconds process) #t))

(define (localhost-has-ipv6?)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define listener (tcp-listen 0 4 #t "localhost"))
    (define-values (_host port _peer _peer-port) (tcp-addresses listener #t))
    (dynamic-wind
      void
      (lambda ()
        (define-values (in out) (tcp-connect "::1" port))
        (close-input-port in)
        (close-output-port out)
        #t)
      (lambda () (tcp-close listener)))))

(define (client-program ports)
  (define (port name) (hash-ref ports name))
  (format
   #<<AGC
def main() -> Void
  echo = Result.unwrap!(TCP.connect("localhost", ~a, 5000))
  Result.unwrap!(TCP.send_bytes(echo, [195], 5000))
  Result.unwrap!(TCP.send_bytes(echo, [177, 10], 5000))
  puts(Result.unwrap!(TCP.read_line(echo, 5000)))
  TCP.close(echo)
  pieces = Result.unwrap!(TCP.connect("127.0.0.1", ~a, 5000))
  puts(Result.unwrap!(TCP.read_line(pieces, 5000)))
  IO.inspect(TCP.read_line(pieces, 5000))
  IO.inspect(TCP.read_line(pieces, 5000))
  IO.inspect(TCP.recv_bytes(pieces, 4, 5000))
  TCP.close(pieces)
  reset = Result.unwrap!(TCP.connect("127.0.0.1", ~a, 5000))
  Result.unwrap!(TCP.send(reset, "x", 5000))
  IO.inspect(TCP.read_line(reset, 5000))
  TCP.close(reset)
  long = Result.unwrap!(TCP.connect("127.0.0.1", ~a, 5000))
  IO.inspect(TCP.read_line(long, 5000))
  IO.inspect(TCP.read_line(long, 5000))
  silent = Result.unwrap!(TCP.connect("127.0.0.1", ~a, 5000))
  IO.inspect(TCP.read_line(silent, 100))
  IO.inspect(TCP.send(silent, "x", 1000))
  stuck = Result.unwrap!(TCP.connect("127.0.0.1", ~a, 5000))
  big = "abcdefgh"
  round = 0
  while round < 22
    big = big + big
    round = round + 1
  end
  IO.inspect(TCP.send(stuck, big, 200))
  IO.inspect(TCP.send(stuck, "x", 1000))
  partial = Result.unwrap!(TCP.connect("127.0.0.1", ~a, 5000))
  IO.inspect(TCP.read_line(partial, 5000))
  refused = TCP.connect("127.0.0.1", ~a, 5000)
  puts(Result.message(refused))
end
AGC
   (port 'echo) (port 'fragments) (port 'reset) (port 'long) (port 'silent) (port 'silent) (port 'partial)
   (port 'refused)))

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
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  puts(TCP.local_port(listener))
  IO.flush()
  a = Task.spawn_owning(&serve, Result.unwrap!(TCP.accept(listener, 10000)))
  b = Task.spawn_owning(&serve, Result.unwrap!(TCP.accept(listener, 10000)))
  Task.await(a)
  Task.await(b)
  TCP.close_listener(listener)
  puts("served")
end
AGC
  )

(define localhost-program
  #<<AGC
def main() -> Void
  listener = Result.unwrap!(TCP.listen("localhost", 0))
  puts(TCP.local_port(listener))
  IO.flush()
  line = ""
  while line != "end"
    socket = Result.unwrap!(TCP.accept(listener, 10000))
    line = Result.unwrap!(TCP.read_line(socket, 10000))
    puts(line)
    IO.flush()
    TCP.close(socket)
  end
  TCP.close_listener(listener)
end
AGC
  )

(define taken-program
  #<<AGC
def main() -> Void
  listener = TCP.listen("localhost", ~a)
  if Result.ok?(listener)
    puts("listening")
  else
    puts(Result.message(listener))
  end
end
AGC
  )

(define (writers-program ports)
  (format
   #<<AGC
struct Job
  socket: Socket
  text: String
end

def write(job: Job) -> Result[Void]
  return TCP.send(job.socket, job.text, 30000)
end

def fill(letter: String) -> String
  text = "#{letter}#{letter}#{letter}#{letter}#{letter}#{letter}#{letter}#{letter}"
  round = 0
  while round < 21
    text = text + text
    round = round + 1
  end
  return text
end

def main() -> Void
  socket = Result.unwrap!(TCP.connect("127.0.0.1", ~a, 5000))
  a = Task.spawn(&write, Job(socket: socket, text: fill("a")))
  b = Task.spawn(&write, Job(socket: socket, text: fill("b")))
  c = Task.spawn(&write, Job(socket: socket, text: fill("c")))
  IO.inspect(Task.await(a))
  IO.inspect(Task.await(b))
  IO.inspect(Task.await(c))
  TCP.close(socket)
end
AGC
   (hash-ref ports 'collect)))

(define (exit-program ports)
  (format
   #<<AGC
def hold(socket: Socket) -> Result[String]
  return TCP.read_line(socket, 60000)
end

def flood(socket: Socket) -> Void
  chunk = String.join(List.repeat("abcdefgh", 131072), "")
  while Result.ok?(TCP.send(socket, chunk, 60000))
  end
end

def wait_accept(listener: Listener) -> Bool
  return Result.ok?(TCP.accept(listener, 60000))
end

def main() -> Void
  watch = Result.unwrap!(TCP.connect("127.0.0.1", ~a, 5000))
  Task.spawn(&hold, Result.unwrap!(TCP.connect("127.0.0.1", ~a, 5000)))
  Task.spawn(&flood, Result.unwrap!(TCP.connect("127.0.0.1", ~a, 5000)))
  Task.spawn(&wait_accept, Result.unwrap!(TCP.listen("127.0.0.1", 0)))
  Task.sleep(200)
  IO.inspect(watch)
  puts("done")
end
AGC
   (hash-ref ports 'watch) (hash-ref ports 'silent) (hash-ref ports 'silent)))

(module+ test
  (when (and (node-ready?) (vm-built? "VM TCP tests"))
    (define work (make-temporary-directory "agentica-vm-tcp~a"))
    (dynamic-wind
      void
      (lambda ()
        (test-case "the VM client reads fragments, EOF, resets, long lines and timeouts from Node peers"
          (with-peer
           (lambda (ports _events)
             (define result (run-vm-text work "client" (client-program ports)))
             (check-equal? (first result) 0 (third result))
             (check-equal?
              (second result)
              (string-append
               "ñ\n"
               "ñ😀\n"
               "ok(\"tail\")\n"
               "error(\"network: end of input\")\n"
               "ok([])\n"
               "error(\"error reading from stream port\\n  system error: Connection reset by peer; errno=104\")\n"
               "error(\"network: line exceeds 1048576 bytes\")\n"
               "error(\"network: socket is closed\")\n"
               "error(\"network: operation timed out\")\n"
               "error(\"network: socket is closed\")\n"
               "error(\"network: operation timed out\")\n"
               "error(\"network: socket is closed\")\n"
               "error(\"error reading from stream port\\n  system error: Connection reset by peer; errno=104\")\n"
               (format "tcp-connect: connection failed\n  hostname: 127.0.0.1\n  port number: ~a\n  system error: Connection refused; errno=111\n"
                       (hash-ref ports 'refused)))))))

        (test-case "a VM server serves two Node clients at once, one task per connection"
          (define bytecode (compile-text work "server" server-program))
          (define-values (process out in err) (start-vm bytecode))
          (define peer #f)
          (define peer-ports '())
          (dynamic-wind
            void
            (lambda ()
              (close-output-port in)
              (define port (next-line out))
              (define-values (started peer-out peer-in peer-err) (subprocess #f #f #f node peer-file "clients" port))
              (set! peer started)
              (set! peer-ports (list peer-out peer-err))
              (close-output-port peer-in)
              (check-true (finished? peer) "the Node clients finish")
              (check-equal? (subprocess-status peer) 0 (port->string peer-err))
              (check-equal? (port->string peer-out) "clients ok\n")
              (check-equal? (next-line out) "served")
              (check-true (finished? process) "the VM server finishes")
              (check-equal? (subprocess-status process) 0 (port->string err)))
            (lambda ()
              (when peer (apply stop peer peer-ports))
              (stop process out err))))

        (test-case "a VM listener on localhost takes IPv4 and IPv6 clients"
          (define ipv6? (localhost-has-ipv6?))
          (define bytecode (compile-text work "localhost" localhost-program))
          (define-values (process out in err) (start-vm bytecode))
          (dynamic-wind
            void
            (lambda ()
              (close-output-port in)
              (define port (string->number (next-line out)))
              (define (send-line host text)
                (define-values (from to) (tcp-connect host port))
                (write-string (string-append text "\n") to)
                (close-output-port to)
                (close-input-port from))
              (send-line "127.0.0.1" "v4")
              (check-equal? (next-line out) "v4")
              (when ipv6?
                (send-line "::1" "v6")
                (check-equal? (next-line out) "v6"))
              (send-line "127.0.0.1" "end")
              (check-equal? (next-line out) "end")
              (check-true (finished? process) "the VM listener finishes")
              (check-equal? (subprocess-status process) 0 (port->string err)))
            (lambda () (stop process out err))))

        (test-case "a listen on localhost fails when another program holds the port on ::1"
          (if (localhost-has-ipv6?)
              (let* ([holder (tcp-listen 0 4 #f "::1")]
                     [port (let-values ([(_host port _peer _peer-port) (tcp-addresses holder #t)]) port)])
                (dynamic-wind
                  void
                  (lambda ()
                    (define result (run-vm-text work "taken" (format taken-program port)))
                    (check-equal? (first result) 0 (third result))
                    (check-true (string-prefix? (second result) "tcp-listen: listen failed\n  hostname: localhost\n")
                                (second result)))
                  (lambda () (tcp-close holder))))
              (displayln "SKIP held ::1 listen test: no IPv6 localhost")))

        (test-case "two tasks writing to one socket take the writer lock in FIFO order"
          (with-peer
           (lambda (ports events)
             (define trace (build-path work "writers.trace"))
             (define result
               (run-vm-text work "writers" (writers-program ports)
                            #:env (list (cons #"AGENTICA_VM_TRACE" #"io")
                                        (cons #"AGENTICA_VM_TRACE_FILE" (path->bytes trace)))))
             (check-equal? (take result 2) (list 0 "ok()\nok()\nok()\n") (third result))
             (define size (* 8 (expt 2 21)))
             (check-equal? (next-line events) (format "collect a=~a b=~a c=~a" size size size))
             (check-true (for/or ([line (in-list (file->lines trace))]) (regexp-match? #rx" io lock_wait " line))
                         "a writer waited for the lock"))))

        (test-case "main returns while tasks wait on sockets: the run ends and the peer sees every socket close"
          (with-peer
           (lambda (ports events)
             (define trace (build-path work "exit.trace"))
             (define started (current-inexact-milliseconds))
             (define result
               (run-vm-text work "exit" (exit-program ports)
                            #:env (list (cons #"AGENTICA_VM_TRACE" #"io")
                                        (cons #"AGENTICA_VM_TRACE_FILE" (path->bytes trace)))))
             (check-equal? (take result 2) (list 0 "<Socket>\ndone\n") (third result))
             (check-true (< (- (current-inexact-milliseconds) started) 20000))
             (define lines (file->lines trace))
             (define (seen? rx) (for/or ([line (in-list lines)]) (regexp-match? rx line)))
             (check-true (seen? #rx" io end code=0 signal=0$") (string-join lines "\n"))
             (check-true (seen? #rx" io tcp_listen listener=") "listen is traced")
             (check-true (seen? #rx" io tcp_connected socket=") "connect is traced")
             (check-equal? (next-line events) "closed watch")))))
      (lambda () (delete-directory/files work)))))
