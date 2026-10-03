#lang racket

(require (except-in rackunit check)
         racket/file
         racket/runtime-path
         racket/list
         "../src/checker.rkt"
         "../src/diagnostic.rkt"
         "../src/evaluator.rkt"
         "../src/lexer.rkt"
         "../src/parser.rkt"
         "../src/source.rkt")

(define-runtime-path examples-dir "../examples")

(define (run-program text #:args [arguments '()])
  (define result #f)
  (define output
    (with-output-to-string
      (lambda ()
        (set! result
              (let* ([lexed (lex (source "filesystem-test.agc" text))]
                     [parsed (if (diagnostic? lexed) lexed (parse lexed))]
                     [checked (if (diagnostic? parsed) parsed (check parsed))])
                (if (diagnostic? checked) checked (evaluate checked #:args arguments)))))))
  (values output result))

(define (with-temp-dir proc)
  (define directory (make-temporary-file "agentica-filesystem~a" 'directory))
  (dynamic-wind
    void
    (lambda () (proc (path->string directory)))
    (lambda () (delete-directory/files directory))))

(define (literal text) (format "~s" text))

(module+ test
  (test-case "file-summary example reads a command-line path"
    (define input-path (build-path examples-dir "hello.agc"))
    (define-values (output result)
      (run-program (file->string (build-path examples-dir "file-summary.agc"))
                   #:args (list (path->string input-path))))
    (check-equal? result 'nil)
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
            "def main() -> Nil\n"
            "  made: Result[Nil] = Dir.mkdir(~a, 1000)\n"
            "  made_again: Result[Nil] = Dir.mkdir(~a, 1000)\n"
            "  opened: Result[FileHandle] = File.open(~a, \"write\", 1000)\n"
            "  handle: FileHandle = Result.unwrap!(opened)\n"
            "  wrote: Result[Nil] = File.write(handle, \"alpha\\n\", 1000)\n"
            "  wrote_bytes: Result[Nil] = File.write_bytes(handle, [98, 101, 116, 97], 1000)\n"
            "  closed: Result[Nil] = File.close(handle, 1000)\n"
            "  closed_again: Result[Nil] = File.close(handle, 1000)\n"
            "  appended: Result[Nil] = File.append_text(~a, \"\\nend\", 1000)\n"
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
            "end\n")
           (literal (path->string directory))
           (literal (path->string directory))
           (literal (path->string path))
           (literal (path->string path))
           (literal (path->string path))
           (literal (path->string path))
           (literal (path->string (build-path root "nested" ".." "nested" "data")))
           (literal (path->string directory))
           (literal (path->string (build-path root "nested" ".." "nested" "data"))))))
       (check-equal? result 'nil)
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
            "def main() -> Nil\n"
            "  invalid_mode: Result[FileHandle] = File.open(~a, \"readwrite\", 1000)\n"
            "  opened: Result[FileHandle] = File.open(~a, \"write\", 1000)\n"
            "  handle: FileHandle = Result.unwrap!(opened)\n"
            "  wrote: Result[Nil] = File.write_bytes(handle, [255], 1000)\n"
            "  closed: Result[Nil] = File.close(handle, 1000)\n"
            "  closed_read: Result[List[Int]] = File.read_bytes(handle, 1, 1000)\n"
            "  invalid_utf8: Result[String] = File.read_text(~a, 1000)\n"
            "  oversized: Result[String] = File.read_text(~a, 1000)\n"
            "  IO.inspect(invalid_mode)\n"
            "  IO.inspect(closed_read)\n"
            "  IO.inspect(invalid_utf8)\n"
            "  IO.inspect(oversized)\n"
            "end\n")
           (literal (path->string path))
           (literal (path->string path))
           (literal (path->string path))
           (literal (path->string large-path)))))
       (check-equal? result 'nil)
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
            "def main() -> Nil\n"
            "  opened: Result[FileHandle] = File.open(~a, \"read\", 1000)\n"
            "  handle: FileHandle = Result.unwrap!(opened)\n"
            "  first: Result[String] = File.read_line(handle, 1000)\n"
            "  second: Result[String] = File.read_line(handle, 1000)\n"
            "  rest: Result[List[Int]] = File.read_bytes(handle, 100, 1000)\n"
            "  eof: Result[List[Int]] = File.read_bytes(handle, 100, 1000)\n"
            "  closed: Result[Nil] = File.close(handle, 1000)\n"
            "  IO.inspect(first)\n"
            "  IO.inspect(second)\n"
            "  IO.inspect(rest)\n"
            "  IO.inspect(eof)\n"
            "end\n")
           (literal (path->string path)))))
       (check-equal? result 'nil)
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
            "def main() -> Nil\n"
            "  contents: Result[String] = File.read_text(~a, 1000)\n"
            "  info: Result[FileInfo] = File.stat(~a, 1000)\n"
            "  IO.inspect(contents)\n"
            "  IO.inspect(info)\n"
            "end\n")
           (literal (path->string alias))
           (literal (path->string alias)))))
       (check-equal? result 'nil)
       (check-true (string-contains? output "ok(\"linked\")"))
       (check-true (string-contains? output "FileInfo(kind: \"file\", size_bytes: 6")))))

  (test-case "evaluation cleanup closes an unclosed file handle"
    (with-temp-dir
     (lambda (root)
       (define path (build-path root "cleanup.txt"))
       (define-values (_output result)
         (run-program
          (format
           (string-append
            "def main() -> Nil\n"
            "  opened: Result[FileHandle] = File.open(~a, \"write\", 1000)\n"
            "  handle: FileHandle = Result.unwrap!(opened)\n"
            "  wrote: Result[Nil] = File.write(handle, \"cleanup\", 1000)\n"
            "end\n")
           (literal (path->string path)))))
       (check-equal? result 'nil)
       (check-equal? (file->string path) "cleanup"))))))
