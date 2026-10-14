#lang racket

(require rackunit json racket/runtime-path "vm-diff-common.rkt")

(define-runtime-path peer-file "fixtures/child-channel-peer.py")
(define-runtime-path program "fixtures/child-channel.agc")
(define python (find-executable-path "python3"))

(define (peer-ready?)
  (cond
    [python #t]
    [(getenv "CI") (error 'vm-child-channel "Python 3 is required in CI")]
    [else (displayln "SKIP VM child channel tests: python3 is unavailable") #f]))

(define (ask bytecode mode)
  (define result
    (run-process vm-file #:timeout run-timeout "--allow-run" "--" (path->string bytecode) mode
                 (path->string python) (path->string peer-file)))
  (check-equal? (first result) 0 (third result))
  (second result))

(define (lines . items)
  (string-append (string-join items "\n") "\n"))

(module+ test
  (test-case "the child side of the channel: lines, partial lines, EOF, timeouts and no channel"
    (when (peer-ready?)
      (define work (make-temporary-directory "agentica-child-channel~a"))
      (dynamic-wind
        void
        (lambda ()
          (define bytecode (build-path work "channel.agcb"))
          (compile-file program bytecode)
          (define result (run-process python #:timeout run-timeout (path->string peer-file) (path->string vm-file)
                                      (path->string bytecode)))
          (check-equal? (first result) 0 (third result))
          (define answer (string->jsexpr (second result)))
          (define (part name key) (hash-ref (hash-ref answer name) key))
          (check-equal? (part 'serve 'exit) 0)
          (check-equal? (part 'serve 'replies)
                        '("echo:one\n" "echo:two\n" "echo:\n" 300006 "echo:café\n" "bye\n" ""))
          (check-equal? (part 'serve 'stdout)
                        (lines "sent: ok()" "sent: ok()" "sent: ok()" "sent: ok()" "sent: ok()"
                               "ended: process: end of input" "bye: ok()"))
          (check-equal? (part 'idle 'stdout)
                        (lines "first: error(\"network: operation timed out\")" "second: error(\"process: channel is closed\")"
                               "send: error(\"process: channel is closed\")"))
          (check-true (part 'idle 'waited))
          (define bare
            (lines "read: error(\"process: no parent channel\")" "send: error(\"process: no parent channel\")"
                   "zero: error(\"network: timeout must be positive milliseconds\")"))
          (check-equal? (part 'bare 'stdout) bare)
          (check-equal? (part 'bare_marker_only 'stdout) bare)
          (define spawned "unset\nclosed\n\n3\nsocket\n\n")
          (check-equal? (part 'spawning 'stdout) spawned)
          (check-equal? (part 'spawning_marker_only 'stdout) spawned)
          (for ([name '(serve idle bare bare_marker_only spawning spawning_marker_only)])
            (check-equal? (part name 'exit) 0 (symbol->string name)))
          (define refused (lines "read: error(\"process: no parent channel\")" "send: error(\"process: no parent channel\")" "ready"))
          (define (pinned kind key) (hash-ref (hash-ref (hash-ref answer 'pinned) kind) key))
          (for ([kind '(file device writeonly fifo)])
            (check-equal? (pinned kind 'exit) 0 (symbol->string kind)))
          (check-equal? (pinned 'file 'head) refused)
          (check-true (string-suffix? (pinned 'file 'target) "/plain.txt"))
          (check-equal? (pinned 'file 'content) "")
          (check-equal? (pinned 'writeonly 'head) refused)
          (check-equal? (pinned 'device 'head) refused)
          (check-equal? (pinned 'device 'target) "/dev/null")
          (check-equal? (pinned 'fifo 'head) (lines "read: ok(\"hello\")" "ready")))
        (lambda () (delete-directory/files work)))))

  (test-case "the parent side of the channel: send, read, read_available, close, timeouts and limits"
    (when (peer-ready?)
      (define work (make-temporary-directory "agentica-child-channel~a"))
      (dynamic-wind
        void
        (lambda ()
          (define bytecode (build-path work "channel.agcb"))
          (compile-file program bytecode)
          (check-equal? (ask bytecode "echo")
                        (lines "send: ok()" "read: ok(\"HELLO\")" "printed: ok(\"out:hello\\n\")" "printed again: ok(\"\")"
                               "close: ok()" "send after close: error(\"process: channel is closed\")"
                               "end: error(\"process: end of input\")" "exit: ok(0)"))
          (check-equal? (ask bytecode "silent")
                        (lines "first: error(\"network: operation timed out\")" "second: error(\"process: channel is closed\")"
                               "send: error(\"process: channel is closed\")" "printed: ok(\"\")"))
          (check-equal? (ask bytecode "stalled")
                        (lines "send: error(\"network: operation timed out\")" "after: error(\"process: channel is closed\")"))
          (check-equal? (ask bytecode "long")
                        (lines "read: error(\"process: line exceeds 1048576 bytes\")" "again: error(\"process: channel is closed\")"))
          (check-equal? (ask bytecode "loud") (lines "read: ok(\"done\")" "printed: ok(\"noise\\n\")"))
          (check-equal? (ask bytecode "split")
                        (lines "first: ok(\"one\")" "printed: ok(\"a\")" "send: ok()" "second: ok(\"two\")" "printed: ok(\"éb\\n\")"))
          (check-equal? (ask bytecode "gone")
                        (lines "exit: ok(0)" "end: error(\"process: end of input\")" "close: ok()" "close again: ok()"))
          (check-equal? (ask bytecode "plain")
                        (lines "read: error(\"process: the child has no channel\")" "send: error(\"process: the child has no channel\")"
                               "close: error(\"process: the child has no channel\")" "exit: ok(0)"
                               "printed: ok(\"marker=None fd3=False\\n\")"
                               "not captured: error(\"process: output is not captured\")")))
        (lambda () (delete-directory/files work))))))
