#lang racket

(require rackunit
         racket/runtime-path
         "vm-diff-common.rkt")

(define-runtime-path peer-file "fixtures/lines-peer.py")
(define python (find-executable-path "python3"))
(define wait-seconds 30)
(define buffer-bytes 4096)
(define line-count 1400000)

(define (collected?)
  (not (regexp-match? #rx"no libgc" (second (run-process vm-file "--version")))))

(define (python-ready?)
  (cond
    [python #t]
    [(getenv "CI") (error 'vm-file-lines "Python 3 is required in CI")]
    [else (displayln "SKIP VM file lines tests: python3 is unavailable") #f]))

(define (with-work proc)
  (define work (make-temporary-directory "agentica-vm-file-lines~a"))
  (dynamic-wind void (lambda () (proc work)) (lambda () (delete-directory/files work))))

(define (compile-text work name text)
  (define source (build-path work (string-append name ".agc")))
  (define bytecode (build-path work (string-append name ".agcb")))
  (display-to-file text source #:exists 'replace)
  (compile-file source bytecode)
  bytecode)

(define (environment-with . pairs)
  (define env (environment-variables-copy (current-environment-variables)))
  (let loop ([rest pairs])
    (unless (null? rest)
      (environment-variables-set! env (string->bytes/utf-8 (first rest)) (string->bytes/utf-8 (second rest)))
      (loop (cddr rest))))
  env)

(define (run-vm bytecode #:env [env (current-environment-variables)] . arguments)
  (parameterize ([current-environment-variables env])
    (apply run-process vm-file #:timeout wait-seconds (append (list "--") (list (path->string bytecode)) arguments))))

(define stream-program
  #<<AGC
def main() -> Void
  r = File.each_line(System.args()[0], 4096, 10000) do |line|
    puts(line)
    ok()
  end
  puts(r)
  status = Result.unwrap!(File.read_text("/proc/self/status", 10000))
  for entry in status.split("\n")
    if entry.starts_with?("VmHWM")
      puts(entry)
    end
  end
end
AGC
  )

(define baseline-program
  #<<AGC
def main() -> Void
  status = Result.unwrap!(File.read_text("/proc/self/status", 10000))
  for entry in status.split("\n")
    if entry.starts_with?("VmHWM")
      puts(entry)
    end
  end
end
AGC
  )

(define (write-lines path)
  (call-with-output-file path #:exists 'truncate
    (lambda (out)
      (for ([k (in-range line-count)])
        (write-bytes (string->bytes/utf-8 (format "l~a\n" k)) out)))))

(define (hwm-kib text)
  (string->number (cadr (regexp-match #px"VmHWM:\\s+([0-9]+) kB" text))))

(define (count-file-jobs trace-file)
  (for/sum ([line (in-list (file->lines trace-file))])
    (if (regexp-match? #rx" io start job=[0-9]+ kind=file " line) 1 0)))

(define fifo-program
  #<<AGC
def open_files() -> Int
  return Result.unwrap!(Dir.list("/proc/self/fd", 10000)).length
end

def wait_for(before: Int, want: Int) -> Bool
  tries = 0
  while tries < 500
    if open_files() - before == want
      return true
    end
    Task.sleep(10)
    tries = tries + 1
  end
  return false
end

def main() -> Void
  before = open_files()
  r = File.each_line(System.args()[0], 1024, Result.unwrap!(String.to_int(System.args()[1]))) do |line|
    IO.inspect(line)
    ok()
  end
  IO.inspect(r)
  IO.inspect(wait_for(before, 0))
end
AGC
  )

(define crash-program
  #<<AGC
def open_files() -> Int
  return Result.unwrap!(Dir.list("/proc/self/fd", 10000)).length
end

def reader(path: String) -> Result[Void]
  return File.each_line(path, 1024, 60000) do |line|
    puts("never #{line}")
    ok()
  end
end

def wait_for(before: Int, want: Int) -> Bool
  tries = 0
  while tries < 500
    if open_files() - before == want
      return true
    end
    Task.sleep(10)
    tries = tries + 1
  end
  return false
end

def parent(go: Channel[Int]) -> Int
  Task.spawn(&reader, System.args()[0])
  Result.unwrap!(go.recv(5000))
  zero = String.length("")
  return 1 / zero
end

def main() -> Void
  before = open_files()
  go: Channel[Int] = Channel.new(1)
  Task.spawn(&parent, go)
  IO.inspect(wait_for(before, 1))
  Result.unwrap!(go.send(1, 1000))
  IO.inspect(wait_for(before, 0))
end
AGC
  )

(define close-program
  #<<AGC
def open_files() -> Int
  return Result.unwrap!(Dir.list("/proc/self/fd", 10000)).length
end

def wait_for(before: Int, want: Int) -> Bool
  tries = 0
  while tries < 500
    if open_files() - before == want
      return true
    end
    Task.sleep(10)
    tries = tries + 1
  end
  return false
end

def main() -> Void
  path = System.args()[0]
  before = open_files()
  r = File.each_line(path, 1024, 5000) do |line|
    IO.inspect(line)
    return error("stop at #{line}")
  end
  IO.inspect(r)
  IO.inspect(wait_for(before, 0))
  h = Result.unwrap!(File.open(path, "read", 5000))
  IO.inspect(File.read_line(h, 5000))
  IO.inspect(File.close(h, 5000))
  IO.inspect(wait_for(before, 0))
end
AGC
  )

(define (start-peer work mode)
  (define fifo (path->string (build-path work (string-append mode ".fifo"))))
  (define-values (process out in err)
    (subprocess #f #f (current-error-port) python (path->string peer-file) fifo mode))
  (close-output-port in)
  (check-equal? (sync/timeout wait-seconds (read-line-evt out)) "ready" mode)
  (values process out fifo))

(define (stop-peer process out)
  (when (eq? (subprocess-status process) 'running) (subprocess-kill process #t))
  (subprocess-wait process)
  (close-input-port out))

(module+ test
  (when (vm-built? "VM file lines tests")
    (test-case "a 10 MB file of short lines streams in order with about size over buffer reads and bounded memory"
      (with-work
       (lambda (work)
         (define data (build-path work "lines.txt"))
         (write-lines data)
         (define size (file-size data))
         (check-true (> size 10000000))
         (define bytecode (compile-text work "stream" stream-program))
         (define trace (build-path work "trace.txt"))
         (define result
           (run-vm bytecode (path->string data)
                   #:env (environment-with "AGENTICA_VM_TRACE" "io" "AGENTICA_VM_TRACE_FILE" (path->string trace))))
         (check-equal? (first result) 0)
         (define expected (file->string data))
         (define output (second result))
         (check-true (string-prefix? output expected) "every line, in order, once")
         (define rest (substring output (string-length expected)))
         (check-regexp-match #px"^ok\\(\\)\nVmHWM:\\s+[0-9]+ kB\n$" rest)
         (when (collected?)
           (define baseline (run-vm (compile-text work "baseline" baseline-program)))
           (check-equal? (first baseline) 0)
           (define growth (- (hwm-kib rest) (hwm-kib (second baseline))))
           (check-true (< growth (quotient size 4096))
                       (format "peak memory grew by ~a kB while streaming ~a bytes" growth size)))
         (define jobs (count-file-jobs trace))
         (check-true (>= jobs (quotient size (add1 buffer-bytes))) (format "~a jobs" jobs))
         (check-true (<= jobs (+ 8 (quotient size (- buffer-bytes 16)))) (format "~a jobs" jobs)))))

    (test-case "--max-steps ends a long file with RUNTIME-STEP-LIMIT"
      (with-work
       (lambda (work)
         (define data (build-path work "lines.txt"))
         (write-lines data)
         (define bytecode (compile-text work "stream" stream-program))
         (define result
           (run-process vm-file #:timeout wait-seconds "--max-steps" "50000" "--" (path->string bytecode)
                        (path->string data)))
         (check-equal? (first result) 1)
         (check-regexp-match #rx"RUNTIME-STEP-LIMIT" (third result)))))

    (when (python-ready?)
      (test-case "a FIFO fed in pieces: lines and a CRLF split across reads, a last line without a newline"
        (with-work
         (lambda (work)
           (define-values (peer peer-out fifo) (start-peer work "pieces"))
           (dynamic-wind
             void
             (lambda ()
               (define result (run-vm (compile-text work "fifo" fifo-program) fifo "5000"))
               (check-equal? (first result) 0)
               (check-equal? (second result) "\"alpha\"\n\"beta\"\n\"gamma\"\n\"\"\n\"delta\"\nok()\ntrue\n")
               (check-equal? (sync/timeout wait-seconds (read-line-evt peer-out)) "closed"))
             (lambda () (stop-peer peer peer-out))))))

      (test-case "a FIFO that stalls times out one read, with a line half read, and the descriptor is closed"
        (with-work
         (lambda (work)
           (define-values (peer peer-out fifo) (start-peer work "stall"))
           (dynamic-wind
             void
             (lambda ()
               (define result (run-vm (compile-text work "fifo" fifo-program) fifo "1200"))
               (check-equal? (first result) 0)
               (check-equal? (second result) "\"first\"\nerror(\"filesystem: operation timed out\")\ntrue\n"))
             (lambda () (stop-peer peer peer-out))))))

      (test-case "closing a read FIFO that still holds buffered lines is ok, after an early stop and after read_line"
        (with-work
         (lambda (work)
           (define-values (peer peer-out fifo) (start-peer work "burst"))
           (dynamic-wind
             void
             (lambda ()
               (define result (run-vm (compile-text work "close" close-program) fifo))
               (check-equal? (first result) 0)
               (check-equal? (second result) "\"one\"\nerror(\"stop at one\")\ntrue\nok(\"four\")\nok()\ntrue\n"))
             (lambda () (stop-peer peer peer-out))))))

      (test-case "a crash cancels a task parked in File.each_line on a FIFO and frees its descriptor"
        (with-work
         (lambda (work)
           (define-values (peer peer-out fifo) (start-peer work "idle"))
           (dynamic-wind
             void
             (lambda ()
               (define result (run-vm (compile-text work "crash" crash-program) fifo
                                      #:env (environment-with "UV_THREADPOOL_SIZE" "1")))
               (check-equal? (first result) 1)
               (check-equal? (second result) "true\ntrue\n"))
             (lambda () (stop-peer peer peer-out)))))))))
