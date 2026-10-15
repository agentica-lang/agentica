#lang racket/base

;; Shared by the tools that write Agentica data files under compiler/: values as small trees that print on one line
;; when they fit in `max-width` characters (the [style] max_line_width of compiler/agentica.toml) and otherwise one
;; item per line with a trailing comma, plus doc comments wrapped to the same width.

(require racket/list
         racket/string)

(provide max-width
         (struct-out group)
         (struct-out lit)
         render
         doc-comment)

(define max-width 119)

;; `prefix open item, item close`: a call or a list. `prefix` is "" or a label such as "name: ".
(struct group (prefix open close items))

;; A string literal. `text` is the unquoted text, `quote` turns a piece of it into source. A literal that does not
;; fit is written as pieces joined with `+` inside parentheses.
(struct lit (prefix text quote))

(define (flat node)
  (cond
    [(string? node) node]
    [(lit? node) (string-append (lit-prefix node) ((lit-quote node) (lit-text node)))]
    [else
     (string-append (group-prefix node) (group-open node)
                    (string-join (map flat (group-items node)) ", ")
                    (group-close node))]))

;; Breaks `text` after spaces into pieces whose quoted form is at most `room` characters when possible.
(define (pieces text quoter room)
  (define words (regexp-match* #px"[^ ]+ *" text))
  (let loop ([words words] [current ""] [done '()])
    (cond
      [(null? words) (reverse (if (string=? current "") done (cons current done)))]
      [(or (string=? current "")
           (<= (string-length (quoter (string-append current (car words)))) room))
       (loop (cdr words) (string-append current (car words)) done)]
      [else (loop words "" (cons current done))])))

;; The text of `node` as it goes on a line indented `indent`, the first line without that indentation. `trailing`
;; is the number of characters that follow the node on its last line, `lead` the number of characters before it on
;; its first line (after the indentation), such as the "return " of a return statement.
(define (render node indent trailing [lead 0])
  (define one-line (flat node))
  (cond
    [(<= (+ indent lead (string-length one-line) trailing) max-width) one-line]
    [(lit? node)
     (define inner (+ indent 2))
     (define parts (pieces (lit-text node) (lit-quote node) (- max-width inner 2)))
     (string-append (lit-prefix node) "(\n"
                    (string-join (for/list ([part (in-list parts)]) (string-append (make-string inner #\space) ((lit-quote node) part)))
                                 " +\n")
                    "\n" (make-string indent #\space) ")")]
    [(string? node) node]
    [else
     (define inner (+ indent 2))
     (string-append (group-prefix node) (group-open node) "\n"
                    (string-append*
                     (for/list ([item (in-list (group-items node))])
                       (string-append (make-string inner #\space) (render item inner 1) ",\n")))
                    (make-string indent #\space) (group-close node))]))

;; A `##` doc block of `text`, wrapped at words and ended with a newline.
(define (doc-comment text)
  (define words (string-split text " "))
  (define room (- max-width 3))
  (define lines
    (let loop ([words words] [current ""] [done '()])
      (cond
        [(null? words) (reverse (if (string=? current "") done (cons current done)))]
        [(string=? current "") (loop (cdr words) (car words) done)]
        [(<= (+ (string-length current) 1 (string-length (car words))) room)
         (loop (cdr words) (string-append current " " (car words)) done)]
        [else (loop words "" (cons current done))])))
  (string-append* (for/list ([line (in-list lines)]) (string-append "## " line "\n"))))
