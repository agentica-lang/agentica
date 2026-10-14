#lang racket

(require rackunit
         json
         racket/runtime-path
         "vm-diff-common.rkt")

(define-runtime-path peer-file "fixtures/stdout-peer.py")
(define python (find-executable-path "python3"))
(define peer-limit 90)
(define filler (make-string 1024 #\x))

(define (python-ready?)
  (cond
    [python #t]
    [(getenv "CI") (error 'vm-stdout "Python 3 is required in CI")]
    [else (displayln "SKIP VM stdout tests: python3 is unavailable") #f]))

(define (rows-program count)
  (format
   #<<AGC
def main() -> Void
  filler = "x"
  for i in 0..9
    filler = filler + filler
  end
  n = 0
  while n < ~a
    puts("row #{n} #{filler}")
    n += 1
  end
end

AGC
   count))

(define (ticker-program count)
  (format
   #<<AGC
def ticker(count: Int) -> Int
  n = 0
  while n < count
    Task.sleep(50)
    IO.warn("tick")
    n += 1
  end
  return n
end

def main() -> Void
  t = Task.spawn(&ticker, 40)
  filler = "x"
  for i in 0..9
    filler = filler + filler
  end
  n = 0
  while n < ~a
    puts("row #{n} #{filler}")
    n += 1
  end
  Task.await(t)
end

AGC
   count))

(define two-writers-program
  #<<AGC
def writer(tag: String) -> Int
  filler = "x"
  for i in 0..12
    filler = filler + filler
  end
  n = 0
  while n < 40
    puts("#{tag}#{n} #{filler}")
    n += 1
  end
  return n
end

def main() -> Void
  a = Task.spawn(&writer, "A")
  b = Task.spawn(&writer, "B")
  Task.await(a)
  Task.await(b)
end

AGC
  )

(define long-print-program
  #<<AGC
def shorts(count: Int) -> Int
  n = 0
  while n < count
    puts("short-#{n}")
    n += 1
  end
  return n
end

def main() -> Void
  s = Task.spawn(&shorts, 200)
  big = "z"
  for i in 0..17
    big = big + big
  end
  puts(big)
  puts(big)
  Task.await(s)
end

AGC
  )

(define crashed-parent-program
  #<<AGC
def child(filler: String) -> Void
  i = 0
  while true
    puts("C#{i} #{filler}")
    i += 1
  end
end

def parent(filler: String) -> Void
  Task.spawn(&child, filler)
  Task.sleep(300)
  x = 1 / 0
  puts(x)
end

def main() -> Void
  filler = "x"
  for i in 0..9
    filler = filler + filler
  end
  Task.await(Task.spawn(&parent, filler))
end

AGC
  )

(define (big-unwrap-program doublings)
  (format
   #<<AGC
def parse(text: String) -> Result[Int]
  return error(text)
end

def main() -> Void
  big = "e"
  for i in 0..~a
    big = big + big
  end
  value = Result.unwrap!(parse(big))
  puts(value)
end

AGC
   doublings))

(define stuck-print-program
  #<<AGC
def printer(big: String) -> Void
  puts(big)
  puts(big)
end

def crasher(k: Int) -> Void
  x = 1 / 0
  puts(x)
end

def main() -> Void
  big = "z"
  for i in 0..18
    big = big + big
  end
  Task.spawn(&printer, big)
  Task.sleep(100)
  Task.spawn(&crasher, 1)
  Task.sleep(100)
end

AGC
  )

(define cut-print-record-program
  #<<AGC
def spill(big: String) -> Void
  print(big)
end

def main() -> Void
  Test.run([
    Test.test("leaves a long print") do
      big = "z"
      for i in 0..17
        big = big + big
      end
      Task.spawn(&spill, big)
      Task.sleep(100)
      ok()
    end
  ])
end

AGC
  )

(define output-then-crash-program
  #<<AGC
def main() -> Void
  puts("before")
  print("partial")
  x = 1 / 0
  puts(x)
end

AGC
  )

(define dev-stdout-program
  #<<AGC
def main() -> Void
  out = File.open("/dev/stdout", "write", 1000).unwrap!
  File.write(out, "via file\n", 1000).unwrap!
  File.close(out, 1000).unwrap!
  err = File.open("/dev/stderr", "append", 1000).unwrap!
  File.write(err, "via stderr\n", 1000).unwrap!
  File.close(err, 1000).unwrap!
  puts("normal")
  IO.warn("after")
end

AGC
  )

(define crash-while-stuck-program
  #<<AGC
def crasher(delay: Int) -> Void
  Task.sleep(delay)
  x = 1 / 0
  puts(x)
end

def main() -> Void
  Task.spawn(&crasher, 200)
  filler = "w"
  for i in 0..9
    filler = filler + filler
  end
  n = 0
  while n < 200
    IO.warn("warn #{n} #{filler}")
    n += 1
  end
end

AGC
  )

(define alternate-program
  #<<AGC
def main() -> Void
  filler = "x"
  for i in 0..9
    filler = filler + filler
  end
  n = 0
  while n < 150
    puts("o#{n} #{filler}")
    IO.warn("e#{n} #{filler}")
    n += 1
  end
end

AGC
  )

(define warn-last-program
  #<<AGC
def main() -> Void
  puts("done")
  IO.warn("last words")
end

AGC
  )

(define flush-program
  #<<AGC
def main() -> Void
  filler = "x"
  for i in 0..9
    filler = filler + filler
  end
  n = 0
  while n < 100
    puts("row #{n} #{filler}")
    n += 1
  end
  IO.flush()
  IO.warn("flushed")
end

AGC
  )

(define (run-case work name program #:peer [peer-arguments '()] #:vm [vm-arguments '()] #:args [program-arguments '()])
  (define source (build-path work (string-append name ".agc")))
  (define bytecode (build-path work (string-append name ".agcb")))
  (define out-file (build-path work (string-append name ".out")))
  (define err-file (build-path work (string-append name ".err")))
  (display-to-file program source #:exists 'replace)
  (compile-file source bytecode)
  (define result
    (apply run-process python #:timeout peer-limit
           (path->string peer-file)
           "--stdout-file" (path->string out-file)
           "--stderr-file" (path->string err-file)
           (append peer-arguments
                   (list "--" (path->string vm-file))
                   vm-arguments
                   (list "--" (path->string bytecode))
                   program-arguments)))
  (check-equal? (first result) 0 (format "~a: the peer ends: ~a" name (third result)))
  (define summary (string->jsexpr (second result)))
  (values summary (file->bytes out-file) (file->string err-file)))

(define (output-lines data)
  (define text (bytes->string/latin-1 data))
  (define lines (string-split text "\n" #:trim? #f))
  (check-true (or (string=? text "") (string-suffix? text "\n")) "the output ends with a whole line")
  (if (null? lines) lines (drop-right lines 1)))

(define (row-total count)
  (for/sum ([n (in-range count)]) (add1 (string-length (format "row ~a ~a" n filler)))))

(define (check-rows lines count)
  (check-equal? (length lines) count)
  (for ([line (in-list lines)] [n (in-naturals)])
    (unless (string=? line (format "row ~a ~a" n filler))
      (fail (format "row ~a is not whole or not in order" n)))))

(define live-child-program
  #<<AGC
def main() -> Void
  child = Result.unwrap!(Process.spawn("/bin/sh", ["-c", "cat"], 5000))
  puts("child started")
  IO.inspect(Process.read_line(child, 100))
  puts("done")
end

AGC
  )

(define (run-to-file work name program #:stderr-file [stderr-file? #f])
  (define source (build-path work (string-append name ".agc")))
  (define bytecode (build-path work (string-append name ".agcb")))
  (define out-file (build-path work (string-append name ".out")))
  (define err-file (build-path work (string-append name ".err")))
  (display-to-file program source #:exists 'replace)
  (compile-file source bytecode)
  (define out (open-output-file out-file #:exists 'truncate))
  (define err-target (if (string? stderr-file?) (string->path stderr-file?) err-file))
  (define err-out (and stderr-file? (open-output-file err-target #:exists 'truncate)))
  (define start (current-inexact-milliseconds))
  (define-values (process in-port ignored err)
    (subprocess out #f err-out vm-file "--allow-run" "--flush-timeout" "20000" "--" (path->string bytecode)))
  (close-output-port ignored)
  (define piped-errors (box ""))
  (define reader (and err (thread (lambda () (set-box! piped-errors (port->string err))))))
  (define finished (sync/timeout peer-limit process))
  (unless finished (subprocess-kill process #t))
  (subprocess-wait process)
  (close-output-port out)
  (when err-out (close-output-port err-out))
  (when reader
    (sync/timeout 10 reader)
    (close-input-port err))
  (values (if finished (subprocess-status process) 'timeout)
          (- (current-inexact-milliseconds) start)
          (file->string out-file)
          (cond
            [(string? stderr-file?) ""]
            [stderr-file? (file->string err-file)]
            [else (unbox piped-errors)])))

(module+ test
  (when (and (python-ready?) (vm-built? "VM stdout tests"))
    (define work (make-temporary-directory "agentica-vm-stdout~a"))
    (dynamic-wind
      void
      (lambda ()
        (test-case "a pipe nobody reads does not stop a timer task, and the run ends once the reader drains"
          (define-values (summary out err)
            (run-case work "ticker" (ticker-program 400) #:peer '("--delay" "1.0" "--chunk" "16384" "--pause" "0.001")))
          (check-equal? (hash-ref summary 'status) 0)
          (check-true (>= (hash-ref summary 'ticks_before_read) 5) "the ticker ran while stdout was stuck")
          (check-rows (output-lines out) 400)
          (check-equal? (length (regexp-match* #rx"tick" err)) 40))

        (test-case "two tasks printing long lines into a slow pipe never interleave, and each keeps its order"
          (define-values (summary out err)
            (run-case work "writers" two-writers-program #:peer '("--delay" "0.3" "--chunk" "16384" "--pause" "0.002")))
          (check-equal? (hash-ref summary 'status) 0)
          (define lines (output-lines out))
          (check-equal? (length lines) 80)
          (define next (make-hash '(("A" . 0) ("B" . 0))))
          (for ([line (in-list lines)])
            (define m (regexp-match #px"^([AB])([0-9]+) x{8192}$" line))
            (unless m (fail "a line is not whole"))
            (check-equal? (string->number (third m)) (hash-ref next (second m)) "the order of one task")
            (hash-update! next (second m) add1)))

        (test-case "a print longer than the buffer holds the stream until it is all copied"
          (define-values (summary out err)
            (run-case work "long" long-print-program #:peer '("--delay" "0.3" "--chunk" "16384" "--pause" "0.002")))
          (check-equal? (hash-ref summary 'status) 0)
          (define lines (output-lines out))
          (check-equal? (length lines) 202)
          (define big (make-string 262144 #\z))
          (check-equal? (length (filter (lambda (line) (string=? line big)) lines)) 2)
          (define shorts (filter (lambda (line) (not (string=? line big))) lines))
          (check-equal? shorts (for/list ([n (in-range 200)]) (format "short-~a" n))))

        (test-case "the end of the run drains standard output within the flush limit"
          (define-values (summary out err)
            (run-case work "drain" (rows-program 100) #:peer '("--delay" "1.0") #:vm '("--json")))
          (check-equal? (hash-ref summary 'status) 0)
          (check-true (>= (hash-ref summary 'exit) (hash-ref summary 'read_start)) "the run waited for the reader")
          (check-rows (output-lines out) 100)
          (check-equal? err ""))

        (test-case "a reader that never reads ends the run after the flush timeout with the warning"
          (define-values (summary out err)
            (run-case work "stuck" (rows-program 100)
                      #:peer '("--read-after-exit") #:vm '("--json" "--flush-timeout" "500")))
          (check-equal? (hash-ref summary 'status) 0)
          (check-true (<= 0.4 (hash-ref summary 'exit) 20) "the run waits for the flush limit")
          (check-regexp-match #rx"\"flush_timeout_ms\":500" err)
          (check-true (< 0 (bytes-length out) (row-total 100)) "the data that fits the pipe arrives"))

        (test-case "a stuck stderr that is the stdout pipe drops the warning and keeps the exit code"
          (define-values (summary out err)
            (run-case work "merged" (rows-program 100)
                      #:peer '("--read-after-exit" "--merge") #:vm '("--json" "--flush-timeout" "500")))
          (check-equal? (hash-ref summary 'status) 0)
          (check-true (<= 0.4 (hash-ref summary 'exit) 20) "the run waits for the flush limit")
          (check-true (< 0 (bytes-length out) (row-total 100)))
          (check-false (regexp-match? #rx#"flush_timeout_ms" out) "the warning is dropped, not mixed into the data"))

        (test-case "a socket as stdout is written on the loop"
          (define-values (summary out err)
            (run-case work "socket" (ticker-program 800) #:peer '("--socket" "--delay" "1.0")))
          (check-equal? (hash-ref summary 'status) 0)
          (check-true (>= (hash-ref summary 'ticks_before_read) 5) "the ticker ran while stdout was stuck")
          (check-rows (output-lines out) 800))

        (test-case "stdout and stderr on one pipe keep the order of the calls under a slow reader"
          (define-values (summary out err)
            (run-case work "alternate" alternate-program #:peer '("--delay" "0.5" "--merge" "--chunk" "16384" "--pause" "0.001")))
          (check-equal? (hash-ref summary 'status) 0)
          (define lines (output-lines out))
          (check-equal? (length lines) 300)
          (for ([line (in-list lines)] [k (in-naturals)])
            (define expected (format "~a~a ~a" (if (even? k) "o" "e") (quotient k 2) filler))
            (unless (string=? line expected)
              (fail (format "line ~a is not in the order of the calls" k)))))

        (test-case "stdout and stderr on one terminal keep the order of the calls under a slow reader"
          (define-values (summary out err)
            (run-case work "terminal" alternate-program #:peer '("--delay" "0.5" "--pty" "--chunk" "1024" "--pause" "0.0005")))
          (check-equal? (hash-ref summary 'status) 0)
          (define lines (output-lines (regexp-replace* #rx#"\r" out #"")))
          (check-equal? (length lines) 300)
          (for ([line (in-list lines)] [k (in-naturals)])
            (define expected (format "~a~a ~a" (if (even? k) "o" "e") (quotient k 2) filler))
            (unless (string=? line expected)
              (fail (format "line ~a is not in the order of the calls" k)))))

        (test-case "IO.flush returns once a slow reader has taken the data"
          (define-values (summary out err)
            (run-case work "flush" flush-program #:peer '("--delay" "1.0")))
          (check-equal? (hash-ref summary 'status) 0)
          (check-rows (output-lines out) 100)
          (check-equal? err "flushed\n")
          (check-true (>= (hash-ref summary 'first_error_at) (hash-ref summary 'read_start)) "flush waited for the reader"))

        (test-case "a crash notice waits for a stderr that is full and then arrives whole"
          (define-values (summary out err)
            (run-case work "crash-notice" crash-while-stuck-program
                      #:peer '("--error-delay" "1.0") #:vm '("--json")))
          (check-equal? (hash-ref summary 'status) 1)
          (check-true (>= (hash-ref summary 'first_error_at) 0.9) "stderr was stuck while the task crashed")
          (define lines (string-split err "\n"))
          (define crash (filter (lambda (line) (regexp-match? #rx"^{\"code\":\"RUNTIME-DIVISION-BY-ZERO\"" line)) lines))
          (check-equal? (length crash) 1)
          (check-equal? (hash-ref (string->jsexpr (car crash)) 'task) #t)
          (check-equal? (length (filter (lambda (line) (regexp-match? #rx"^warn [0-9]+ w+$" line)) lines)) 200))

        (test-case "a stderr that cannot be written makes the exit code 1"
          (define-values (status elapsed out err) (run-to-file work "full-stderr" warn-last-program #:stderr-file "/dev/full"))
          (check-equal? status 1)
          (check-equal? out "done\n"))

        (test-case "a long diagnostic reaches a slow stderr pipe whole"
          (define-values (summary out err)
            (run-case work "slow-diagnostic" (big-unwrap-program 17) #:peer '("--error-delay" "1.0") #:vm '("--json")))
          (check-equal? (hash-ref summary 'status) 1)
          (check-regexp-match #rx"RUNTIME-UNWRAP-ERROR" err)
          (check-true (> (string-length err) 262144) "the whole text arrives"))

        (test-case "a print cut by the end of the run does not hold a queued notice or the exit"
          (define-values (summary out err)
            (run-case work "stuck-print" stuck-print-program
                      #:peer '("--delay" "1.0" "--merge") #:vm '("--json" "--flush-timeout" "6000")))
          (check-equal? (hash-ref summary 'status) 1)
          (check-true (< (hash-ref summary 'exit) 4) "the run does not wait for the flush limit")
          (check-false (regexp-match? #rx#"flush_timeout_ms" out))
          (check-regexp-match #rx#"RUNTIME-DIVISION-BY-ZERO" out))

        (test-case "a protocol record starts a line after a print that was cut"
          (define-values (summary out err)
            (run-case work "cut-record" cut-print-record-program
                      #:peer '("--delay" "1.0" "--stdin" "tok\n0\n") #:args '("--agentica-test" "run")))
          (check-equal? (hash-ref summary 'status) 0)
          (define marker (regexp-match-positions #rx#"\x1eagentica-bdd " out))
          (check-true (and marker #t) "the record is there")
          (check-equal? (bytes-ref out (sub1 (caar marker))) 10 "the record starts a line")
          (check-regexp-match #rx#"RUNTIME-TEST-PENDING-TASKS" out))

        (test-case "blocking stdout and stderr on one pipe: the program output comes before the diagnostic"
          (putenv "AGENTICA_VM_TEST_BLOCKING_OUTPUT" "1")
          (define-values (summary out err)
            (dynamic-wind
              void
              (lambda ()
                (run-case work "blocking-order" output-then-crash-program #:peer '("--merge") #:vm '("--json")))
              (lambda ()
                (environment-variables-set! (current-environment-variables) #"AGENTICA_VM_TEST_BLOCKING_OUTPUT" #f))))
          (check-equal? (hash-ref summary 'status) 1)
          (check-regexp-match #rx#"^before\npartial[^\n]*RUNTIME-DIVISION-BY-ZERO" out))

        (test-case "File calls on /dev/stdout and /dev/stderr still work when they are pipes"
          (define-values (summary out err) (run-case work "dev-stdout" dev-stdout-program))
          (check-equal? (hash-ref summary 'status) 0)
          (check-equal? out #"via file\nnormal\n")
          (check-equal? err "via stderr\nafter\n"))

        (test-case "a long error text reaches a stderr file whole"
          (define-values (status elapsed out err) (run-to-file work "big-error" (big-unwrap-program 16) #:stderr-file #t))
          (check-equal? status 1)
          (check-equal? out "")
          (check-regexp-match #rx"RUNTIME-UNWRAP-ERROR" err)
          (check-true (> (string-length err) 131072) "the whole text is written"))

        (test-case "a regular file written by the pool is drained while a child is stopped at the end of the run"
          (define-values (status elapsed out err) (run-to-file work "live-child" live-child-program))
          (check-equal? status 0)
          (check-true (< elapsed 10000) "the run does not wait for the flush limit")
          (check-equal? err "")
          (check-regexp-match #rx"^child started\n.*\ndone\n$" out))

        (test-case "a reader that goes away fails the print, not the VM"
          (define-values (summary out err)
            (run-case work "gone" (rows-program 400) #:peer '("--close-after" "100000") #:vm '("--json")))
          (check-equal? (hash-ref summary 'status) 1)
          (check-regexp-match #rx"\"code\":\"RUNTIME-INTERNAL\"" err))

        (test-case "a crashed parent cancels a child waiting to print, and nothing partial is written"
          (define-values (summary out err)
            (run-case work "crash" crashed-parent-program #:peer '("--delay" "1.0") #:vm '("--json")))
          (check-equal? (hash-ref summary 'status) 1)
          (check-regexp-match #rx"\"code\":\"RUNTIME-DIVISION-BY-ZERO\"" err)
          (define lines (output-lines out))
          (check-true (> (length lines) 50) "the child filled the buffers before it was cancelled")
          (for ([line (in-list lines)] [n (in-naturals)])
            (unless (string=? line (format "C~a ~a" n filler))
              (fail (format "line ~a is partial or out of order" n))))))
      (lambda () (delete-directory/files work)))))
