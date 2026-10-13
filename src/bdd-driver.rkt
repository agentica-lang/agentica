#lang racket

(require (only-in ffi/unsafe -> _fun _int get-ffi-obj)
         file/sha1 json racket/os racket/random racket/runtime-path
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
    (define ir (lower checked types))
    (when (and (diagnostic? ir) (eq? (diagnostic-code ir) 'LOWER-UNSUPPORTED))
      (stop (diagnostic 'LOWER-UNSUPPORTED (diagnostic-message ir) (diagnostic-span ir) #:help vm-only-help)))
    (pass (write-bytecode (pass (ir->bytecode (pass ir)))))))

(define (feature-name? name)
  (regexp-match? #rx#"[.]feature$" (path->bytes name)))

(define (utf-8-name? name)
  (with-handlers ([exn:fail:contract? (lambda (_) #f)])
    (and (bytes->string/utf-8 (path->bytes name)) #t)))

(define (discover paths)
  (define errors '())
  (define targets '())
  (define (fail! path message)
    (set! errors (cons (hasheq 'path (path->string path) 'problem message) errors)))
  (define (walk directory)
    (define names
      (with-handlers ([exn:fail? (lambda (failure) (fail! directory (format "cannot list the directory: ~a" (exn-message failure))) '())])
        (directory-list directory)))
    (for ([name (in-list names)])
      (define path (build-path directory name))
      (define type
        (with-handlers ([exn:fail? (lambda (failure) (fail! path (format "cannot read the file information: ~a" (exn-message failure))) #f)])
          (file-or-directory-type path #t)))
      (cond
        [(not type) (void)]
        [(and (not (utf-8-name? name)) (or (eq? type 'directory) (feature-name? name)))
         (fail! path "the file name is not valid UTF-8")]
        [(eq? type 'directory) (walk path)]
        [(not (feature-name? name)) (void)]
        [(eq? type 'file) (set! targets (cons path targets))]
        [(and (eq? type 'link) (file-exists? path)) (set! targets (cons path targets))]
        [(memq type '(link directory-link)) (fail! path "the symbolic link does not name a file")])))
  (for ([given (in-list paths)])
    (define path (simplify-path (path->complete-path given) #f))
    (cond
      [(directory-exists? path) (walk path)]
      [(file-exists? path) (set! targets (cons path targets))]
      [else (fail! path "feature path does not exist")]))
  (define files (sort (remove-duplicates (map path->string targets)) string<?))
  (append (reverse errors) (for/list ([file (in-list files)]) (hasheq 'path file 'problem ""))))

(define stale-name #rx"^agentica-bdd-[0-9a-f]+$")

(define (lock-file directory)
  (build-path directory "lock"))

(define (take-lock directory)
  (define port (open-output-file (lock-file directory) #:exists 'error #:permissions #o600))
  (define locked?
    (with-handlers ([(lambda (_) #t) (lambda (failure) (close-output-port port) (raise failure))])
      (port-try-file-lock? port 'exclusive)))
  (unless locked?
    (close-output-port port)
    (error 'agentica "cannot lock ~a" directory))
  port)

(define (abandoned? path owner)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (and (eq? (file-or-directory-type path #t) 'directory)
         (equal? (hash-ref (file-or-directory-stat path #t) 'user-id) owner)
         (eq? (file-or-directory-type (lock-file path) #t) 'file)
         (let ([port (open-output-file (lock-file path) #:exists 'update)])
           (if (port-try-file-lock? port 'exclusive)
               port
               (begin (close-output-port port) #f))))))

(define (sweep-stale temporary own)
  (define owner (hash-ref (file-or-directory-stat own #t) 'user-id))
  (for ([name (in-list (with-handlers ([exn:fail:filesystem? (lambda (_) '())]) (directory-list temporary)))])
    (define path (build-path temporary name))
    (define held (and (regexp-match? stale-name (path->bytes name)) (not (equal? path own)) (abandoned? path owner)))
    (when held
      (with-handlers ([exn:fail? void])
        (delete-directory/files path #:must-exist? #f))
      (close-output-port held))))

(define unix-geteuid (get-ffi-obj "geteuid" #f (_fun -> _int) (lambda () #f)))

(define (shared-and-not-sticky? temporary)
  (define stat (file-or-directory-stat temporary))
  (define mode (hash-ref stat 'mode))
  (define (writable? bits) (not (zero? (bitwise-and mode bits))))
  (and (zero? (bitwise-and mode #o1000))
       (or (writable? #o002)
           (and (writable? #o020)
                (not (and unix-geteuid (equal? (hash-ref stat 'user-id) (unix-geteuid))))))))

(define (message-line text pick)
  (define lines (string-split text "\n"))
  (if (null? lines) "no diagnostic" (pick lines)))

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
                     (list "--driver-pid" (number->string (getpid)) "--" (path->string runner) (path->string config))))))
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
     (define temporary (find-system-path 'temp-dir))
     (define hex (bytes->hex-string (crypto-random-bytes 16)))
     (define directory (build-path temporary (format "agentica-bdd-~a" hex)))
     (define current (build-path temporary (format "agentica-bdd-new-~a" hex)))
     (define created? #f)
     (define lock #f)
     (with-handlers ([exn:break? raise])
       (with-handlers ([exn:fail? (lambda (failure) (infrastructure-report (message-line (exn-message failure) car) (path->string temporary) style))])
         (if (shared-and-not-sticky? temporary)
             (infrastructure-report
              (format "the temporary directory ~a is shared and not sticky; set TMPDIR to a private folder" temporary)
              (path->string temporary) style)
             (dynamic-wind
               (lambda ()
                 (parameterize-break #f
                   (make-directory current #o700)
                   (set! created? #t)))
               (lambda ()
                 (parameterize-break #f
                   (set! lock (take-lock current))
                   (rename-file-or-directory current directory)
                   (set! current directory))
                 (sweep-stale temporary directory)
                 (run-in directory paths (and (pair? step-files) (car step-files)) style allow-run? seed vm))
               (lambda ()
                 (parameterize-break #f
                   (with-handlers ([exn:fail? void])
                     (when created? (delete-directory/files current #:must-exist? #f)))
                   (with-handlers ([exn:fail? void])
                     (when lock (close-output-port lock)))))))))]))

(define (run-in directory paths step-file style allow-run? seed vm)
  (define runner-file (build-path directory "runner.agcb"))
  (define steps-file (build-path directory "steps.agcb"))
  (define config-file (build-path directory "config.jsonl"))
  (define runner (compile-text (path->string (build-path directory "runner.agc")) runner-root))
  (define steps (compile-steps step-file directory))
  (cond
    [(diagnostic? runner)
     (infrastructure-report (format "the BDD runner does not compile: ~a" (diagnostic-message runner))
                            (path->string vm) style)]
    [else
     (write-private runner-file runner)
     (unless (diagnostic? steps) (write-private steps-file steps))
     (define entries (discover paths))
     (define config
       (jsexpr->string
        (hasheq 'vm (path->string vm)
                'steps_bytecode (path->string steps-file)
                'steps_source (path->string (if step-file (path->complete-path step-file) (build-path directory "steps.agc")))
                'steps_error (if (diagnostic? steps) (jsexpr->string (diagnostic->jsexpr steps)) "")
                'agentica (agentica-command)
                'count (length entries)
                'empty_path (path->string (simplify-path (path->complete-path (car paths)) #f))
                'style (symbol->string style)
                'allow_run allow-run?
                'seeded (and seed #t)
                'seed (or seed 0))))
     (write-private config-file
                    (string->bytes/utf-8
                     (string-append* config "\n" (for/list ([entry (in-list entries)]) (string-append (jsexpr->string entry) "\n")))))
     (define-values (status out err)
       (with-handlers ([exn:fail? (lambda (failure) (values #f "" (exn-message failure)))])
         (run-runner vm runner-file config-file seed)))
     (if (and (memv status '(0 1 2)) (equal? err ""))
         (values status out)
         (infrastructure-report
          (format "the BDD runner failed with exit code ~a: ~a" status
                  (message-line err last))
          (path->string vm) style))]))
