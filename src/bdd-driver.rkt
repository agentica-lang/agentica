#lang racket

;; `agentica test`: the hand-off to the BDD driver, a program in Agentica (compiler/bdd.agc; docs/future/35-self-hosting.md,
;; step 7b). The driver finds the test files, compiles them, runs the runner on the VM and prints the report. This
;; module only starts it on the VM, as `agentica file.agc` starts a program, and gives it what only this process knows:
;; the VM, the std/ sources (they are embedded in this program, so they go to the driver on its stdin, and it writes
;; them to its own private run directory) and the command that runs agentica. Until step 8 moves the command line to
;; Agentica too, the driver is compiled by `make` (dist/agentica-bdd-driver.agcb) and shipped next to the VM, never
;; compiled on a run.

(require file/sha1 json racket/os racket/random racket/runtime-path
         "stdlib.rkt" "vm-launch.rkt")

(provide run-agentica-test find-bdd-driver)

(define-runtime-path main-program "main.rkt")

(define driver-name "agentica-bdd-driver.agcb")

;; The compiled driver: dist/ in a checkout, next to the executable otherwise (as find-vm finds the VM).
(define (find-bdd-driver)
  (define here (variable-reference->module-source (#%variable-reference)))
  (cond
    [(path? here)
     (define-values (directory _name _dir?) (split-path here))
     (simplify-path (build-path directory 'up "dist" driver-name) #f)]
    [else (build-path (path-only (running-executable)) driver-name)]))

;; The command that runs agentica, which the runner gives to the programs under test.
(define (agentica-command)
  (if (path? (variable-reference->module-source (#%variable-reference)))
      (list (path->string (or (find-executable-path "racket") (find-system-path 'exec-file)))
            (path->string main-program))
      (list (path->string (running-executable)))))

;; The std/ sources of the registry as the JSON the driver reads on stdin: {"files": [{"path": "bdd/match.agc", "text": ...}]}.
;; The key std/bdd/match.agc is the file bdd/match.agc of the stdlib/ folder that the Agentica linker reads.
(define (std-sources-json)
  (jsexpr->string
   (hasheq 'files (for/list ([(key text) (in-hash stdlib-sources)])
                    (hasheq 'path (substring key (string-length "std/")) 'text text)))))

;; A private copy of the driver for the VM to run, next to where `agentica file.agc` puts its bytecode: a VM started
;; with --driver-pid reads only a private file (owner, no group or other bits) and deletes it after the load. The
;; driver must not leave more than that in the temporary directory when this process is killed.
(define (write-private-copy driver)
  (define copy (build-path (find-system-path 'temp-dir)
                           (format "agentica-bdd-driver-~a.agcb" (bytes->hex-string (crypto-random-bytes 16)))))
  (call-with-output-file copy #:exists 'error #:permissions #o600
    (lambda (out) (write-bytes (file->bytes driver) out)))
  copy)

(define (capture port)
  (define out (open-output-bytes))
  (values out (thread (lambda () (copy-port port out) (close-input-port port)))))

;; Runs the driver on the VM with the arguments and waits for it. The std/ sources go to its stdin. Its stdout is the
;; report, kept to be returned; its stderr is shown at once. A break (Ctrl-C, SIGTERM) stops the VM, which stops the
;; driver's children, as the Racket driver stopped the runner; unlike that driver, this one does not remove its run
;; directory then (see 35.5).
(define (run-driver vm driver arguments)
  (define-values (process stdout stdin stderr)
    (apply subprocess #f #f #f vm
           (append (list "--allow-run" "--driver-pid" (number->string (getpid)) "--" (path->string driver)) arguments)))
  ;; A driver that ends before it reads its stdin (a usage error) breaks the pipe: that is not an error here.
  (define sender
    (thread (lambda ()
              (with-handlers ([exn:fail? void])
                (write-string (std-sources-json) stdin)
                (close-output-port stdin)))))
  (define broke? #f)
  (dynamic-wind
    void
    (lambda ()
      (call-noting-break
       (lambda () (set! broke? #t))
       (lambda ()
         (define-values (out out-reader) (capture stdout))
         (define errors (current-error-port))
         (define err-reader (thread (lambda () (copy-port stderr errors) (close-input-port stderr))))
         (subprocess-wait process)
         (thread-wait out-reader)
         (thread-wait err-reader)
         (define status (subprocess-status process))
         (define text (bytes->string/utf-8 (get-output-bytes out) (integer->char #xFFFD)))
         ;; A driver that ran always printed a report or a usage message. A VM that stopped on a runtime error of the
         ;; driver (status 1) printed nothing, and must not look like "the tests failed": that is status 2.
         (values (if (and (equal? text "") (not (eqv? status 0))) 2 status) text))))
    (lambda ()
      (kill-thread sender)
      (with-handlers ([exn:fail? void]) (close-output-port stdin))
      (parameterize-break #f (stop-vm process #:interrupted? broke?)))))

;; Runs `agentica test`. `arguments` are the words after `test`, `step-files` the --steps given before it; the driver
;; reads both and reports usage errors itself. Gives the exit status and the text to print.
(define (run-agentica-test arguments step-files #:style style #:allow-run allow-run? #:seed seed #:vm vm
                           #:test-timeout-ms [test-timeout-ms 30000])
  (define driver (find-bdd-driver))
  (cond
    [(not (and (file-exists? vm) (memq 'execute (file-or-directory-permissions vm))))
     (eprintf "agentica: cannot find the VM at ~a; run make vm or set AGENTICA_VM\n" vm)
     (values 2 "")]
    [(not (file-exists? driver))
     (eprintf "agentica: cannot find the BDD driver at ~a; run make dist/agentica-bdd-driver.agcb\n" driver)
     (values 2 "")]
    [else
     (define copy (with-handlers ([exn:fail:filesystem? (lambda (_) #f)]) (write-private-copy driver)))
     (cond
       [(not copy)
        (eprintf "agentica: cannot write a temporary file in ~a\n" (find-system-path 'temp-dir))
        (values 2 "")]
       [else
        (dynamic-wind
          void
          (lambda ()
            (run-driver vm copy
                        (append (list "--vm" (path->string vm)
                                      "--style" (symbol->string style)
                                      "--test-timeout-ms" (number->string test-timeout-ms))
                                (if allow-run? '("--allow-run") '())
                                (if seed (list "--seed" (number->string seed)) '())
                                (append-map (lambda (word) (list "--agentica" word)) (agentica-command))
                                '("--")
                                (append-map (lambda (file) (list "--steps" file)) step-files)
                                arguments)))
          ;; The VM deletes its copy of the driver after loading it; this covers a VM that never got there.
          (lambda () (parameterize-break #f (with-handlers ([exn:fail:filesystem? void]) (delete-file copy)))))])]))
