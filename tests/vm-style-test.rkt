#lang racket

(require rackunit
         racket/runtime-path)

(define-runtime-path vm-dir "../vm")

(define skipped '("unicode_data.c"))

(define (vm-files)
  (define (in dir prefix)
    (for/list ([p (directory-list (build-path vm-dir dir))]
               #:when (regexp-match? #rx"[.]c$" (path->string p)))
      (string-append prefix (path->string p))))
  (sort (filter (lambda (f) (not (member f skipped)))
                (append (in "." "") (in "tests" "tests/")))
        string<?))

(define (header-files)
  (define (in dir prefix ext)
    (for/list ([p (directory-list (build-path vm-dir dir))]
               #:when (regexp-match? ext (path->string p)))
      (string-append prefix (path->string p))))
  (sort (filter (lambda (f) (not (member f skipped)))
                (append (in "." "" #rx"[.][ch]$") (in "tests" "tests/" #rx"[.]c$")))
        string<?))

(define (header-problems file text)
  (define test? (regexp-match? #rx"^tests/" file))
  (define-values (low high) (if test? (values 1 4) (values 3 8)))
  (define (legal? comment) (regexp-match? #px"(?i:copyright|licen[sc]e|spdx)" comment))
  (let loop ([rest text])
    (define m (regexp-match #px"^\\s*/\\*(.*?)\\*/(.*)$" rest))
    (cond
      [(not m)
       (list (format "vm/~a: no header comment: the file must start with a /* */ comment of ~a to ~a lines"
                     file low high))]
      [(legal? (cadr m)) (loop (caddr m))]
      [else
       (define lines (regexp-split #rx"\n" (cadr m)))
       (define (blank? l) (regexp-match? #px"^[\\s*]*$" l))
       (define body
         (let* ([l lines]
                [l (if (and (pair? l) (blank? (car l))) (cdr l) l)]
                [l (if (and (pair? l) (blank? (last l))) (drop-right l 1) l)])
           l))
       (if (<= low (length body) high)
           '()
           (list (format "vm/~a: header comment has ~a lines of text, want ~a to ~a (references/vm-c.md)"
                         file (length body) low high)))])))

(define (top-level-headers text)
  (define n (string-length text))
  (define headers '())
  (define (char-at i) (if (< i n) (string-ref text i) #\nul))
  (let loop ([i 0] [line 1] [depth 0] [header ""] [start #f] [line-start? #t])
    (define c (char-at i))
    (define (next j line* header* start*)
      (loop j line* depth header* start* #f))
    (cond
      [(>= i n) (reverse headers)]
      [(char=? c #\newline) (loop (add1 i) (add1 line) depth (if (zero? depth) (string-append header " ") header) start #t)]
      [(and line-start? (char=? c #\#))
       (let skip ([j i] [line line])
         (cond
           [(>= j n) (loop j line depth header start #t)]
           [(and (char=? (char-at j) #\\) (char=? (char-at (add1 j)) #\newline))
            (skip (+ j 2) (add1 line))]
           [(and (char=? (char-at j) #\/) (char=? (char-at (add1 j)) #\*))
            (let comment ([k (+ j 2)] [line line])
              (cond
                [(>= k n) (skip k line)]
                [(and (char=? (char-at k) #\*) (char=? (char-at (add1 k)) #\/)) (skip (+ k 2) line)]
                [else (comment (add1 k) (if (char=? (char-at k) #\newline) (add1 line) line))]))]
           [(char=? (char-at j) #\newline) (loop (add1 j) (add1 line) depth header start #t)]
           [else (skip (add1 j) line)]))]
      [(and (char=? c #\/) (char=? (char-at (add1 i)) #\/))
       (let skip ([j i]) (if (or (>= j n) (char=? (char-at j) #\newline)) (next j line header start) (skip (add1 j))))]
      [(and (char=? c #\/) (char=? (char-at (add1 i)) #\*))
       (let skip ([j (+ i 2)] [line line])
         (cond
           [(>= j n) (next j line header start)]
           [(and (char=? (char-at j) #\*) (char=? (char-at (add1 j)) #\/)) (next (+ j 2) line header start)]
           [else (skip (add1 j) (if (char=? (char-at j) #\newline) (add1 line) line))]))]
      [(or (char=? c #\") (char=? c #\'))
       (let skip ([j (add1 i)])
         (cond
           [(>= j n) (next j line header start)]
           [(char=? (char-at j) #\\) (skip (+ j 2))]
           [(char=? (char-at j) c) (next (add1 j) line (if (zero? depth) (string-append header "\"\"") header) start)]
           [else (skip (add1 j))]))]
      [(char-whitespace? c) (loop (add1 i) line depth (if (zero? depth) (string-append header " ") header) start line-start?)]
      [(zero? depth)
       (case c
         [(#\;)
          (when (regexp-match? #px"^\\s*(typedef\\b|((_Noreturn|inline)\\s+)*static\\b)" header)
            (set! headers (cons (cons (or start line) (string-append (string-normalize-spaces header) ";"))
                                headers)))
          (next (add1 i) line "" #f)]
         [(#\{)
          (set! headers (cons (cons (or start line) (string-normalize-spaces header)) headers))
          (loop (add1 i) line 1 "" #f #f)]
         [else (next (add1 i) line (string-append header (string c)) (or start line))])]
      [(char=? c #\{) (loop (add1 i) line (add1 depth) header start #f)]
      [(char=? c #\}) (loop (add1 i) line (sub1 depth) "" #f #f)]
      [else (next (add1 i) line header start)])))

(define (header-kind h)
  (cond
    [(regexp-match? #px";$" h)
     (cond
       [(regexp-match? #px"^typedef\\b" h) 'type]
       [(regexp-match? #px"=|^[^(]*\\(\\s*\\*" h) 'data]
       [(regexp-match? #px"\\(" h) 'prototype]
       [else 'data])]
    [(regexp-match? #px"^typedef\\b" h) 'type]
    [(regexp-match? #px"=" h) 'data]
    [(regexp-match? #px"\\(" h) 'function]
    [(regexp-match? #px"^((static|const|extern)\\s+)*(struct|union|enum)\\b" h) 'type]
    [else 'other]))

(define (style-problems file)
  (text-problems file (file->string (build-path vm-dir file))))

(define (text-problems file text)
  (define headers (top-level-headers text))
  (define first-function
    (for/first ([h headers] #:when (eq? (header-kind (cdr h)) 'function)) (car h)))
  (for/list ([h headers]
             #:when (or (eq? (header-kind (cdr h)) 'prototype)
                        (and first-function
                             (> (car h) first-function)
                             (eq? (header-kind (cdr h)) 'type))))
    (if (eq? (header-kind (cdr h)) 'prototype)
        (format "vm/~a:~a: prototype of a static function (define it before its first use): ~a"
                file (car h) (cdr h))
        (format "vm/~a:~a: type definition after the first function (line ~a): ~a"
                file (car h) first-function (cdr h)))))

(test-case "scanner finds functions and late type definitions"
  (define headers
    (top-level-headers
     (string-append "#define M(x) /* {\n  } */ \\\n  { x }\n"
                    "static int helper(int a);\n"
                    "static void (*hook)(int);\n"
                    "static int count, table[2];\n"
                    "typedef struct { int a; } t;\n"
                    "static const char *s = \"{\";\n"
                    "struct p *f(struct p *q);\n"
                    "static int g(void) {\n  struct p *x = 0;\n  return '}';\n}\n"
                    "static const int k[] = {1};\n"
                    "static struct p *h(void) { return 0; }\n"
                    "struct late {\n  int b;\n};\n"
                    "typedef struct late late_t;\n")))
  (check-equal? (map car headers) '(4 5 6 7 8 10 14 15 16 19))
  (check-equal? (map (compose header-kind cdr) headers)
                '(prototype data data type data function data function type type)))

(test-case "late types and static prototypes are reported with their lines"
  (check-equal?
   (map (lambda (m) (cadr (regexp-match #px"^vm/x[.]c:(\\d+):" m)))
        (text-problems "x.c"
                       (string-append "_Noreturn static void stop(void);\n"
                                      "int f(void) {\n  return 0;\n}\n"
                                      "struct x {\n  int a;\n};\n"
                                      "inline static int g(void);\n"
                                      "static int f2(void);\n")))
   '("1" "5" "8" "9")))

(test-case "no late type definition or static prototype in vm/*.c"
  (define files (vm-files))
  (check-not-false (member "interp.c" files))
  (define problems (append-map style-problems files))
  (check-true (null? problems) (string-join problems "\n")))

(test-case "header comment bounds"
  (define (lines n) (string-join (for/list ([i n]) (format " * line ~a" i)) "\n"))
  (define (file n) (string-append "/*\n" (lines n) "\n */\nint x;\n"))
  (check-equal? (header-problems "a.c" (file 3)) '())
  (check-equal? (header-problems "a.c" (file 8)) '())
  (check-equal? (length (header-problems "a.c" (file 2))) 1)
  (check-equal? (length (header-problems "a.c" (file 9))) 1)
  (check-equal? (header-problems "tests/a_test.c" (file 1)) '())
  (check-equal? (header-problems "tests/a_test.c" (file 4)) '())
  (check-equal? (length (header-problems "tests/a_test.c" (file 5))) 1)
  (check-equal? (header-problems "a.c" (string-append "/* Copyright 2026 */\n" (file 3))) '())
  (check-regexp-match #rx"^vm/a[.]c: no header comment" (car (header-problems "a.c" "int x;\n/* late */\n")))
  (check-regexp-match #rx"^vm/a[.]c: no header" (car (header-problems "a.c" "// line\nint x;\n"))))

(test-case "every vm C file starts with a header comment of the right length"
  (define files (header-files))
  (check-not-false (member "interp.c" files))
  (check-not-false (member "port.h" files))
  (check-not-false (member "tests/map_test.c" files))
  (define problems
    (append-map (lambda (f) (header-problems f (file->string (build-path vm-dir f)))) files))
  (check-true (null? problems) (string-join problems "\n")))
