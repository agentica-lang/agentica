#lang racket

(require "diagnostic.rkt" "lower.rkt" "source.rkt" "version.rkt")

(provide ir->bytecode
         write-bytecode
         read-bytecode
         format-version
         opcodes
         (struct-out bc-program)
         (struct-out bc-function))

(struct bc-program (sources spans constants builtins functions entry) #:transparent)
(struct bc-function (name params captures registers span code spans) #:transparent)

(define format-version 1)
(define max-u16 65535)

(define opcodes
  '(move const step add-i sub-i mul-i div-i mod-i neg-i not lt-i le-i eq ne
    jump jump-if-false jump-if-true call call-builtin return))

(define opcode-number
  (for/hasheq ([op (in-list opcodes)] [index (in-naturals)]) (values op index)))

(define (ir->bytecode ir)
  (let/ec return
    (define (too-big what span)
      (return (diagnostic 'BYTECODE-LIMIT (format "the program has too many ~a for the VM" what) span)))
    (define sources (ir-program-sources ir))
    (define source-index
      (for/hasheq ([text-source (in-list sources)] [index (in-naturals)])
        (values text-source index)))
    (define spans '())
    (define span-count 0)
    (define runs (make-hash))
    (define (span-key span)
      (define start (source-span-start span))
      (define end (source-span-end span))
      (vector (hash-ref source-index (source-span-source span))
              (source-position-line start) (source-position-column start)
              (source-position-line end) (source-position-column end)))
    (define (intern-spans! list-of-spans)
      (define keys (map span-key list-of-spans))
      (hash-ref! runs keys
                 (lambda ()
                   (define index span-count)
                   (set! spans (append (reverse keys) spans))
                   (set! span-count (+ span-count (length keys)))
                   index)))
    (intern-spans! (list (ir-program-span ir)))
    (define constants '())
    (define constant-count 0)
    (define constant-index (make-hash))
    (define (constant! value)
      (define key (cond [(void? value) '(void)] [(boolean? value) (list 'bool value)]
                        [(string? value) (list 'string value)] [else (list 'int value)]))
      (hash-ref! constant-index key
                 (lambda ()
                   (set! constants (cons value constants))
                   (set! constant-count (add1 constant-count))
                   (sub1 constant-count))))
    (define builtins '())
    (define builtin-index (make-hash))
    (define (builtin! name arity)
      (hash-ref! builtin-index (cons name arity)
                 (lambda ()
                   (set! builtins (append builtins (list (cons name arity))))
                   (sub1 (length builtins)))))
    (define (merge-steps body)
      (let loop ([items body] [out '()])
        (cond
          [(null? items) (reverse out)]
          [(and (ir-instr? (car items)) (eq? (ir-instr-op (car items)) 'step))
           (define-values (run rest)
             (splitf-at items (lambda (item) (and (ir-instr? item) (eq? (ir-instr-op item) 'step)))))
           (define chunks
             (let split ([run run])
               (if (> (length run) max-u16)
                   (cons (take run max-u16) (split (drop run max-u16)))
                   (list run))))
           (loop rest
                 (append (reverse
                          (for/list ([chunk (in-list chunks)])
                            (ir-instr 'step (list (length chunk)) (append-map ir-instr-spans chunk))))
                         out))]
          [else (loop (cdr items) (cons (car items) out))])))
    (define (encode-function function)
      (define slots (ir-function-slots function))
      (when (> slots max-u16) (too-big "registers in one function" (ir-function-span function)))
      (define body (merge-steps (ir-function-body function)))
      (define labels (make-hasheqv))
      (for/fold ([pc 0]) ([item (in-list body)])
        (cond
          [(ir-label? item) (hash-set! labels (ir-label-id item) pc) pc]
          [else (add1 pc)]))
      (define instrs (filter ir-instr? body))
      (define code
        (for/vector ([instr (in-list instrs)])
          (define op (ir-instr-op instr))
          (define args (ir-instr-args instr))
          (define (wide a x) (list a (bitwise-and x max-u16) (arithmetic-shift x -16)))
          (cons (hash-ref opcode-number op)
                (case op
                  [(move neg-i not) (list (first args) (second args) 0)]
                  [(const) (wide (first args) (constant! (second args)))]
                  [(step) (list (first args) 0 0)]
                  [(jump) (wide 0 (hash-ref labels (first args)))]
                  [(jump-if-false jump-if-true) (wide (first args) (hash-ref labels (second args)))]
                  [(call) (wide (first args) (second args))]
                  [(call-builtin) (wide (first args) (builtin! (second args) (third args)))]
                  [(return) (list (first args) 0 0)]
                  [else args]))))
      (define instr-spans
        (for/vector ([instr (in-list instrs)]) (intern-spans! (ir-instr-spans instr))))
      (bc-function (ir-function-name function) (ir-function-params function)
                   (ir-function-captures function) slots
                   (intern-spans! (list (ir-function-span function))) code instr-spans))
    (define functions (map encode-function (ir-program-functions ir)))
    (bc-program (for/list ([text-source (in-list sources)])
                  (cons (source-name text-source) (source-text text-source)))
                (list->vector (reverse spans))
                (list->vector (reverse constants))
                builtins
                functions
                (ir-program-entry ir))))

(define (u8 out n) (write-byte n out))
(define (u16 out n) (write-bytes (integer->integer-bytes n 2 #f #f) out))
(define (u32 out n) (write-bytes (integer->integer-bytes n 4 #f #f) out))
(define (str out text)
  (define data (string->bytes/utf-8 text))
  (u32 out (bytes-length data))
  (write-bytes data out))

(define (write-bytecode program)
  (define out (open-output-bytes))
  (write-bytes #"AGCB" out)
  (u32 out format-version)
  (str out version)
  (u32 out (length (bc-program-sources program)))
  (for ([entry (in-list (bc-program-sources program))])
    (str out (car entry))
    (str out (cdr entry)))
  (u32 out (vector-length (bc-program-spans program)))
  (for ([span (in-vector (bc-program-spans program))])
    (for ([n (in-vector span)]) (u32 out n)))
  (u32 out (vector-length (bc-program-constants program)))
  (for ([value (in-vector (bc-program-constants program))])
    (cond
      [(void? value) (u8 out 0)]
      [(eq? value #f) (u8 out 2)]
      [(eq? value #t) (u8 out 3)]
      [(exact-integer? value) (u8 out 4) (write-bytes (integer->integer-bytes value 8 #t #f) out)]
      [(string? value) (u8 out 6) (str out value)]))
  (u32 out 0)
  (u32 out 0)
  (u32 out 0)
  (u32 out (length (bc-program-builtins program)))
  (for ([entry (in-list (bc-program-builtins program))])
    (str out (car entry))
    (u32 out (cdr entry)))
  (u32 out (length (bc-program-functions program)))
  (for ([function (in-list (bc-program-functions program))])
    (str out (bc-function-name function))
    (u32 out (bc-function-params function))
    (u32 out (bc-function-captures function))
    (u32 out (bc-function-registers function))
    (u32 out (bc-function-span function))
    (u32 out (vector-length (bc-function-code function)))
    (for ([instr (in-vector (bc-function-code function))])
      (for ([n (in-list instr)]) (u16 out n)))
    (for ([span (in-vector (bc-function-spans function))]) (u32 out span)))
  (u32 out (bc-program-entry program))
  (get-output-bytes out))

(define (read-bytecode data)
  (let/ec escape
    (define in (open-input-bytes data))
    (define (bad) (escape #f))
    (define (take-bytes n)
      (define chunk (read-bytes n in))
      (if (and (bytes? chunk) (= (bytes-length chunk) n)) chunk (bad)))
    (define (r8) (bytes-ref (take-bytes 1) 0))
    (define (r16) (integer-bytes->integer (take-bytes 2) #f #f))
    (define (r32) (integer-bytes->integer (take-bytes 4) #f #f))
    (define (rstr)
      (define chunk (take-bytes (r32)))
      (with-handlers ([exn:fail? (lambda (_) (bad))])
        (bytes->string/utf-8 chunk)))
    (unless (equal? (take-bytes 4) #"AGCB") (bad))
    (unless (= (r32) format-version) (bad))
    (unless (equal? (rstr) version) (bad))
    (define sources (for/list ([_ (in-range (r32))]) (let ([name (rstr)]) (cons name (rstr)))))
    (define spans (for/vector ([_ (in-range (r32))]) (for/vector ([_ (in-range 5)]) (r32))))
    (define constants
      (for/vector ([_ (in-range (r32))])
        (case (r8)
          [(0) (void)]
          [(2) #f]
          [(3) #t]
          [(4) (integer-bytes->integer (take-bytes 8) #t #f)]
          [(6) (rstr)]
          [else (bad)])))
    (for ([_ (in-range 3)]) (unless (zero? (r32)) (bad)))
    (define builtins (for/list ([_ (in-range (r32))]) (let ([name (rstr)]) (cons name (r32)))))
    (define functions
      (for/list ([_ (in-range (r32))])
        (define name (rstr))
        (define params (r32))
        (define captures (r32))
        (define registers (r32))
        (define span (r32))
        (define count (r32))
        (define code (for/vector ([_ (in-range count)]) (for/list ([_ (in-range 4)]) (r16))))
        (define instr-spans (for/vector ([_ (in-range count)]) (r32)))
        (bc-function name params captures registers span code instr-spans)))
    (define entry (r32))
    (unless (eof-object? (read-byte in)) (bad))
    (bc-program sources spans constants builtins functions entry)))
