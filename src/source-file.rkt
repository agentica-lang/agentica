#lang racket

;; Reading a source file: strict UTF-8, no size limit. file->string would replace
;; invalid bytes with U+FFFD, so the front end would lex text the file does not
;; hold. compiler/source_file.agc does the same on the Agentica side.

(require "diagnostic.rkt"
         "source.rkt")

(provide read-source-file
         first-invalid-utf8)

;; The text of the file at `path`, or a LEX-INVALID-UTF8 diagnostic located in the file `name`.
;; A file system error is raised, as file->string did; each caller turns it into its own code.
(define (read-source-file path name)
  (define data (file->bytes path))
  (define text (with-handlers ([exn:fail:contract? (lambda (_) #f)]) (bytes->string/utf-8 data)))
  (or text
      ;; Racket's decoder and first-invalid-utf8 agree on what is valid; 0 only keeps a
      ;; disagreement from becoming an exception.
      (invalid-utf8 name data (or (first-invalid-utf8 data) (source-position 0 1 1)))))

;; The position (characters decoded before it, line, column) of the first byte of the first
;; sequence that does not decode, or #f when all of `data` is valid. The rules are those of
;; agc_utf8_valid in vm/value.c, which String.from_bytes uses: no overlong forms, no surrogates,
;; nothing above U+10FFFF, no truncated sequence at the end.
(define (first-invalid-utf8 data)
  (define size (bytes-length data))
  (let loop ([at 0] [chars 0] [line 1] [line-start 0])
    (cond
      [(>= at size) #f]
      [else
       (define width (sequence-width data at))
       (cond
         [(zero? width) (source-position chars line (add1 (- chars line-start)))]
         [(= (bytes-ref data at) 10) (loop (add1 at) (add1 chars) (add1 line) (add1 chars))]
         [else (loop (+ at width) (add1 chars) line line-start)])])))

;; The length of the valid sequence that starts at `at`, or 0.
(define (sequence-width data at)
  (define lead (bytes-ref data at))
  (define extra
    (cond
      [(< lead #x80) 0]
      [(<= #xC2 lead #xDF) 1]
      [(<= #xE0 lead #xEF) 2]
      [(<= #xF0 lead #xF4) 3]
      [else #f]))
  (cond
    [(not extra) 0]
    [(zero? extra) 1]
    [(>= (+ at extra) (bytes-length data)) 0]
    [else
     (define code
       (for/fold ([code (bitwise-and lead (case extra [(1) #x1F] [(2) #x0F] [else #x07]))])
                 ([next (in-bytes data (add1 at) (+ at extra 1))])
         (and code
              (= (bitwise-and next #xC0) #x80)
              (bitwise-ior (arithmetic-shift code 6) (bitwise-and next #x3F)))))
     (if (and code
              (>= code (case extra [(1) #x80] [(2) #x800] [else #x10000]))
              (<= code #x10FFFF)
              (not (<= #xD800 code #xDFFF)))
         (add1 extra)
         0)]))

;; The span is the first bad byte, one long. The text keeps the bad bytes as U+FFFD so that
;; the diagnostic can show the line.
(define (invalid-utf8 name data position)
  (define text (bytes->string/utf-8 data (integer->char #xFFFD)))
  (define after (source-position (add1 (source-position-offset position))
                                 (source-position-line position)
                                 (add1 (source-position-column position))))
  (diagnostic 'LEX-INVALID-UTF8
              "source file is not valid UTF-8"
              (source-span (source name text) position after)
              #:help "source files are UTF-8: save the file as UTF-8 text"))
