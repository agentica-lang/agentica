#lang racket

(require rackunit
         racket/runtime-path
         ffi/unsafe
         "cli-in-process.rkt"
         (only-in "vm-diff-common.rkt" vm-file vm-built?))

(define-runtime-path main-file "../src/main.rkt")
(define-runtime-path peer-file "fixtures/stop-peer.py")
(define python (find-executable-path "python3"))
(define wait-seconds 10)
(define unix-kill (get-ffi-obj "kill" #f (_fun _int _int -> _int) (lambda () #f)))
(define sighup 1)
(define sigint 2)
(define sigkill 9)
(define sigalrm 14)
(define sigterm 15)

(define (ready? what)
  (cond
    [(not (vm-built? what)) #f]
    [(not unix-kill) (displayln (format "SKIP ~a: kill is unavailable" what)) #f]
    [python #t]
    [(getenv "CI") (error 'vm-stop "Python 3 is required in CI")]
    [else (displayln (format "SKIP ~a: python3 is unavailable" what)) #f]))

(define (with-temp-dir proc)
  (define directory (make-temporary-file "agentica-stop~a" 'directory))
  (dynamic-wind void (lambda () (proc directory)) (lambda () (delete-directory/files directory))))

(define (compile-program root text)
  (define source (build-path root "program.agc"))
  (define bytecode (build-path root "program.agcb"))
  (display-to-file text source #:exists 'truncate)
  (check-equal? (first (run-main-in-process "compile" (path->string source) "-o" (path->string bytecode))) 0)
  (file-or-directory-permissions bytecode #o600)
  (path->string bytecode))

(define (alive? pid)
  (define stat (build-path "/proc" (number->string pid) "stat"))
  (and (file-exists? stat)
       (not (regexp-match? #rx"^[0-9]+ \\(.*\\) Z" (with-handlers ([exn:fail? (lambda (_) "0 () Z")]) (file->string stat))))))

(define (gone-soon? pid)
  (let loop ([left (* 10 wait-seconds)])
    (cond
      [(not (alive? pid)) #t]
      [(zero? left) (unix-kill pid sigkill) #f]
      [else (sleep 0.1) (loop (sub1 left))])))

(define (finish process [thunk void])
  (define ended (sync/timeout wait-seconds process))
  (unless ended (subprocess-kill process #t) (subprocess-wait process))
  (thunk)
  (check-true (and ended #t) (format "the process ends within ~a s" wait-seconds))
  (subprocess-status process))

(define (start-peer . arguments)
  (define-values (process out in err) (apply subprocess #f #f (current-error-port) python peer-file arguments))
  (values process out in))

(define (start-vm disposition error-port . arguments)
  (apply subprocess #f #f error-port python peer-file "launch" disposition (path->string vm-file) arguments))

(define (with-full-fifo root proc)
  (define fifo (path->string (build-path root "fifo")))
  (define-values (peer out in) (start-peer "fill" fifo))
  (dynamic-wind
    void
    (lambda ()
      (check-equal? (sync/timeout wait-seconds (read-line-evt out)) "ready")
      (proc fifo))
    (lambda ()
      (close-output-port in)
      (finish peer)
      (close-input-port out))))

(define stuck-flush
  (string-append "def main() -> Void\n  f = File.open(System.args()[0], \"write\", 5000).unwrap!\n"
                 "  File.write(f, \"x\", 1000).unwrap!\n  puts(\"ready\")\n  IO.flush()\nend\n"))

(define (child-program [trap ""])
  (string-append
   "def main() -> Void\n  f = File.open(System.args()[0], \"write\", 1000).unwrap!\n"
   "  File.write(f, \"buffered\", 1000).unwrap!\n"
   "  p = Process." (if (equal? trap "") "spawn" "spawn_captured") "(\"/bin/sh\", [\"-c\", \"" trap
   "echo $$; exec sleep 30\"]" (if (equal? trap "") "" ", \".\"") ", 1000).unwrap!\n"
   "  puts(Process.read_line(p, 5000).unwrap!)\n  IO.flush()\n"
   "  if System.args()[1] == \"sleep\"\n    Task.sleep(30000)\n"
   "  else\n    n = 0\n    while true\n      n = n + 1\n    end\n  end\nend\n"))

(define (check-stopped pid path label)
  (check-equal? (file->string path) "buffered" label)
  (check-true (gone-soon? pid) (format "~a: the child is gone" label)))

(module+ test
  (test-case "a stop signal takes the exit path: children die, buffered file data is written, the VM dies by the signal"
    (when (ready? "the stop signal tests")
      (for ([run (list (list "sleep" sigterm) (list "spin" sigint) (list "sleep" sighup))])
        (with-temp-dir
         (lambda (root)
           (define label (format "~a" run))
           (define path (path->string (build-path root "out.txt")))
           (define bytecode (compile-program root (child-program)))
           (define-values (vm out in err) (start-vm "default" #f "--allow-run" "--" bytecode path (first run)))
           (close-output-port in)
           (define pid (string->number (sync/timeout wait-seconds (read-line-evt out))))
           (unix-kill (subprocess-pid vm) (second run))
           (check-equal? (finish vm (lambda () (close-input-port out) (close-input-port err))) (+ 128 (second run)) label)
           (check-stopped pid path label))))))

  (test-case "a stop signal the VM inherited as ignored stays ignored"
    (when (ready? "the inherited ignore test")
      (with-temp-dir
       (lambda (root)
         (define bytecode (compile-program root "def main() -> Void\n  puts(\"ready\")\n  IO.flush()\n  Task.sleep(30000)\nend\n"))
         (define-values (vm out in err) (start-vm "ignore" #f "--" bytecode))
         (close-output-port in)
         (check-equal? (sync/timeout wait-seconds (read-line-evt out)) "ready")
         (unix-kill (subprocess-pid vm) sighup)
         (unix-kill (subprocess-pid vm) sigint)
         (check-false (sync/timeout 0.5 vm) "the ignored signals do not stop the VM")
         (subprocess-kill vm #t)
         (subprocess-wait vm)
         (close-input-port out)
         (close-input-port err)))))

  (test-case "an outside SIGALRM keeps its default action"
    (when (ready? "the SIGALRM test")
      (with-temp-dir
       (lambda (root)
         (define bytecode (compile-program root "def main() -> Void\n  puts(\"ready\")\n  IO.flush()\n  Task.sleep(30000)\nend\n"))
         (define-values (vm out in err) (subprocess #f #f #f vm-file "--" bytecode))
         (close-output-port in)
         (check-equal? (sync/timeout wait-seconds (read-line-evt out)) "ready")
         (unix-kill (subprocess-pid vm) sigalrm)
         (check-equal? (finish vm (lambda () (close-input-port out) (close-input-port err))) (+ 128 sigalrm))))))

  (test-case "a second stop signal before the children are stopped waits for them"
    (when (ready? "the early second signal test")
      (with-temp-dir
       (lambda (root)
         (define path (path->string (build-path root "out.txt")))
         (define bytecode (compile-program root (child-program "trap '' TERM; ")))
         (define-values (vm out in err) (subprocess #f #f #f vm-file "--allow-run" "--" bytecode path "sleep"))
         (close-output-port in)
         (define pid (string->number (sync/timeout wait-seconds (read-line-evt out))))
         (unix-kill (subprocess-pid vm) sigterm)
         (sleep 0.1)
         (unix-kill (subprocess-pid vm) sigterm)
         (check-equal? (finish vm (lambda () (close-input-port out) (close-input-port err))) (+ 128 sigterm))
         (check-true (gone-soon? pid) "the child is gone")))))

  (test-case "a second stop signal ends a flush that cannot finish; the first one waits for it"
    (when (ready? "the second signal test")
      (with-temp-dir
       (lambda (root)
         (with-full-fifo
          root
          (lambda (fifo)
            (define bytecode (compile-program root stuck-flush))
            (define-values (vm out in err) (start-vm "default" (current-error-port) "--" bytecode fifo))
            (close-output-port in)
            (check-equal? (sync/timeout wait-seconds (read-line-evt out)) "ready")
            (sleep 0.3)
            (unix-kill (subprocess-pid vm) sigint)
            (check-false (sync/timeout 0.5 vm) "the first signal flushes within the flush limit")
            (unix-kill (subprocess-pid vm) sigterm)
            (check-equal? (finish vm (lambda () (close-input-port out))) (+ 128 sigterm))))))))

  (test-case "a driven VM whose driver died does not wait for its flush"
    (when (ready? "the driver death test")
      (with-temp-dir
       (lambda (root)
         (with-full-fifo
          root
          (lambda (fifo)
            (define bytecode (compile-program root stuck-flush))
            (define-values (driver out in) (start-peer "drive" (path->string vm-file) "--" bytecode fifo))
            (close-output-port in)
            (define pid (string->number (sync/timeout wait-seconds (read-line-evt out))))
            (finish driver (lambda () (close-input-port out)))
            (check-true (gone-soon? pid) "the VM ends after its driver")))))))

  (test-case "a stop signal while standard output is full ends the run without a diagnostic"
    (when (ready? "the blocked stdout test")
      (with-temp-dir
       (lambda (root)
         (define bytecode
           (compile-program root (string-append "def main() -> Void\n  line = \"y\"\n  for i in 0..12\n"
                                                "    line = line + line\n  end\n"
                                                "  while true\n    puts(line)\n  end\nend\n")))
         (define-values (vm out in err) (subprocess #f #f #f vm-file "--" bytecode))
         (close-output-port in)
         (check-pred string? (sync/timeout wait-seconds (read-line-evt out)))
         (sleep 0.3)
         (unix-kill (subprocess-pid vm) sigterm)
         (define drain (thread (lambda () (copy-port out (open-output-nowhere)))))
         (define errors #f)
         (define reader (thread (lambda () (set! errors (port->string err)))))
         (check-equal? (finish vm (lambda () (sync/timeout wait-seconds drain) (sync/timeout wait-seconds reader)
                                    (close-input-port out) (close-input-port err)))
                       (+ 128 sigterm))
         (check-equal? errors "")))))

  (test-case "a stop signal with standard output stuck does not wait for the flush limit"
    (when (ready? "the stuck stdout test")
      (with-temp-dir
       (lambda (root)
         (define bytecode
           (compile-program root (string-append "def main() -> Void\n  line = \"y\"\n  for i in 0..9\n"
                                                "    line = line + line\n  end\n  n = 0\n  while n < 100\n"
                                                "    puts(line)\n    n += 1\n  end\n"
                                                "  IO.warn(\"ready\")\n  Task.sleep(30000)\nend\n")))
         (define-values (vm out in err) (subprocess #f #f #f vm-file "--" bytecode))
         (close-output-port in)
         (check-equal? (sync/timeout wait-seconds (read-line-evt err)) "ready")
         (sleep 0.3)
         (define start (current-inexact-milliseconds))
         (unix-kill (subprocess-pid vm) sigterm)
         (check-equal? (finish vm (lambda () (close-input-port out) (close-input-port err))) (+ 128 sigterm))
         (check-true (< (- (current-inexact-milliseconds) start) 5000) "the run does not wait for the reader")))))

  (test-case "Ctrl-C through the CLI stops a child that ignores the signals and writes the file"
    (when (ready? "the CLI interrupt test")
      (with-temp-dir
       (lambda (root)
         (define path (path->string (build-path root "out.txt")))
         (define source (build-path root "program.agc"))
         (display-to-file (child-program "trap '' INT TERM; ") source)
         (define environment (environment-variables-copy (current-environment-variables)))
         (environment-variables-set! environment #"AGENTICA_VM" (string->bytes/utf-8 (path->string vm-file)))
         (define-values (cli out in errors)
           (parameterize ([subprocess-group-enabled #t] [current-environment-variables environment])
             (subprocess #f #f #f (find-system-path 'exec-file) (path->string main-file)
                         "--allow-run" (path->string source) path "sleep")))
         (close-output-port in)
         (define pid (string->number (sync/timeout (* 6 wait-seconds) (read-line-evt out))))
         (unix-kill (- (subprocess-pid cli)) sigint)
         (finish cli (lambda () (close-input-port out) (close-input-port errors)))
         (check-stopped pid path "cli"))))))
