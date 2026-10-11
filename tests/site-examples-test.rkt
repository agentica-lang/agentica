#lang racket

(require (except-in rackunit check)
         racket/runtime-path
         "../src/checker.rkt"
         "../src/diagnostic.rkt"
         "../src/evaluator.rkt"
         "../src/lexer.rkt"
         "../src/modules.rkt"
         "../src/parser.rkt"
         "../src/source.rkt")

(define-runtime-path content-dir "../site/content")

(struct block (lang attributes text line) #:transparent)

(define fence-open #px"^```([A-Za-z0-9_-]+)[ \t]*(?:\\{([^}]*)\\})?[ \t]*$")
(define fence-close #px"^```[ \t]*$")
(define known-attributes '("mode" "file" "expect"))

(define (parse-attributes text)
  (for/hash ([match (in-list (regexp-match* #px"([a-z]+)=\"([^\"]*)\"" (or text "") #:match-select cdr))])
    (values (car match) (cadr match))))

(define (blocks-of path)
  (let loop ([lines (file->lines path)] [number 1] [found '()])
    (cond
      [(null? lines) (reverse found)]
      [(regexp-match fence-open (car lines))
       => (lambda (match)
            (define-values (body rest end)
              (let collect ([rest (cdr lines)] [end (add1 number)] [body '()])
                (cond
                  [(null? rest) (values (reverse body) rest end)]
                  [(regexp-match? fence-close (car rest)) (values (reverse body) (cdr rest) (add1 end))]
                  [else (collect (cdr rest) (add1 end) (cons (car rest) body))])))
            (loop rest end
                  (cons (block (cadr match) (parse-attributes (caddr match))
                               (string-append* (map (lambda (line) (string-append line "\n")) body))
                               number)
                        found)))]
      [(regexp-match? #px"^```" (car lines))
       (error 'site-examples "~a:~a: unsupported code fence" path number)]
      [else (loop (cdr lines) (add1 number) found)])))

(define (program? b) (member (block-lang b) '("agentica" "agc")))

(define (pipeline path text)
  (define lexed (lex (source (path->string path) text)))
  (define parsed (if (diagnostic? lexed) lexed (parse lexed)))
  (define linked (if (diagnostic? parsed) parsed (link-program parsed path)))
  (if (diagnostic? linked) linked (check linked)))

(define (run-program checked input)
  (define out (open-output-string))
  (define result
    (evaluate checked #:in (open-input-string input) #:out out #:err (open-output-string)
              #:max-steps 5000000 #:seed 1))
  (values result (get-output-string out)))

(define (diagnostic-text result)
  (if (diagnostic? result) (format-diagnostic result) (format "~a" result)))

(define (check-page path counts)
  (define blocks (blocks-of path))
  (define directory (make-temporary-directory))
  (dynamic-wind
   void
   (lambda ()
     (for ([b (in-list blocks)] #:when (and (program? b) (hash-ref (block-attributes b) "file" #f)))
       (call-with-output-file (build-path directory (hash-ref (block-attributes b) "file"))
         (lambda (out) (write-string (block-text b) out))))
     (let loop ([rest blocks] [previous #f])
       (unless (null? rest)
         (define b (car rest))
         (define where (format "~a:~a" path (block-line b)))
         (define attributes (block-attributes b))
         (cond
           [(member (block-lang b) '("input" "output"))
            (check-true (and previous #t) (format "~a: ~a block without a program before it" where (block-lang b)))
            (loop (cdr rest) (and (equal? (block-lang b) "input") previous))]
           [(and (program? b) (hash-ref attributes "file" #f))
            (hash-update! counts 'module add1 0)
            (loop (cdr rest) #f)]
           [(program? b)
            (for ([key (in-hash-keys attributes)])
              (check-not-false (member key known-attributes) (format "~a: unknown attribute ~a" where key)))
            (define mode (hash-ref attributes "mode" "run"))
            (check-not-false (member mode '("run" "check")) (format "~a: unknown mode ~a" where mode))
            (define expect (hash-ref attributes "expect" #f))
            (define following
              (let take ([after (cdr rest)] [found (hash)])
                (cond
                  [(null? after) found]
                  [(equal? (block-lang (car after)) "sh") (take (cdr after) found)]
                  [(and (equal? (block-lang (car after)) "input") (not (hash-has-key? found "input"))
                        (not (hash-has-key? found "output")))
                   (take (cdr after) (hash-set found "input" (block-text (car after))))]
                  [(and (equal? (block-lang (car after)) "output") (not (hash-has-key? found "output")))
                   (hash-set found "output" (block-text (car after)))]
                  [else found])))
            (define file (build-path directory "main.agc"))
            (define checked (pipeline file (block-text b)))
            (cond
              [(and (diagnostic? checked) expect)
               (check-equal? (diagnostic-code checked) (string->symbol expect) where)
               (hash-update! counts 'rejected add1 0)]
              [(diagnostic? checked)
               (fail (format "~a: ~a" where (diagnostic-text checked)))]
              [(equal? mode "check")
               (check-false expect (format "~a: expected ~a, but the program checks" where expect))
               (check-false (hash-ref following "output" #f) (format "~a: a check-only block has an output block" where))
               (hash-update! counts 'check add1 0)]
              [else
               (define-values (result output) (run-program checked (hash-ref following "input" "")))
               (cond
                 [expect
                  (check-true (and (diagnostic? result) (eq? (diagnostic-code result) (string->symbol expect)))
                              (format "~a: expected ~a, got ~a" where expect (diagnostic-text result)))]
                 [else
                  (check-false (diagnostic? result) (format "~a: ~a" where (diagnostic-text result)))])
               (check-true (or (and expect #t) (hash-has-key? following "output"))
                           (format "~a: a run block needs an output block" where))
               (when (or (not expect) (hash-has-key? following "output"))
                 (check-equal? output (hash-ref following "output" "") where))
               (hash-update! counts 'run add1 0)])
            (loop (cdr rest) b)]
           [(equal? (block-lang b) "sh") (loop (cdr rest) previous)]
           [else (loop (cdr rest) #f)]))))
   (lambda () (delete-directory/files directory))))

(module+ test
  (define pages
    (sort (for/list ([path (in-directory (simplify-path content-dir))]
                     #:when (regexp-match? #px"\\.md$" (path->string path)))
            path)
          string<? #:key path->string))
  (define counts (make-hasheq))
  (for ([page (in-list pages)])
    (test-case (path->string page)
      (check-page page counts)))
  (check-true (> (hash-ref counts 'run 0) 100) "the site should have many run examples")
  (printf "site examples: ~a run, ~a checked only, ~a rejected by the checker, ~a module files\n"
          (hash-ref counts 'run 0) (hash-ref counts 'check 0) (hash-ref counts 'rejected 0)
          (hash-ref counts 'module 0)))
