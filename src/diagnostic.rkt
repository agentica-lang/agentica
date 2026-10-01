#lang racket

(require "source.rkt")

(provide diagnostic
         diagnostic?
         diagnostic-code
         diagnostic-message
         diagnostic-span
         diagnostic-expected
         diagnostic-actual
         diagnostic-callee
         diagnostic-argument
         diagnostic-signature
         diagnostic-labels
         diagnostic-help
         format-diagnostic
         format-diagnostic-ai
         diagnostic->jsexpr)

(struct diagnostic (code message span expected actual callee argument signature labels help)
  #:transparent
  #:constructor-name make-diagnostic
  #:omit-define-syntaxes)

(define (diagnostic code message span
                    #:expected [expected #f]
                    #:actual [actual #f]
                    #:callee [callee #f]
                    #:argument [argument #f]
                    #:signature [signature #f]
                    #:labels [labels '()]
                    #:help [help #f])
  (make-diagnostic code message span expected actual callee argument signature labels help))

(define (source-line text line)
  (define lines (string-split text "\n" #:trim? #f))
  (if (<= 1 line (length lines))
      (string-trim (list-ref lines (sub1 line)) "\r" #:left? #f)
      ""))

(define (padding text count)
  (list->string
   (for/list ([index (in-range count)])
     (if (and (< index (string-length text)) (char=? (string-ref text index) #\tab)) #\tab #\space))))

(define (mark span character label text-of)
  (define start (source-span-start span))
  (define end (source-span-end span))
  (define line (source-position-line start))
  (define column (source-position-column start))
  (define text (text-of line))
  (define room (max 1 (- (string-length text) (sub1 column))))
  (define wanted
    (if (= (source-position-line end) line)
        (- (source-position-column end) column)
        room))
  (list line column (max 1 (min wanted room)) character label))

(define (render-line line marks text-of gutter-width)
  (define text (text-of line))
  (define gutter (make-string gutter-width #\space))
  (define sorted (sort marks < #:key cadr))
  (define width (apply max (map (lambda (m) (+ (sub1 (cadr m)) (caddr m))) sorted)))
  (define row (list->vector (string->list (padding text width))))
  (for ([m (in-list sorted)])
    (for ([offset (in-range (caddr m))])
      (vector-set! row (+ (sub1 (cadr m)) offset) (cadddr m))))
  (define notes
    (for/list ([m (in-list (reverse sorted))] #:when (list-ref m 4))
      (format "~a | ~a~a" gutter (padding text (sub1 (cadr m))) (list-ref m 4))))
  (string-join
   (append (list (format "~a | ~a" (~a line #:min-width gutter-width #:align 'left) text)
                 (format "~a | ~a" gutter (list->string (vector->list row))))
           notes)
   "\n"))

(define (format-diagnostic problem)
  (define span (diagnostic-span problem))
  (define start (source-span-start span))
  (define text-source (source-text (source-span-source span)))
  (define (text-of line) (source-line text-source line))
  (define marks
    (cons (mark span #\^ #f text-of)
          (for/list ([label (in-list (diagnostic-labels problem))])
            (mark (car label) #\- (cdr label) text-of))))
  (define lines (sort (remove-duplicates (map car marks)) <))
  (define gutter-width (string-length (number->string (apply max lines))))
  (define body
    (string-join
     (for/list ([line (in-list lines)])
       (render-line line (filter (lambda (m) (= (car m) line)) marks) text-of gutter-width))
     "\n"))
  (define help
    (if (diagnostic-help problem)
        (format "\n~a = help: ~a" (make-string gutter-width #\space) (diagnostic-help problem))
        ""))
  (format "~a:~a:~a error[~a]\n~a\n\n~a~a"
          (source-name (source-span-source span))
          (source-position-line start)
          (source-position-column start)
          (diagnostic-code problem)
          (diagnostic-message problem)
          body
          help))

(define (span-start-line span) (source-position-line (source-span-start span)))

(define (format-diagnostic-ai problem)
  (define span (diagnostic-span problem))
  (define start (source-span-start span))
  (define line (source-line (source-text (source-span-source span)) (source-position-line start)))
  (define (field name value) (if value (list (format "  ~a: ~a" name value)) '()))
  (string-join
   (append (list "check failed: 1 error" "" (format "[~a]" (diagnostic-code problem))
                 (format "  message: ~a" (diagnostic-message problem))
                 (format "  at: ~a:~a:~a" (source-name (source-span-source span))
                         (source-position-line start) (source-position-column start)))
           (field "in" (diagnostic-signature problem))
           (list (format "  source: ~a" (string-trim line)))
           (field "callee" (diagnostic-callee problem))
           (field "expected" (diagnostic-expected problem))
           (field "actual" (diagnostic-actual problem))
           (for/list ([label (in-list (diagnostic-labels problem))])
             (format "  label: ~a:~a ~a"
                     (span-start-line (car label))
                     (source-position-column (source-span-start (car label)))
                     (cdr label)))
           (field "help" (diagnostic-help problem)))
   "\n"))

(define (diagnostic->jsexpr problem)
  (define span (diagnostic-span problem))
  (define (position p) (hasheq 'line (source-position-line p) 'column (source-position-column p)))
  (define (optional key value) (if value (list (cons key value)) '()))
  (make-immutable-hasheq
   (append
    (list (cons 'code (symbol->string (diagnostic-code problem)))
          (cons 'message (diagnostic-message problem))
          (cons 'file (source-name (source-span-source span)))
          (cons 'range (hasheq 'start (position (source-span-start span))
                               'end (position (source-span-end span)))))
    (optional 'expected (diagnostic-expected problem))
    (optional 'actual (diagnostic-actual problem))
    (optional 'callee (diagnostic-callee problem))
    (optional 'argument (diagnostic-argument problem))
    (optional 'function (diagnostic-signature problem))
    (optional 'help (diagnostic-help problem))
    (if (null? (diagnostic-labels problem))
        '()
        (list (cons 'labels
                    (for/list ([label (in-list (diagnostic-labels problem))])
                      (hasheq 'range (hasheq 'start (position (source-span-start (car label)))
                                             'end (position (source-span-end (car label))))
                              'text (cdr label)))))))))
