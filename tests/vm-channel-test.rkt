#lang racket

(require rackunit
         racket/runtime-path
         "vm-diff-common.rkt")

(define-runtime-path peer-file "fixtures/channel-peer.py")
(define python (find-executable-path "python3"))
(define wait-seconds 30)
(define clients 6)

(define (python-ready?)
  (cond
    [python #t]
    [(getenv "CI") (error 'vm-channel "Python 3 is required in CI")]
    [else (displayln "SKIP VM channel tests: python3 is unavailable") #f]))

(define program
  #<<AGC
struct Pool
  sockets: Channel[Socket]
  id: Int
end

def serve(pool: Pool) -> Int
  handled = 0
  while true
    case pool.sockets.recv(10000)
      ok(socket) ->
        line = Result.unwrap!(TCP.read_line(socket, 10000))
        Result.unwrap!(TCP.send(socket, "worker #{pool.id} got #{line}\n", 10000))
        TCP.close(socket)
        handled += 1
      error(_) -> break
    end
  end
  return handled
end

def main() -> Void
  sockets: Channel[Socket] = Channel.new(2)
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  puts(TCP.local_port(listener))
  IO.flush()
  workers = [Task.spawn(&serve, Pool(sockets: sockets, id: 0)),
             Task.spawn(&serve, Pool(sockets: sockets, id: 1)),
             Task.spawn(&serve, Pool(sockets: sockets, id: 2))]
  i = 0
  while i < 6
    Result.unwrap!(sockets.send(Result.unwrap!(TCP.accept(listener, 10000)), 10000))
    i += 1
  end
  sockets.close
  handled = workers.map do |worker|
    Task.await(worker)
  end
  TCP.close_listener(listener)
  puts("handled #{handled.reduce(0) do |sum, n| sum + n end}")
end
AGC
  )

(define (next-line port)
  (define line (sync/timeout wait-seconds (read-line-evt port 'linefeed)))
  (unless (string? line) (error 'vm-channel "no line within ~a s: ~s" wait-seconds line))
  line)

(define (run-peer port)
  (define-values (process out in err) (subprocess #f #f (current-error-port) python peer-file (number->string port) (number->string clients)))
  (close-output-port in)
  (dynamic-wind
    void
    (lambda ()
      (define lines (for/list ([_ (in-range clients)]) (next-line out)))
      (unless (sync/timeout wait-seconds process) (error 'vm-channel "the peer did not finish"))
      (list (subprocess-status process) lines))
    (lambda ()
      (when (eq? (subprocess-status process) 'running) (subprocess-kill process #t))
      (subprocess-wait process)
      (close-input-port out))))

(module+ test
  (when (and (python-ready?) (vm-built? "VM channel tests"))
    (define work (make-temporary-directory "agentica-vm-channel~a"))
    (dynamic-wind
      void
      (lambda ()
        (test-case "a socket handed to a worker over a channel is served, and the loop ends when the channel closes"
          (define source (build-path work "pool.agc"))
          (define bytecode (build-path work "pool.agcb"))
          (display-to-file program source #:exists 'replace)
          (compile-file source bytecode)
          (define-values (process out in err) (subprocess #f #f (current-error-port) vm-file "--" (path->string bytecode)))
          (close-output-port in)
          (dynamic-wind
            void
            (lambda ()
              (define port (string->number (next-line out)))
              (check-true (exact-positive-integer? port))
              (define peer (run-peer port))
              (check-equal? (first peer) 0)
              (for ([line (in-list (second peer))] [i (in-naturals)])
                (check-regexp-match (pregexp (format "^~a worker [012] got msg ~a$" i i)) line))
              (check-equal? (next-line out) "handled 6")
              (check-true (and (sync/timeout wait-seconds process) #t) "the program ends")
              (check-equal? (subprocess-status process) 0))
            (lambda ()
              (when (eq? (subprocess-status process) 'running) (subprocess-kill process #t))
              (subprocess-wait process)
              (close-input-port out)))))
      (lambda () (delete-directory/files work)))))
