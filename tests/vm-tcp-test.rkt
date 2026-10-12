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

(define (run-vm-text work name text #:env [env '()])
  (define bytecode (compile-text work name text))
  (define environment (environment-variables-copy (current-environment-variables)))
  (for ([pair (in-list env)])
    (environment-variables-set! environment (car pair) (cdr pair)))
  (parameterize ([current-environment-variables environment])
    (run-process vm-file #:timeout run-timeout "--" (path->string bytecode))))

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
  IO.inspect(TCP.read_line(reset, 5000))
  TCP.close(reset)
  long = Result.unwrap!(TCP.connect("127.0.0.1", ~a, 5000))
  IO.inspect(TCP.read_line(long, 5000))
  IO.inspect(TCP.read_line(long, 5000))
  silent = Result.unwrap!(TCP.connect("127.0.0.1", ~a, 5000))
  IO.inspect(TCP.read_line(silent, 100))
  IO.inspect(TCP.send(silent, "x", 1000))
  refused = TCP.connect("127.0.0.1", ~a, 5000)
  puts(Result.message(refused))
end
AGC
   (port 'echo) (port 'fragments) (port 'reset) (port 'long) (port 'silent) (port 'refused)))

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
  a = Task.spawn(&serve, Result.unwrap!(TCP.accept(listener, 10000)))
  b = Task.spawn(&serve, Result.unwrap!(TCP.accept(listener, 10000)))
  Task.await(a)
  Task.await(b)
  TCP.close_listener(listener)
  puts("served")
end
AGC
  )

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
               (format "tcp-connect: connection failed\n  hostname: 127.0.0.1\n  port number: ~a\n  system error: Connection refused; errno=111\n"
                       (hash-ref ports 'refused)))))))

        (test-case "a VM server serves two Node clients at once, one task per connection"
          (define bytecode (compile-text work "server" server-program))
          (define-values (process out in err) (subprocess #f #f #f vm-file "--" (path->string bytecode)))
          (dynamic-wind
            void
            (lambda ()
              (close-output-port in)
              (define port (next-line out))
              (define-values (peer peer-out peer-in peer-err) (subprocess #f #f #f node peer-file "clients" port))
              (close-output-port peer-in)
              (define peer-text (port->string peer-out))
              (define peer-errors (port->string peer-err))
              (subprocess-wait peer)
              (close-input-port peer-out)
              (close-input-port peer-err)
              (check-equal? (subprocess-status peer) 0 peer-errors)
              (check-equal? peer-text "clients ok\n")
              (check-equal? (next-line out) "served")
              (check-not-false (sync/timeout wait-seconds process))
              (check-equal? (subprocess-status process) 0 (port->string err)))
            (lambda ()
              (when (eq? (subprocess-status process) 'running) (subprocess-kill process #t))
              (subprocess-wait process)
              (close-input-port out)
              (close-input-port err))))

        (test-case "main returns while tasks wait on sockets: the run ends and every socket closes"
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
             (check-true (seen? #rx" io close resources=0 settled=1$") (string-join lines "\n"))
             (check-equal? (for/sum ([line (in-list lines)]) (if (regexp-match? #rx" io tcp_close .* why=exit$" line) 1 0))
                           4)
             (check-true (seen? #rx" io tcp_listen listener=") "listen is traced")
             (check-true (seen? #rx" io tcp_connected socket=") "connect is traced")
             (check-equal? (next-line events) "closed watch")))))
      (lambda () (delete-directory/files work)))))
