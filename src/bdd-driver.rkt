#lang racket

(require file/sha1 json racket/random racket/runtime-path
         "bytecode.rkt" "checker.rkt" "diagnostic.rkt" "lexer.rkt" "lower.rkt"
         "modules.rkt" "parser.rkt" "source.rkt" "vm-launch.rkt")

(provide run-agentica-test bdd-usage-report)

(define-runtime-path main-program "main.rkt")

(define runner-root "import \"std/bdd/runner\" as Runner\n\ndef main() -> Void\n  Runner.main()\nend\n")
(define default-steps "import \"std/bdd\" as BDD\n\ndef main() -> Void\n  BDD.run([])\nend\n")

(define (agentica-command)
  (if (path? (variable-reference->module-source (#%variable-reference)))
      (list (path->string (or (find-executable-path "racket") (find-system-path 'exec-file)))
            (path->string main-program))
      (list (path->string (running-executable)))))

(define (first-line-span file)
  (source-span (source file "") (source-position 0 1 1) (source-position 0 1 1)))

(define (one-error-report problem style)
  (define error (diagnostic->jsexpr problem))
  (define file (hash-ref error 'file))
  (values 2
          (if (eq? style 'json)
              (string-append
               (jsexpr->string
                (hasheq 'ok #f 'passed 0 'failed 0 'not_executed 0 'file_errors 1 'exit_code 2
                        'files (list (hasheq 'path file 'feature "" 'status "failed" 'scenarios '() 'error error))))
               "\n")
              (format "FAIL ~a~a~a:1:1 [~a] ~a\n0 passed, 0 failed, 0 not executed, 1 file errors\n"
                      file (if (eq? style 'ai) " | " "\n") file (hash-ref error 'code) (hash-ref error 'message)))))

(define (bdd-usage-report message style)
  (one-error-report (diagnostic 'RUNTIME-BDD-USAGE message (first-line-span "<arguments>")) style))

(define (infrastructure-report message file style)
  (one-error-report (diagnostic 'RUNTIME-BDD-INFRA message (first-line-span file)) style))

(define (compile-text name text)
  (let/ec stop
    (define (pass value) (if (diagnostic? value) (stop value) value))
    (define tree (pass (parse (pass (lex (source name text))))))
    (define types (make-hasheq))
    (define checked (pass (check (pass (link-program tree name)) #:types types)))
    (pass (write-bytecode (pass (ir->bytecode (pass (lower checked types))))))))

(define (compile-steps path directory)
  (cond
    [(not path) (compile-text (path->string (build-path directory "steps.agc")) default-steps)]
    [else
     (define file (path->string (path->complete-path path)))
     (define text
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (file->string file)))
     (if text
         (compile-text file text)
         (diagnostic 'RUNTIME-BDD-INFRA (format "cannot read the step program ~a" path) (first-line-span file)))]))

(define (write-private path data)
  (call-with-output-file path #:exists 'error #:permissions #o600
    (lambda (out) (void (write-bytes data out)))))

(define (capture port)
  (define out (open-output-bytes))
  (values out (thread (lambda () (copy-port port out) (close-input-port port)))))

(define (run-runner vm runner config seed)
  (define environment (environment-variables-copy (current-environment-variables)))
  (for ([name '(#"AGENTICA_VM_METRICS" #"AGENTICA_VM_METRICS_FILE")])
    (environment-variables-set! environment name #f))
  (define-values (process stdout stdin stderr)
    (parameterize ([current-environment-variables environment])
      (apply subprocess #f #f #f vm
             (append '("--allow-run") (if seed (list "--seed" (number->string seed)) '())
                     (list "--" (path->string runner) config)))))
  (close-output-port stdin)
  (dynamic-wind
    void
    (lambda ()
      (define-values (out out-reader) (capture stdout))
      (define-values (err err-reader) (capture stderr))
      (subprocess-wait process)
      (thread-wait out-reader)
      (thread-wait err-reader)
      (values (subprocess-status process)
              (bytes->string/utf-8 (get-output-bytes out) #\uFFFD)
              (bytes->string/utf-8 (get-output-bytes err) #\uFFFD)))
    (lambda () (parameterize-break #f (stop-vm process)))))

(define (run-agentica-test paths step-files #:style style #:allow-run allow-run? #:seed seed #:vm vm)
  (cond
    [(> (length step-files) 1)
     (bdd-usage-report "one --steps program; import the other files from it" style)]
    [(not (and (file-exists? vm) (memq 'execute (file-or-directory-permissions vm))))
     (infrastructure-report (format "cannot find the VM at ~a; run make vm or set AGENTICA_VM" vm)
                            (path->string vm) style)]
    [else
     (define directory
       (build-path (find-system-path 'temp-dir)
                   (format "agentica-bdd-~a" (bytes->hex-string (crypto-random-bytes 16)))))
     (define created? #f)
     (with-handlers ([exn:break? raise])
       (dynamic-wind
         (lambda () (parameterize-break #f (make-directory directory #o700) (set! created? #t)))
         (lambda () (run-in directory paths (and (pair? step-files) (car step-files)) style allow-run? seed vm))
         (lambda () (when created? (delete-directory/files directory #:must-exist? #f)))))]))

(define (run-in directory paths step-file style allow-run? seed vm)
  (define runner-file (build-path directory "runner.agcb"))
  (define steps-file (build-path directory "steps.agcb"))
  (define runner (compile-text (path->string (build-path directory "runner.agc")) runner-root))
  (define steps (compile-steps step-file directory))
  (cond
    [(diagnostic? runner)
     (infrastructure-report (format "the BDD runner does not compile: ~a" (diagnostic-message runner))
                            (path->string vm) style)]
    [else
     (write-private runner-file runner)
     (unless (diagnostic? steps) (write-private steps-file steps))
     (define config
       (jsexpr->string
        (hasheq 'vm (path->string vm)
                'steps_bytecode (path->string steps-file)
                'steps_source (path->string (if step-file (path->complete-path step-file) (build-path directory "steps.agc")))
                'steps_error (if (diagnostic? steps) (jsexpr->string (diagnostic->jsexpr steps)) "")
                'agentica (agentica-command)
                'paths paths
                'style (symbol->string style)
                'allow_run allow-run?
                'seeded (and seed #t)
                'seed (or seed 0))))
     (define-values (status out err)
       (with-handlers ([exn:fail? (lambda (failure) (values #f "" (exn-message failure)))])
         (run-runner vm runner-file config seed)))
     (if (and (memv status '(0 1 2)) (equal? err ""))
         (values status out)
         (infrastructure-report
          (format "the BDD runner failed with exit code ~a: ~a" status
                  (let ([lines (string-split err "\n")]) (if (null? lines) "no diagnostic" (last lines))))
          (path->string vm) style))]))
