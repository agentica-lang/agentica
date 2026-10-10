#lang racket

(require json
         "builtins.rkt"
         "ast.rkt"
         "diagnostic.rkt"
         "bdd.rkt"
         "runtime-values.rkt"
         "task.rkt"
         "builtin-types.rkt" "network.rkt" "filesystem.rkt" "process.rkt" "http-wire.rkt" "http-client.rkt" "http-server.rkt"
         "json.rkt"
         "json-typed.rkt"
         (only-in racket/random crypto-random-bytes))

(provide evaluate
         (struct-out instance)
         (struct-out mapping)
         (struct-out exit-code)
         (struct-out function-value)
         (struct-out enum-value))

(define int-min (- (expt 2 63)))
(define int-max (sub1 (expt 2 63)))
(define decimal-integer-pattern #px"^[+-]?[0-9]+$")
(define decimal-float-pattern #px"^[+-]?[0-9]+(\\.[0-9]+)?$")

(define max-call-depth 10000)

(define max-seed (sub1 (expt 2 31)))

(define (random-seed-from-os)
  (modulo (integer-bytes->integer (crypto-random-bytes 4) #f) (add1 max-seed)))

(define (random-in-range low high)
  (define size (add1 (- high low)))
  (if (<= size 4294967087)
      (+ low (random size))
      (let* ([space (expt 2 64)]
             [limit (* size (quotient space size))])
        (let loop ()
          (define bits
            (for/fold ([n 0]) ([_ (in-range 4)])
              (+ (* n 65536) (random 65536))))
          (if (< bits limit)
              (+ low (modulo bits size))
              (loop))))))

(define (order<? a b)
  (cond
    [(string? a) (string<? a b)]
    [(nan? a) #f]
    [(nan? b) #t]
    [else (< a b)]))
;; ponytail: cap eager reads at 1 MiB per call; stream larger inputs in chunks.
(define max-read-bytes (* 1024 1024))

(define (evaluate program
                  #:in [input (current-input-port)]
                  #:out [output (current-output-port)]
                  #:err [error-output (current-error-port)]
                  #:args [program-args '()]
                  #:max-steps [max-steps #f]
                  #:entrypoint [entrypoint "main"]
                  #:arguments [arguments '()]
                  #:builtin-handler [builtin-handler #f]
                  #:require-complete-tasks? [require-complete? #f]
                  #:allow-run [allow-run? (current-process-allowed?)]
                  #:seed [seed #f])
  (parameterize ([current-input-port input]
                 [current-output-port output]
                 [current-error-port error-output]
                 [current-pseudo-random-generator (make-pseudo-random-generator)])
    (random-seed (or seed (random-seed-from-os)))
    (define functions
      (for/hash ([declaration (in-list (program-declarations program))]
                 #:when (function-decl? declaration))
        (values (function-decl-name declaration) declaration)))
    (define struct-fields
      (for/fold ([fields builtin-field-order]) ([declaration (in-list (program-declarations program))]
                 #:when (struct-decl? declaration))
        (hash-set fields (struct-decl-name declaration) (map field-decl-name (struct-decl-fields declaration)))))
    (define enum-names
      (for/hash ([declaration (in-list (program-declarations program))]
                 #:when (enum-decl? declaration))
        (values (enum-decl-name declaration) #t)))
    (define file-handles (make-hasheq))
    (define file-registry-lock (make-semaphore 1))
    (define file-registry-closing? (box #f))
    (define processes (make-hasheq))
    (define process-lock (make-semaphore 1))
    (define process-closing? (box #f))
    (task-run
     (lambda (run)
       (parameterize ([current-network-owner run]
                      [current-network-shutdown (lambda (cust) (task-shutdown! run cust))]
                      [current-file-owner run]
                      [current-file-shutdown (lambda (cust) (task-shutdown! run cust))]
                      [current-file-handles file-handles]
                      [current-file-registry-lock file-registry-lock]
                      [current-file-registry-closing file-registry-closing?]
                      [current-process-owner run]
                      [current-process-registry processes]
                      [current-process-registry-lock process-lock]
                      [current-process-closing process-closing?]
                      [current-process-custodian (current-custodian)]
                      [current-process-allowed? allow-run?])
         (evaluate-with-ports program program-args entrypoint arguments builtin-handler
                              functions struct-fields enum-names run)))
     max-steps (program-span program) #:require-complete? require-complete?
     #:cleanup (lambda ()
                 (process-close-all! processes process-lock process-closing?)
                 (filesystem-close-all! file-handles file-registry-lock file-registry-closing?)))))

(define (evaluate-with-ports program program-args entrypoint entry-arguments builtin-handler
                             functions struct-fields enum-names run)
  (define scopes '())
  (define return-to #f)
  (define depth 0)

  (with-handlers ([exn:fail?
                   (lambda (failure)
                     (diagnostic 'RUNTIME-INTERNAL
                                 (exn-message failure)
                                 (program-span program)))])
   (let/ec escape
    (define (bail code message span)
      (escape (diagnostic code message span)))

    (define (step! span)
      (define problem (task-step! run span))
      (when problem (escape problem)))

    (define (push-scope!) (set! scopes (cons (make-hash) scopes)))
    (define (pop-scope!) (set! scopes (cdr scopes)))
    (define loop-break (make-parameter #f))
    (define loop-next (make-parameter #f))
    (define (run-loop body)
      (define saved scopes)
      (let/ec break-k
        (parameterize ([loop-break (lambda () (set! scopes saved) (break-k (void)))])
          (body (lambda (step)
                  (let/ec next-k
                    (parameterize ([loop-next (lambda () (set! scopes saved) (next-k (void)))])
                      (step))))))))

    (define (lookup name)
      (for/or ([frame (in-list scopes)])
        (hash-ref frame name #f)))

    (define (define! name value)
      (hash-set! (car scopes) name (box value)))

    (define (assign! name value)
      (set-box! (lookup name) value))

    (define (in-int-range n span [fail bail])
      (unless (<= int-min n int-max)
        (fail 'RUNTIME-INTEGER-OVERFLOW "Int result is outside the 64-bit range" span))
      n)

    (define (unreachable what span)
      (bail 'RUNTIME-UNREACHABLE (format "cannot evaluate ~a" what) span))

    (define (fallible bang? operation)
      (let/ec failed
        (define (fail code message where)
          (if bang? (bail code message where) (failed (result-error message))))
        (define value (operation fail))
        (if bang? value (result-ok value))))

    (define (json-extract value predicate expected [convert values])
      (define data (json-value-data value))
      (if (predicate data)
          (result-ok (convert data))
          (result-error (format "expected ~a" expected))))

    (define (json-data value span)
      (cond
        [(json-value? value) (json-value-data value)]
        [(instance? value)
         (for/hasheq ([key (in-list (hash-ref struct-fields (instance-type-name value)))])
           (values (string->symbol key) (json-data (hash-ref (instance-fields value) key) span)))]
        [(mapping? value)
         (for/hasheq ([(key item) (in-hash (mapping-table value))])
           (values (string->symbol key) (json-data item span)))]
        [(list? value) (map (lambda (item) (json-data item span)) value)]
        [(and (real? value) (not (rational? value)))
         (bail 'RUNTIME-JSON-ENCODE "cannot encode a non-finite Float" span)]
        [else value]))

    (define (encode-json value span)
      (define out (open-output-string))
      (define (write-object keys ref)
        (display "{" out)
        (for ([key (in-list keys)] [i (in-naturals)])
          (unless (zero? i) (display "," out))
          (write-json key out)
          (display ":" out)
          (write-value (ref key)))
        (display "}" out))
      (define (write-value value)
        (cond
          [(json-value? value) (write-json (json-value-data value) out #:null 'nil)]
          [(instance? value)
           (write-object (hash-ref struct-fields (instance-type-name value))
                         (lambda (key) (hash-ref (instance-fields value) key)))]
          [(mapping? value)
           (write-object (reverse (mapping-reversed-keys value))
                         (lambda (key) (hash-ref (mapping-table value) key)))]
          [(list? value)
           (display "[" out)
           (for ([item (in-list value)] [i (in-naturals)])
             (unless (zero? i) (display "," out))
             (write-value item))
           (display "]" out)]
          [else (write-json (json-data value span) out #:null 'nil)]))
      (write-value value)
      (get-output-string out))

    ;; Expressions ----------------------------------------------------------

    (define (eval-expression expression)
      (cond
        [(typed-target? expression) (eval-expression (typed-target-expression expression))]
        [(method-call? expression) (eval-expression (method-call-resolved expression))]
        [(and (field-access? expression) (field-access-resolved expression))
         (eval-expression (field-access-resolved expression))]
        [else (eval-step-expression expression)]))

    (define (eval-step-expression expression)
      (step! (node-span expression))
      (cond
        [(type-expression? expression) (type-expression-name expression)]
        [(literal? expression) (literal-value expression)]
        [(name-ref? expression) (unbox (lookup (name-ref-name expression)))]
        [(unary? expression) (eval-unary expression)]
        [(binary? expression) (eval-binary expression)]
        [(call? expression) (eval-call expression)]
        [(enum-constructor? expression)
         (enum-value (enum-constructor-enum-name expression)
                     (enum-constructor-variant-name expression)
                     (map eval-expression (enum-constructor-args expression)))]
        [(function-ref? expression) (function-value (function-ref-name expression))]
        [(block-lit? expression) (closure-value expression (capture-scopes))]
        [(invoke? expression)
         (define target (eval-expression (invoke-target expression)))
         (define arguments (map eval-expression (invoke-args expression)))
         (apply-callable target arguments (invoke-span expression))]
        [(try-expr? expression)
         (define result (eval-expression (try-expr-operand expression)))
         (if (result-ok? result) (result-ok-value result) (return-to result))]
        [(construct? expression)
         (define parts (string-split (construct-type-name expression) "."))
         (if (and (= (length parts) 2) (hash-has-key? enum-names (car parts)))
             (enum-value (car parts) (cadr parts)
                         (map (lambda (argument)
                                (if (named-arg? argument)
                                    (eval-expression (named-arg-value argument))
                                    (eval-expression argument)))
                              (construct-args expression)))
             (instance (construct-type-name expression)
                       (for/fold ([fields (hash)])
                                 ([argument (in-list (construct-args expression))])
                         (hash-set fields (named-arg-name argument)
                                   (eval-expression (named-arg-value argument))))))]
        [(list-lit? expression)
         (for/list ([element (in-list (list-lit-elements expression))])
           (eval-expression element))]
        [(map-lit? expression)
         (for/fold ([result (mapping (hash) '())])
                   ([entry (in-list (map-lit-entries expression))])
           (mapping-put result
                        (eval-expression (map-entry-key entry))
                        (eval-expression (map-entry-value entry))))]
        [(interpolation? expression)
         (apply string-append
                (for/list ([part (in-list (interpolation-parts expression))])
                  (cond
                    [(string? part) part]
                    [else
                     (define value (eval-expression part))
                     (if (string? value) value (value->debug-string value))])))]
        [(field-access? expression)
         (hash-ref (instance-fields (eval-expression (field-access-target expression)))
                   (field-access-name expression))]
        [(index-access? expression)
         (define target (eval-expression (index-access-target expression)))
         (define index (eval-expression (index-access-index expression)))
         (cond
           [(mapping? target)
            (hash-ref (mapping-table target) index
                      (lambda ()
                        (bail 'RUNTIME-KEY-NOT-FOUND
                              (format "key ~s is not in the map" index)
                              (node-span (index-access-index expression)))))]
           [else
            (unless (< -1 index (length target))
              (bail 'RUNTIME-INDEX-OUT-OF-RANGE
                    (format "index ~a is outside a list of length ~a" index (length target))
                    (node-span (index-access-index expression))))
            (list-ref target index)])]
        [else (unreachable "expression" (node-span expression))]))

    (define (eval-unary expression)
      (define operand (eval-expression (unary-operand expression)))
      (case (unary-op expression)
        [(minus) (if (exact-integer? operand)
                     (in-int-range (- operand) (unary-op-span expression))
                     (- operand))]
        [(not) (not operand)]
        [else (unreachable "unary operator" (unary-op-span expression))]))

    (define (eval-binary expression)
      (define op (binary-op expression))
      (define span (binary-op-span expression))
      (define left (eval-expression (binary-left expression)))
      (case op
        [(and) (and left (eval-expression (binary-right expression)))]
        [(or) (or left (eval-expression (binary-right expression)))]
        [else
         (define right (eval-expression (binary-right expression)))
         (define ints? (exact-integer? left))
         (define (checked n) (if ints? (in-int-range n span) n))
         (define (non-zero!)
           (when (zero? right)
             (bail 'RUNTIME-DIVISION-BY-ZERO "division by zero" span)))
         (case op
           [(plus) (if (string? left) (string-append left right) (checked (+ left right)))]
           [(minus) (checked (- left right))]
           [(multiply) (checked (* left right))]
           [(divide)
            (non-zero!)
            (if ints? (checked (quotient left right)) (/ left right))]
           [(modulo) (non-zero!) (remainder left right)]
           [(less) (< left right)]
           [(less-equal) (<= left right)]
           [(greater) (> left right)]
           [(greater-equal) (>= left right)]
           [(equal) (if (number? left) (= left right) (equal? left right))]
           [(not-equal) (not (if (number? left) (= left right) (equal? left right)))]
           [else (unreachable "operator" span)])]))

    (define (value->debug-string value)
      (cond
        [(eq? value 'nil) "nil"]
        [(boolean? value) (if value "true" "false")]
        [(string? value) (format "~s" value)]
        [(number? value) (number->string value)]
        [(json-value? value) "<Json>"]
        [(or (function-value? value) (closure-value? value)) "<Fn>"]
        [(task-value? value) "<Task>"]
        [(net-socket? value) "<Socket>"]
        [(net-listener? value) "<Listener>"]
        [(http-client? value) "<HttpClient>"]
        [(http-server? value) "<HttpServer>"]
        [(http-body? value) "<HttpBody>"]
        [(http-writer? value) "<HttpWriter>"]
        [(file-handle? value) "<FileHandle>"]
        [(process-handle? value) "<Process>"]
        [(result-ok? value) (if (void? (result-ok-value value)) "ok()"
                               (format "ok(~a)" (value->debug-string (result-ok-value value))))]
        [(result-error? value) (format "error(~s)" (result-error-message value))]
        [(instance? value)
         (define field-order (hash-ref struct-fields (instance-type-name value) '()))
         (format "~a(~a)"
                 (instance-type-name value)
                 (string-join
                  (for/list ([field (in-list field-order)])
                    (format "~a: ~a" field
                            (value->debug-string
                             (hash-ref (instance-fields value) field))))
                  ", "))]
        [(mapping? value)
         (format "{~a}"
                 (string-join
                  (for/list ([key (in-list (reverse (mapping-reversed-keys value)))])
                    (format "~a: ~a"
                            (value->debug-string key)
                            (value->debug-string (hash-ref (mapping-table value) key))))
                  ", "))]
        [(list? value)
         (format "[~a]" (string-join (map value->debug-string value) ", "))]
        [else (format "~s" value)]))

    (define (eval-call expression)
      (define arguments
        (for/list ([argument (in-list (call-args expression))])
          (eval-expression argument)))
      (define entry (builtin-ref (call-name expression) (length arguments)))
      (define name (if entry (builtin-implementation entry) (call-name expression)))
      (define span (call-span expression))
      (define (invoke-network callback args)
        (evaluate-with-ports program program-args callback args
                             builtin-handler functions struct-fields enum-names run))
      (define (spawn-network thunk cust)
        (task-spawn run thunk span #:custodian cust))
      (define (request client method url headers text)
        (define data (string->bytes/utf-8 text))
        (http-client-request client method url headers data (bytes-length data) #f #f
                             invoke-network spawn-network))
      (cond
        [(string-prefix? name "Process.")
         (define result (process-call name arguments span))
         (if (diagnostic? result) (escape result) result)]
        [(string-prefix? name "File.") (filesystem-call name arguments)]
        [(string-prefix? name "Dir.") (filesystem-call name arguments)]
        [(string-prefix? name "Path.") (filesystem-call name arguments)]
        [(or (string-prefix? name "TCP.") (string-prefix? name "TLS.")) (network-call name arguments)]
        [(string-prefix? name "HTTP.")
         (match name
           ["HTTP.client_options" (default-client-options)]
           ["HTTP.server_options" (default-server-options)]
           ["HTTP.close_client" (close-http-client (car arguments))]
           ["HTTP.close_server" (close-http-server (car arguments))]
           ["HTTP.local_port" (http-server-port (car arguments))]
           [(or "HTTP.client" "HTTP.get" "HTTP.post" "HTTP.request" "HTTP.request_stream" "HTTP.listen" "HTTP.listen_tls" "HTTP.wait")
            (network-result
             (lambda ()
               (match name
                 ["HTTP.client" (make-http-client (if (null? arguments) (default-client-options) (car arguments)))]
                 ["HTTP.get" (request (car arguments) "GET" (cadr arguments) '() "")]
                 ["HTTP.post" (match-define (list client url headers text) arguments) (request client "POST" url headers text)]
                 ["HTTP.request" (apply request arguments)]
                 ["HTTP.request_stream"
                  (match-define (list client method url headers length callback arg) arguments)
                  (http-client-request client method url headers #f length callback arg invoke-network spawn-network)]
                 ["HTTP.listen" (match-define (list host port callback opts) arguments)
                                (make-http-server host port callback opts invoke-network spawn-network)]
                 ["HTTP.listen_tls" (match-define (list host port cert key callback opts) arguments)
                                    (make-http-server host port callback opts invoke-network spawn-network cert key)]
                 ["HTTP.wait" (wait-http-server (car arguments))])))]
           [else (http-call-wire name arguments)])]
        [else (case name
        [("Task.spawn")
         (define callback (car arguments))
         (task-spawn run
           (lambda ()
             (evaluate-with-ports program program-args callback (list (cadr arguments))
                                  builtin-handler functions struct-fields enum-names run)) span)]
        [("Task.await")
         (define value (task-await run (car arguments) span))
         (if (or (diagnostic? value) (exit-code? value)) (escape value) value)]
        [("Task.sleep")
         (define duration (car arguments))
         (when (negative? duration)
           (bail 'RUNTIME-INVALID-DURATION "sleep duration must be nonnegative"
                 (node-span (car (call-args expression)))))
         (sleep (/ duration 1000))
         (void)]
        [("BDD.run" "BDD.step" "BDD.doc_string" "BDD.table" "BDD.assert" "BDD.set" "BDD.get"
          "BDD.given_program" "BDD.when_line" "BDD.when_input" "BDD.when_eof" "BDD.then_line"
          "BDD.then_json_line" "BDD.then_stdin_open" "BDD.then_exit" "BDD.then_stdout" "BDD.then_stderr")
         (unless builtin-handler
           (bail 'RUNTIME-BDD-CONTEXT "BDD needs a runner context" span))
         (define value (builtin-handler name arguments span))
         (cond
           [(diagnostic? value) (escape value)]
           [(bdd-result? value)
            (if (bdd-result-ok? value)
                (result-ok (bdd-result-value value))
                (result-error (bdd-result-value value)))]
           [else value])]
        [("puts") (displayln (car arguments)) (void)]
        [("ok") (result-ok (if (null? arguments) (void) (car arguments)))]
        [("error") (result-error (car arguments))]
        [("Result.ok?") (result-ok? (car arguments))]
        [("Result.message")
         (if (result-error? (car arguments)) (result-error-message (car arguments)) "")]
        [("Result.unwrap!")
         (define result (car arguments))
         (if (result-ok? result)
             (result-ok-value result)
             (bail 'RUNTIME-UNWRAP-ERROR (result-error-message result) span))]
        [("Result.unwrap_or")
         (if (result-ok? (car arguments)) (result-ok-value (car arguments)) (cadr arguments))]
        [("IO.print") (display (car arguments)) (void)]
        [("IO.flush") (flush-output (current-output-port)) (void)]
        [("IO.warn") (displayln (car arguments) (current-error-port)) (void)]
        [("IO.inspect")
         (displayln (value->debug-string (car arguments)))
         (car arguments)]
        [("IO.gets" "IO.gets!")
         (fallible (string-suffix? name "!")
                   (lambda (fail)
                     (define line (read-line (current-input-port) 'any))
                     (when (eof-object? line)
                       (fail 'RUNTIME-END-OF-INPUT "IO.gets reached the end of input" span))
                     line))]
        [("IO.read") (port->string (current-input-port))]
        [("IO.read_bytes")
         (define count (car arguments))
         (if (<= 0 count max-read-bytes)
             (with-handlers ([exn:fail? (lambda (_) (result-error "input read failed"))])
               (define data (read-bytes count (current-input-port)))
               (result-ok (if (eof-object? data) '() (bytes->list data))))
             (result-error (format "byte count must be between 0 and ~a" max-read-bytes)))]
        [("IO.eof?") (eof-object? (peek-byte (current-input-port)))]
        [("System.args") program-args]
        [("System.exit") (escape (exit-code (car arguments)))]
        [("Map.has_key?") (hash-has-key? (mapping-table (car arguments)) (cadr arguments))]
        [("Map.keys") (reverse (mapping-reversed-keys (car arguments)))]
        [("Map.size") (hash-count (mapping-table (car arguments)))]
        [("Map.put") (mapping-put (car arguments) (cadr arguments) (caddr arguments))]
        [("Map.get")
         (define table (mapping-table (car arguments)))
         (define key (cadr arguments))
         (cond
           [(hash-has-key? table key)
            (if (= (length arguments) 2) (result-ok (hash-ref table key)) (hash-ref table key))]
           [(= (length arguments) 3) (caddr arguments)]
           [else (result-error (format "key ~s is not in the map" key))])]
        [("Map.delete")
         (define target (car arguments))
         (define key (cadr arguments))
         (mapping (hash-remove (mapping-table target) key)
                  (remove key (mapping-reversed-keys target)))]
        [("Map.values")
         (define target (car arguments))
         (for/list ([key (in-list (reverse (mapping-reversed-keys target)))])
           (hash-ref (mapping-table target) key))]
        [("JSON.parse")
         ;; Malformed exponents can raise non-read exceptions in Racket's reader.
         ;; Only parsing is recoverable; argument evaluation stays outside.
         (with-handlers ([exn:fail? (lambda (failure) (result-error (exn-message failure)))])
           (result-ok (read-json-value (car arguments))))]
        [("JSON.object" "JSON.array" "JSON.from")
         (json-value (json-data (car arguments) span))]
        [("JSON.null") (json-value 'nil)]
        [("JSON.null?") (eq? (json-value-data (car arguments)) 'nil)]
        [("JSON.schema") (json-schema (car arguments) (program-declarations program))]
        [("JSON.decode")
         (decode-json (car arguments) (cadr arguments) (program-declarations program))]
        [("JSON.encode") (encode-json (car arguments) span)]
        [("JSON.get")
         (define data (json-value-data (car arguments)))
         (define key (string->symbol (cadr arguments)))
         (cond
           [(not (hash? data)) (result-error "expected a JSON object")]
           [(not (hash-has-key? data key)) (result-error (format "missing JSON key ~s" (cadr arguments)))]
           [else (result-ok (json-value (hash-ref data key)))])]
        [("JSON.at")
         (define data (json-value-data (car arguments)))
         (define index (cadr arguments))
         (cond
           [(not (list? data)) (result-error "expected a JSON array")]
           [(not (< -1 index (length data))) (result-error "JSON array index is out of range")]
           [else (result-ok (json-value (list-ref data index)))])]
        [("JSON.string") (json-extract (car arguments) string? "a JSON string")]
        [("JSON.int")
         (json-extract (car arguments)
                       (lambda (data) (and (exact-integer? data) (<= int-min data int-max)))
                       "a signed 64-bit JSON integer")]
        [("JSON.float")
         (define data (json-value-data (car arguments)))
         (define value (and (real? data) (exact->inexact data)))
         (if (and value (rational? value))
             (result-ok value)
             (result-error "expected a JSON number representable as a finite Float"))]
        [("JSON.bool") (json-extract (car arguments) boolean? "a JSON boolean")]
        [("JSON.list")
         (json-extract (car arguments) list? "a JSON array"
                       (lambda (data) (map json-value data)))]
        [("List.size") (length (car arguments))]
        [("List.append") (append (car arguments) (list (cadr arguments)))]
        [("List.map" "List.filter" "List.reduce" "List.each" "List.any?" "List.all?")
         (define target (car arguments))
         (define callback (last arguments))
         (define (invoke-callback args)
           (apply-callable callback args span))
         (cond
           [(equal? name "List.each")
            (for ([item (in-list target)])
              (invoke-callback (list item)))
            (void)]
           [(equal? name "List.any?")
            (for/or ([item (in-list target)])
              (and (invoke-callback (list item)) #t))]
           [(equal? name "List.all?")
            (for/and ([item (in-list target)])
              (and (invoke-callback (list item)) #t))]
           [(equal? name "List.map")
            (for/list ([item (in-list target)])
              (invoke-callback (list item)))]
           [(equal? name "List.filter")
            (for/list ([item (in-list target)]
                       #:when (invoke-callback (list item)))
              item)]
           [else
            (for/fold ([accumulator (cadr arguments)]) ([item (in-list target)])
              (invoke-callback (list accumulator item)))])]
        [("List.concat") (append (car arguments) (cadr arguments))]
        [("List.take" "List.drop")
         (define target (car arguments))
         (define count (cadr arguments))
         (when (< count 0)
           (bail 'RUNTIME-INVALID-COUNT "count must be nonnegative"
                 (node-span (cadr (call-args expression)))))
         (define bounded (min count (length target)))
         ((if (equal? name "List.take") take drop) target bounded)]
        [("List.at")
         (define target (car arguments))
         (define index (cadr arguments))
         (unless (< -1 index (length target))
           (bail 'RUNTIME-INDEX-OUT-OF-RANGE "list index is out of range"
                 (node-span (cadr (call-args expression)))))
         (list-ref target index)]
        [("List.set")
         (define target (car arguments))
         (define index (cadr arguments))
         (unless (< -1 index (length target))
           (bail 'RUNTIME-INDEX-OUT-OF-RANGE "list index is out of range"
                 (node-span (cadr (call-args expression)))))
         (list-set target index (caddr arguments))]
        [("List.repeat")
         (define count (cadr arguments))
         (unless (<= 0 count (* 1024 1024))
           (bail 'RUNTIME-INVALID-COUNT "count must be between 0 and 1048576"
                 (node-span (cadr (call-args expression)))))
         (make-list count (car arguments))]
        [("List.reverse") (reverse (car arguments))]
        [("List.sort") (sort (car arguments) order<?)]
        [("List.sort_by")
         (define callback (cadr arguments))
         (define keyed
           (for/list ([item (in-list (car arguments))])
             (cons (apply-callable callback (list item) span) item)))
         (map cdr (sort keyed order<? #:key car))]
        [("String.length") (string-length (car arguments))]
        [("String.upcase") (string-upcase (car arguments))]
        [("String.downcase") (string-downcase (car arguments))]
        [("String.trim") (string-trim (car arguments))]
        [("String.split")
         (define text (car arguments))
         (define separator (cadr arguments))
         (if (string=? separator "")
             (map string (string->list text))
             (string-split text separator))]
        [("String.join") (string-join (car arguments) (cadr arguments))]
        [("String.contains?") (string-contains? (car arguments) (cadr arguments))]
        [("String.starts_with?") (string-prefix? (car arguments) (cadr arguments))]
        [("String.ends_with?") (string-suffix? (car arguments) (cadr arguments))]
        [("String.replace") (string-replace (car arguments) (cadr arguments) (caddr arguments))]
        [("String.slice")
         (define text (car arguments))
         (define start (cadr arguments))
         (define length (caddr arguments))
         (unless (and (>= start 0)
                      (>= length 0)
                      (<= (+ start length) (string-length text)))
           (bail 'RUNTIME-INDEX-OUT-OF-RANGE
                 (format "slice ~a,~a is outside a string of length ~a"
                         start length (string-length text))
                 (call-span expression)))
         (substring text start (+ start length))]
        [("String.index_of")
         (define found (regexp-match-positions (regexp-quote (cadr arguments)) (car arguments)))
         (if found
             (result-ok (caar found))
             (result-error (format "~s not found" (cadr arguments))))]
        [("String.at")
         (define text (car arguments))
         (define index (cadr arguments))
         (unless (< -1 index (string-length text))
           (bail 'RUNTIME-INDEX-OUT-OF-RANGE "string index is out of range"
                 (node-span (cadr (call-args expression)))))
         (string (string-ref text index))]
        [("String.reverse") (list->string (reverse (string->list (car arguments))))]
        [("String.code")
         (define text (car arguments))
         (unless (= (string-length text) 1)
           (bail 'RUNTIME-INVALID-CHARACTER "String.code needs exactly one character"
                 (node-span (car (call-args expression)))))
         (char->integer (string-ref text 0))]
        [("String.from_code")
         (define code (car arguments))
         (unless (or (<= 0 code #xD7FF) (<= #xE000 code #x10FFFF))
           (bail 'RUNTIME-INVALID-CHARACTER "not a Unicode scalar value"
                 (node-span (car (call-args expression)))))
         (string (integer->char code))]
        [("Time.now_ms") (exact-floor (current-inexact-milliseconds))]
        [("Time.monotonic_ms") (exact-floor (current-inexact-monotonic-milliseconds))]
        [("Random.int")
         (define low (car arguments))
         (define high (cadr arguments))
         (when (> low high)
           (bail 'RUNTIME-INVALID-RANGE "Random.int needs min <= max" span))
         (random-in-range low high)]
        [("Random.float") (random)]
        [("Float.from_int") (exact->inexact (car arguments))]
        [("Float.to_int" "Float.to_int!")
         (fallible (string-suffix? name "!")
                   (lambda (fail)
                     (define x (car arguments))
                     (unless (rational? x)
                       (fail 'RUNTIME-INVALID-NUMBER (format "cannot convert ~a to Int" x) span))
                     (in-int-range (inexact->exact (truncate x)) span fail)))]
        [("String.from_int") (number->string (car arguments))]
        [("String.from_float") (number->string (car arguments))]
        [("String.from_bytes")
         (define data (car arguments))
         (if (andmap byte? data)
             (with-handlers ([exn:fail:contract? (lambda (_) (result-error "invalid or incomplete UTF-8"))])
               (result-ok (bytes->string/utf-8 (list->bytes data) #f)))
             (result-error "bytes must be integers between 0 and 255"))]
        [("String.to_int" "String.to_int!")
         (fallible (string-suffix? name "!")
                   (lambda (fail)
                     (define text (car arguments))
                     (define parsed-int
                       (and (regexp-match? decimal-integer-pattern text) (string->number text)))
                     (unless (exact-integer? parsed-int)
                       (fail 'RUNTIME-INVALID-NUMBER (format "cannot convert ~s to Int" text) span))
                     (in-int-range parsed-int span fail)))]
        [("String.to_float" "String.to_float!")
         (fallible (string-suffix? name "!")
                   (lambda (fail)
                     (define text (car arguments))
                     (define parsed-float
                       (and (regexp-match? decimal-float-pattern text) (string->number text)))
                     (unless (real? parsed-float)
                       (fail 'RUNTIME-INVALID-NUMBER (format "cannot convert ~s to Float" text) span))
                     (exact->inexact parsed-float)))]
        [else
         (when entry (unreachable "builtin implementation" span))
         (define declaration (hash-ref functions name #f))
         (unless declaration (unreachable "call" (call-span expression)))
         (call-function declaration arguments (call-span expression))])]))

    (define (capture-scopes)
      (for*/fold ([captured (hash)])
                 ([frame (in-list (reverse scopes))]
                  [(name value) (in-hash frame)])
        (hash-set captured name (unbox value))))

    (define (apply-callable callable arguments span)
      (if (function-value? callable)
          (call-function (hash-ref functions (function-value-name callable)) arguments span)
          (call-closure callable arguments span)))

    (define (call-closure closure arguments span)
      (when (>= depth max-call-depth)
        (bail 'RUNTIME-STACK-OVERFLOW "call depth limit exceeded" span))
      (define block (closure-value-block closure))
      (define saved-scopes scopes)
      (define saved-return return-to)
      (set! depth (add1 depth))
      (define result
        (let/ec done
          (set! return-to done)
          (set! scopes (list (make-hash)
                             (for/hash ([(name value) (in-hash (closure-value-captured closure))])
                               (values name (box value)))))
          (for ([parameter (in-list (block-lit-params block))]
                [argument (in-list arguments)])
            (define! (block-param-name parameter) argument))
          (define statements (block-lit-body block))
          (cond
            [(and (pair? statements) (expr-stmt? (last statements)))
             (exec-block (drop-right statements 1))
             (define final (last statements))
             (step! (node-span final))
             (eval-expression (expr-stmt-value final))]
            [else
             (exec-block statements)
             (void)])))
      (set! depth (sub1 depth))
      (set! scopes saved-scopes)
      (set! return-to saved-return)
      result)

    (define (call-function declaration arguments span)
      (when (>= depth max-call-depth)
        (bail 'RUNTIME-STACK-OVERFLOW "call depth limit exceeded" span))
      (define saved-scopes scopes)
      (define saved-return return-to)
      (set! depth (add1 depth))
      (define result
        (let/ec done
          (set! return-to done)
          (set! scopes '())
          (push-scope!)
          (for ([parameter (in-list (function-decl-params declaration))]
                [argument (in-list arguments)])
            (define! (param-name parameter) argument))
          (exec-block (function-decl-body declaration))
          (void)))
      (set! depth (sub1 depth))
      (set! scopes saved-scopes)
      (set! return-to saved-return)
      result)

    ;; Statements -----------------------------------------------------------

    (define (exec-block statements)
      (for ([statement (in-list statements)])
        (exec-statement statement)))

    (define (exec-scoped statements)
      (push-scope!)
      (exec-block statements)
      (pop-scope!))

    (define (pattern-payload pattern value)
      (cond
        [(enum-value? value)
         (and (equal? (variant-pattern-enum-name pattern) (enum-value-type-name value))
              (equal? (variant-pattern-variant-name pattern) (enum-value-variant-name value))
              (enum-value-payload value))]
        [(and (equal? (variant-pattern-enum-name pattern) "Result") (result-ok? value)
              (equal? (variant-pattern-variant-name pattern) "Ok"))
         (list (result-ok-value value))]
        [(and (equal? (variant-pattern-enum-name pattern) "Result") (result-error? value)
              (equal? (variant-pattern-variant-name pattern) "Err"))
         (list (result-error-message value))]
        [else #f]))

    (define (pattern-matches? pattern value)
      (cond
        [(wildcard-pattern? pattern) #t]
        [(literal-pattern? pattern) (equal? (literal-pattern-value pattern) value)]
        [(variant-pattern? pattern) (and (pattern-payload pattern value) #t)]
        [else #f]))

    (define (exec-case statement)
      (define value (eval-expression (case-stmt-value statement)))
      (define arm
        (for/first ([candidate (in-list (case-stmt-arms statement))]
                    #:when (pattern-matches? (case-arm-pattern candidate) value))
          candidate))
      (unless arm (unreachable "case arm" (case-stmt-span statement)))
      (define pattern (case-arm-pattern arm))
      (define payload (and (variant-pattern? pattern) (pattern-payload pattern value)))
      (push-scope!)
      (when (variant-pattern? pattern)
        (for ([name (in-list (variant-pattern-bindings pattern))]
              [item (in-list payload)])
          (when name (define! name item))))
      (exec-block (case-arm-body arm))
      (pop-scope!))

    (define (exec-statement statement)
      (step! (node-span statement))
      (cond
        [(binding? statement)
         (define value (eval-expression (binding-value statement)))
         (if (and (not (binding-type statement)) (lookup (binding-name statement)))
             (assign! (binding-name statement) value)
             (define! (binding-name statement) value))]
        [(return-stmt? statement)
         (return-to (if (return-stmt-value statement)
                        (eval-expression (return-stmt-value statement))
                        (void)))]
        [(expr-stmt? statement) (eval-expression (expr-stmt-value statement))]
        [(case-stmt? statement) (exec-case statement)]
        [(if-stmt? statement)
         (define branch
           (for/first ([branch (in-list (if-stmt-branches statement))]
                       #:when (eval-expression (if-branch-condition branch)))
             branch))
         (cond
           [branch (exec-scoped (if-branch-body branch))]
           [(if-stmt-else-body statement) (exec-scoped (if-stmt-else-body statement))])]
        [(while-stmt? statement)
         (run-loop
          (lambda (iterate)
            (let loop ()
              (when (eval-expression (while-stmt-condition statement))
                (iterate (lambda () (exec-scoped (while-stmt-body statement))))
                (loop)))))]
        [(for-stmt? statement)
         (define elements (eval-expression (for-stmt-iterable statement)))
         (run-loop
          (lambda (iterate)
            (for ([element (in-list elements)])
              (iterate
               (lambda ()
                 (push-scope!)
                 (define! (for-stmt-var statement) element)
                 (exec-block (for-stmt-body statement))
                 (pop-scope!))))))]
        [(loop-control? statement)
         ((if (eq? (loop-control-kind statement) 'break) (loop-break) (loop-next)))]
        [else (unreachable "statement" (node-span statement))]))

    ;; Program --------------------------------------------------------------

    (if (string? entrypoint)
        (call-function (hash-ref functions entrypoint) entry-arguments (program-span program))
        (apply-callable entrypoint entry-arguments (program-span program))))))
