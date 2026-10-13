#lang racket

(require (except-in rackunit check)
         racket/file
         racket/runtime-path
         racket/list
         racket/system
         json
         "cli-in-process.rkt"
         (only-in "vm-diff-common.rkt" vm-file vm-built?))

(define-runtime-path examples-dir "../examples")

(define (run-program text #:args [arguments '()])
  (define file (make-temporary-file "agentica-filesystem~a.agc"))
  (define result
    (dynamic-wind
      void
      (lambda ()
        (display-to-file text file #:exists 'truncate)
        (apply run-main-in-process (path->string file) arguments))
      (lambda () (delete-file file))))
  (values (second result) (if (zero? (first result)) (void) result)))

(define (with-temp-dir proc)
  (define directory (make-temporary-file "agentica-filesystem~a" 'directory))
  (dynamic-wind
    void
    (lambda () (proc (path->string directory)))
    (lambda () (delete-directory/files directory))))

(define (literal text) (format "~s" text))

(define vm-wait-seconds 10)
(define python (find-executable-path "python3"))
(define-runtime-path stop-peer "fixtures/stop-peer.py")

(define (run-vm-bounded root text #:inherit? [inherit? #f] #:input [input #f] . arguments)
  (define source (build-path root "program.agc"))
  (define bytecode (path->string (build-path root "program.agcb")))
  (display-to-file text source #:exists 'truncate)
  (check-equal? (first (run-main-in-process "compile" (path->string source) "-o" bytecode)) 0)
  (define-values (process out in err)
    (apply subprocess #f #f #f (if inherit? python vm-file)
           (append (if inherit? (list (path->string stop-peer) "inherit" (path->string vm-file)) '())
                   (list "--allow-run" "--" bytecode) arguments)))
  (when input (write-string input in))
  (close-output-port in)
  (define output #f)
  (define reader (thread (lambda () (set! output (port->string out)))))
  (define finished (sync/timeout vm-wait-seconds process))
  (unless finished (subprocess-kill process #t))
  (sync/timeout vm-wait-seconds reader)
  (close-input-port out)
  (close-input-port err)
  (check-true (and finished #t) (format "the VM ends within ~a s" vm-wait-seconds))
  (list (subprocess-status process) output))

(module+ test
  (test-case "the run waits for the close of a crashed task's file, so its buffered write reaches the disk"
    (with-temp-dir
     (lambda (root)
       (define path (path->string (build-path root "crash.txt")))
       (define-values (output result)
         (run-program
          (string-append
           "def writer(path: String) -> Result[Int]\n  f = try File.open(path, \"write\", 1000)\n"
           "  try File.write(f, \"hello world\\n\", 1000)\n  n = 0\n  return ok(1 / n)\nend\n\n"
           "def main() -> Void\n  t = Task.spawn(&writer, System.args()[0])\n  puts(Task.await(t).ok?)\nend\n")
          #:args (list path)))
       (check-equal? output "false\n")
       (check-equal? result (void))
       (check-equal? (file->string path) "hello world\n"))))

  (test-case "--flush-timeout needs a non-negative integer"
    (define hello (path->string (build-path examples-dir "hello.agc")))
    (check-equal? (first (run-main-in-process "--flush-timeout" "-1" hello)) 2)
    (check-equal? (first (run-main-in-process "--flush-timeout" "soon" hello)) 2)
    (check-equal? (first (run-main-in-process "--flush-timeout" "0" hello)) 0))

  (test-case "--flush-timeout ends the run when a file flush cannot finish"
    (define mkfifo (find-executable-path "mkfifo"))
    (if (not mkfifo)
        (displayln "skip: mkfifo is not available")
        (with-temp-dir
         (lambda (root)
           (define fifo (path->string (build-path root "fifo")))
           (define source (path->string (build-path root "stuck.agc")))
           (check-true (system* mkfifo fifo))
           (display-to-file
            (string-append
             "def main() -> Void\n  f = File.open(System.args()[0], \"write\", 1000).unwrap!\n"
             "  File.write(f, \"x\", 1000).unwrap!\n  IO.print(\"main done\\n\")\nend\n")
            source)
           (define reader (open-input-file fifo))
           (define filler #f)
           (define watchdog (thread (lambda () (sleep 10) (close-input-port reader))))
           (define start (current-inexact-milliseconds))
           (define result
             (dynamic-wind
               void
               (lambda ()
                 (set! filler (open-output-file fifo #:exists 'append))
                 (let fill ()
                   (define written (write-bytes-avail* (make-bytes 4096 97) filler))
                   (when (and written (positive? written)) (fill)))
                 (close-output-port filler)
                 (run-main-in-process "--json" "--flush-timeout" "200" source fifo))
               (lambda ()
                 (kill-thread watchdog)
                 (when filler (with-handlers ([exn:fail? void]) (close-output-port filler)))
                 (close-input-port reader))))
           (check-true (< (- (current-inexact-milliseconds) start) 10000))
           (check-equal? (take result 2) '(0 "main done\n"))
           (check-equal? (hash-ref (string->jsexpr (third result)) 'flush_timeout_ms) 200)))))

  (test-case "file calls cannot reopen the VM's own pipes, so a later spawn does not deadlock"
    (when (vm-built? "the private pipe test")
      (with-temp-dir
       (lambda (root)
         (define result
           (run-vm-bounded
            root
            (string-append
             "def main() -> Void\n  for name in Dir.list(\"/proc/self/fd\", 1000).unwrap!\n"
             "    if name != \"0\" and name != \"1\" and name != \"2\"\n"
             "      path = \"/proc/self/fd/\" + name\n"
             "      IO.inspect([File.read_text(path, 100).ok?, File.open(path, \"append\", 100).ok?])\n"
             "    end\n  end\n"
             "  p = Process.spawn(\"true\", [], 1000).unwrap!\n  IO.inspect(Process.wait(p, 1000))\nend\n")))
         (define lines (string-split (second result) "\n"))
         (check-equal? (first result) 0)
         (check-equal? (last lines) "ok(0)")
         (check-equal? (remove-duplicates (drop-right lines 1)) '("[false, false]"))))))

  (test-case "pipes the VM got at start stay readable: an inherited descriptor and a piped stdin"
    (when (vm-built? "the inherited pipe test")
      (cond
        [python
         (with-temp-dir
          (lambda (root)
            (define program
              (string-append "def main() -> Void\n  f = File.open(System.args()[0], \"read\", 1000).unwrap!\n"
                             "  IO.inspect(File.read_line(f, 1000))\nend\n"))
            (check-equal? (run-vm-bounded root program #:inherit? #t) '(0 "ok(\"inherited\")\n"))
            (check-equal? (run-vm-bounded root program #:input "piped\n" "/dev/stdin") '(0 "ok(\"piped\")\n"))))]
        [(getenv "CI") (error 'filesystem "Python 3 is required in CI")]
        [else (displayln "SKIP the inherited pipe test: python3 is unavailable")])))

  (test-case "file-summary example reads a command-line path"
    (define input-path (build-path examples-dir "hello.agc"))
    (define-values (output result)
      (run-program (file->string (build-path examples-dir "file-summary.agc"))
                   #:args (list (path->string input-path))))
    (check-equal? result (void))
    (check-equal? output (format "~a\n" (string-length (file->string input-path)))))

  (test-case "file streams, whole-text helpers, directories, metadata, and paths work together"
    (with-temp-dir
     (lambda (root)
       (define directory (build-path root "nested" "data"))
       (define path (build-path directory "notes.txt"))
       (define-values (output result)
         (run-program
          (format
           (string-append
            "def main() -> Void\n"
            "  made: Result[Void] = Dir.mkdir(~a, 1000)\n"
            "  made_again: Result[Void] = Dir.mkdir(~a, 1000)\n"
            "  opened: Result[FileHandle] = File.open(~a, \"write\", 1000)\n"
            "  handle: FileHandle = Result.unwrap!(opened)\n"
            "  wrote: Result[Void] = File.write(handle, \"alpha\\n\", 1000)\n"
            "  wrote_bytes: Result[Void] = File.write_bytes(handle, [98, 101, 116, 97], 1000)\n"
            "  closed: Result[Void] = File.close(handle, 1000)\n"
            "  closed_again: Result[Void] = File.close(handle, 1000)\n"
            "  appended: Result[Void] = File.append_text(~a, \"\\nend\", 1000)\n"
            "  text: Result[String] = File.read_text(~a, 1000)\n"
            "  info: Result[FileInfo] = File.stat(~a, 1000)\n"
            "  entries: Result[List[String]] = Dir.list(~a, 1000)\n"
            "  joined: Result[String] = Path.join([~a, \"notes.txt\"])\n"
            "  resolved: Result[String] = Path.resolve(~a)\n"
            "  IO.inspect(Result.ok?(made) and Result.ok?(made_again) and Result.ok?(wrote) and Result.ok?(wrote_bytes) and Result.ok?(closed) and Result.ok?(closed_again) and Result.ok?(appended))\n"
            "  IO.inspect(text)\n"
            "  IO.inspect(info)\n"
            "  IO.inspect(entries)\n"
            "  IO.inspect(joined)\n"
            "  IO.inspect(resolved)\n"
            "end\n\n")
           (literal (path->string directory))
           (literal (path->string directory))
           (literal (path->string path))
           (literal (path->string path))
           (literal (path->string path))
           (literal (path->string path))
           (literal (path->string (build-path root "nested" ".." "nested" "data")))
           (literal (path->string directory))
           (literal (path->string (build-path root "nested" ".." "nested" "data"))))))
       (check-equal? result (void))
       (check-true (string-contains? output "true\n"))
       (check-true (string-contains? output "ok(\"alpha\\nbeta\\nend\")"))
       (check-true (string-contains? output "FileInfo(kind: \"file\", size_bytes: 14"))
       (check-true (string-contains? output "ok([\"notes.txt\"])"))
       (check-true (string-contains? output (format "ok(~s)" (path->string path))))
       (check-true (string-contains? output (format "ok(~s)" (path->string directory))))))

  (test-case "invalid modes, closed handles, invalid UTF-8, and whole-file bounds return errors"
    (with-temp-dir
     (lambda (root)
       (define path (build-path root "bad.txt"))
       (define large-path (build-path root "large.txt"))
       (call-with-output-file large-path
         (lambda (port) (write-bytes (make-bytes 1048577 120) port))
         #:mode 'binary)
       (define-values (output result)
         (run-program
          (format
           (string-append
            "def main() -> Void\n"
            "  invalid_mode: Result[FileHandle] = File.open(~a, \"readwrite\", 1000)\n"
            "  opened: Result[FileHandle] = File.open(~a, \"write\", 1000)\n"
            "  handle: FileHandle = Result.unwrap!(opened)\n"
            "  wrote: Result[Void] = File.write_bytes(handle, [255], 1000)\n"
            "  closed: Result[Void] = File.close(handle, 1000)\n"
            "  closed_read: Result[List[Int]] = File.read_bytes(handle, 1, 1000)\n"
            "  invalid_utf8: Result[String] = File.read_text(~a, 1000)\n"
            "  oversized: Result[String] = File.read_text(~a, 1000)\n"
            "  IO.inspect(invalid_mode)\n"
            "  IO.inspect(closed_read)\n"
            "  IO.inspect(invalid_utf8)\n"
            "  IO.inspect(oversized)\n"
            "end\n\n")
           (literal (path->string path))
           (literal (path->string path))
           (literal (path->string path))
           (literal (path->string large-path)))))
       (check-equal? result (void))
       (check-true (string-contains? output "error("))
       (check-true (string-contains? output "file handle is closed"))
       (check-true (string-contains? output "UTF-8"))
       (check-true (string-contains? output "1048576")))))

  (test-case "bounded stream reads and line decoding preserve EOF semantics"
    (with-temp-dir
     (lambda (root)
       (define path (build-path root "lines.txt"))
       (call-with-output-file path (lambda (port) (write-bytes #"one\r\ntwo\nlast" port))
         #:mode 'binary)
       (define-values (output result)
         (run-program
          (format
           (string-append
            "def main() -> Void\n"
            "  opened: Result[FileHandle] = File.open(~a, \"read\", 1000)\n"
            "  handle: FileHandle = Result.unwrap!(opened)\n"
            "  first: Result[String] = File.read_line(handle, 1000)\n"
            "  second: Result[String] = File.read_line(handle, 1000)\n"
            "  rest: Result[List[Int]] = File.read_bytes(handle, 100, 1000)\n"
            "  eof: Result[List[Int]] = File.read_bytes(handle, 100, 1000)\n"
            "  closed: Result[Void] = File.close(handle, 1000)\n"
            "  IO.inspect(first)\n"
            "  IO.inspect(second)\n"
            "  IO.inspect(rest)\n"
            "  IO.inspect(eof)\n"
            "end\n\n")
           (literal (path->string path)))))
       (check-equal? result (void))
       (check-true (string-contains? output "ok(\"one\")"))
       (check-true (string-contains? output "ok(\"two\")"))
       (check-true (string-contains? output "ok([108, 97, 115, 116])"))
       (check-true (string-contains? output "ok([])")))))

  (test-case "file operations follow symlinks to regular files"
    (with-temp-dir
     (lambda (root)
       (define target (build-path root "target.txt"))
       (define alias (build-path root "alias.txt"))
       (call-with-output-file target (lambda (port) (display "linked" port)))
       (make-file-or-directory-link target alias)
       (define-values (output result)
         (run-program
          (format
           (string-append
            "def main() -> Void\n"
            "  contents: Result[String] = File.read_text(~a, 1000)\n"
            "  info: Result[FileInfo] = File.stat(~a, 1000)\n"
            "  IO.inspect(contents)\n"
            "  IO.inspect(info)\n"
            "end\n\n")
           (literal (path->string alias))
           (literal (path->string alias)))))
       (check-equal? result (void))
       (check-true (string-contains? output "ok(\"linked\")"))
       (check-true (string-contains? output "FileInfo(kind: \"file\", size_bytes: 6")))))

  (test-case "empty files read as empty text and relative symlinks resolve from the link directory"
    (with-temp-dir
     (lambda (root)
       (define nested (build-path root "nested"))
       (define empty-path (build-path root "empty.txt"))
       (define target (build-path nested "target.txt"))
       (define alias (build-path nested "alias.txt"))
       (make-directory* nested)
       (call-with-output-file empty-path void #:exists 'truncate)
       (call-with-output-file target (lambda (port) (display "linked" port)) #:exists 'truncate)
       (make-file-or-directory-link "target.txt" alias)
       (define-values (output result)
         (run-program
          (format
           (string-append
            "def main() -> Void\n"
            "  empty: Result[String] = File.read_text(~a, 1000)\n"
            "  linked: Result[String] = File.read_text(~a, 1000)\n"
            "  IO.inspect(empty)\n"
            "  IO.inspect(linked)\n"
            "end\n\n")
           (literal (path->string empty-path))
           (literal (path->string alias)))))
       (check-equal? result (void))
       (check-true (string-contains? output "ok(\"\")"))
       (check-true (string-contains? output "ok(\"linked\")")))))

  (test-case "the end of a run flushes and closes an unclosed file handle"
    (with-temp-dir
     (lambda (root)
       (define path (build-path root "cleanup.txt"))
       (define-values (_output result)
         (run-program
          (format
           (string-append
            "def main() -> Void\n"
            "  opened: Result[FileHandle] = File.open(~a, \"write\", 1000)\n"
            "  handle: FileHandle = Result.unwrap!(opened)\n"
            "  wrote: Result[Void] = File.write(handle, \"cleanup\", 1000)\n"
            "end\n\n")
           (literal (path->string path)))))
       (check-equal? result (void))
       (check-equal? (file->string path) "cleanup"))))))
