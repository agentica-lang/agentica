#lang racket

(require rackunit racket/runtime-path)

(define-runtime-path source-directory "../src")
(define-runtime-path library-directory "../stdlib")
(define vm-name (if (eq? (system-type 'os) 'windows) "agentica-vm.exe" "agentica-vm"))
(define-runtime-path dist-directory "../dist")

(for ([name '(#"AGENTICA_VM_TRACE" #"AGENTICA_VM_TRACE_FILE")])
  (environment-variables-set! (current-environment-variables) name #f))

(module+ test
  (test-case "distributed executable imports stdlib after its build checkout is deleted"
    (define directory (make-temporary-file "agentica-distribution~a" 'directory))
    (dynamic-wind void
      (lambda ()
        (define checkout (build-path directory "checkout"))
        (make-directory checkout)
        (copy-directory/files source-directory (build-path checkout "src"))
        (copy-directory/files library-directory (build-path checkout "stdlib"))
        ;; Recompile against this checkout, not copied bytecode/dependency paths.
        (delete-directory/files (build-path checkout "src" "compiled") #:must-exist? #f)
        (define raco (find-executable-path "raco"))
        (check-not-false raco)
        (define executable (build-path directory "agentica"))
        (check-true (system* raco "exe" "-o" executable
                             (build-path checkout "src" "main.rkt")))
        (define bundle (build-path directory "bundle"))
        (check-true (system* raco "distribute" bundle executable))
        (delete-directory/files checkout)
        (delete-file executable)
        (define relocated (build-path directory "relocated"))
        (rename-file-or-directory bundle relocated)
        (copy-file (build-path dist-directory vm-name) (build-path relocated "bin" vm-name))
        (define program (build-path directory "program.agc"))
        (display-to-file
         "import \"std/queue\" as Queue\ndef main() -> Void\n  q = Queue.push(Queue.new(), \"embedded\")\n  puts(Result.unwrap!(Queue.peek(q)))\nend\n\n"
         program)
        (define out (open-output-string))
        (define err (open-output-string))
        (parameterize ([current-directory directory]
                       [current-output-port out] [current-error-port err])
          (define bin (build-path relocated "bin"
                                  (if (eq? (system-type 'os) 'windows) "agentica.exe" "agentica")))
          (check-true (system* bin program) (get-output-string err)))
        (check-equal? (get-output-string err) "")
        (check-equal? (get-output-string out) "embedded\n"))
      (lambda () (delete-directory/files directory)))))
