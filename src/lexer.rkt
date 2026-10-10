#lang racket

(require "diagnostic.rkt"
         "source.rkt"
         "token.rkt")

(provide lex)

(define keywords
  (hash "import" 'import "export" 'export
        "def" 'def "struct" 'struct "enum" 'enum "case" 'case "do" 'do "end" 'end
        "if" 'if "elsif" 'elsif "else" 'else
        "while" 'while "for" 'for "in" 'in "return" 'return "try" 'try
        "true" 'true "false" 'false "nil" 'nil
        "and" 'and "or" 'or "not" 'not))

(define (ascii-letter? char)
  (or (char<=? #\a char #\z)
      (char<=? #\A char #\Z)))

(define (ascii-digit? char)
  (char<=? #\0 char #\9))

(define (lex input)
  (define text (source-text input))
  (define source-length (string-length text))
  (define index 0)
  (define line 1)
  (define column 1)
  (define reversed-tokens '())
  (define delimiters '())

  (define (position)
    (source-position index line column))

  (define (span-from start)
    (source-span input start (position)))

  (define (current)
    (string-ref text index))

  (define (peek distance)
    (and (< (+ index distance) source-length)
         (string-ref text (+ index distance))))

  (define (advance!)
    (define char (current))
    (set! index (add1 index))
    (if (char=? char #\newline)
        (begin (set! line (add1 line)) (set! column 1))
        (set! column (add1 column)))
    char)

  (define (advance-newline!)
    (define start (position))
    (if (and (char=? (current) #\return) (equal? (peek 1) #\newline))
        (begin (set! index (+ index 2))
               (set! line (add1 line))
               (set! column 1))
        (advance!))
    start)

  (define (emit! kind start value)
    (define token-span (span-from start))
    (set! reversed-tokens
          (cons (token kind
                       (substring text (source-position-offset start) index)
                       value
                       token-span)
                reversed-tokens)))

  (define (fail code message start)
    (diagnostic code message (span-from start)))

  (define (scan-while! predicate)
    (let loop ()
      (when (and (< index source-length) (predicate (current)))
        (advance!)
        (loop))))

  (let/ec return
    (let scan ()
      (cond
        [(= index source-length)
         (when (and (null? delimiters)
                    (or (null? reversed-tokens)
                        (not (eq? (token-kind (car reversed-tokens)) 'NL))))
           (define start (position))
           (emit! 'NL start #f))
         (unless (null? delimiters)
           (define opening (car delimiters))
           (return (fail 'LEX-UNCLOSED-DELIMITER
                         (format "unclosed ~a delimiter" (car opening))
                         (cdr opening))))
         (emit! 'EOF (position) #f)
         (reverse reversed-tokens)]
        [else
         (define char (current))
         (cond
           [(or (char=? char #\space) (char=? char #\tab))
            (advance!)
            (scan)]
           [(or (char=? char #\newline) (char=? char #\return))
            (when (and (char=? char #\return)
                       (not (equal? (peek 1) #\newline)))
              (return (fail 'LEX-UNEXPECTED-CHAR
                            "unexpected carriage return"
                            (position))))
            (define start (advance-newline!))
            (when (null? delimiters)
              (emit! 'NL start #f))
            (scan)]
           [(char=? char #\#)
            (scan-while! (lambda (c) (not (memv c '(#\newline #\return)))))
            (scan)]
           [(or (ascii-letter? char) (char=? char #\_))
            (define start (position))
            (advance!)
            (scan-while! (lambda (c) (or (ascii-letter? c)
                                         (ascii-digit? c)
                                         (char=? c #\_))))
            ;; Suffixes belong to names, but "!=" remains an operator.
            (when (and (not (char<=? #\A char #\Z))
                       (< index source-length)
                       (memv (current) '(#\? #\!))
                       (not (and (char=? (current) #\!)
                                 (equal? (peek 1) #\=))))
              (advance!))
            (define lexeme (substring text (source-position-offset start) index))
            (define kind
              (hash-ref keywords lexeme
                        (lambda () (if (char<=? #\A char #\Z)
                                       'type-name
                                       'name))))
            (emit! kind start lexeme)
            (scan)]
           [(ascii-digit? char)
            (define start (position))
            (scan-while! ascii-digit?)
            (define float?
              (and (equal? (peek 0) #\.)
                   (peek 1)
                   (ascii-digit? (peek 1))))
            (when float?
              (advance!)
              (scan-while! ascii-digit?))
            (define lexeme (substring text (source-position-offset start) index))
            (emit! (if float? 'float 'integer) start (string->number lexeme))
            (scan)]
           [(char=? char #\")
            (define start (position))
            (advance!)
            (define decoded (open-output-string))
            (let string-loop ()
              (cond
                [(= index source-length)
                 (return (fail 'LEX-UNTERMINATED-STRING "unterminated string" start))]
                [(or (char=? (current) #\newline) (char=? (current) #\return))
                 (return (fail 'LEX-UNTERMINATED-STRING "unterminated string" start))]
                [(char=? (current) #\")
                 (advance!)
                 (emit! 'string start (get-output-string decoded))
                 (scan)]
                [(char=? (current) #\\)
                 (define escape-start (position))
                 (advance!)
                 (when (= index source-length)
                   (return (fail 'LEX-INVALID-ESCAPE "incomplete string escape" escape-start)))
                 (define escaped (current))
                 (define decoded-char
                   (case escaped
                     [(#\") #\"]
                     [(#\\) #\\]
                     [(#\n) #\newline]
                     [(#\r) #\return]
                     [(#\t) #\tab]
                     [else #f]))
                 (unless decoded-char
                   (advance!)
                   (return (fail 'LEX-INVALID-ESCAPE
                                 (format "unsupported escape \\~a" escaped)
                                 escape-start)))
                 (advance!)
                 (write-char decoded-char decoded)
                 (string-loop)]
                [else
                 (write-char (advance!) decoded)
                 (string-loop)]))]
           [else
            (define start (position))
            (define two-char
              (and (peek 1)
                   (member (string (current) (peek 1))
                           '("->" "==" "!=" "<=" ">=" "&&" "||" "+=" "-=" "*=" "/=" "%="))
                   (string (current) (peek 1))))
            (define lexeme (or two-char (string char)))
            (define kind
              (hash-ref
               (hash "->" 'arrow "==" 'equal "!=" 'not-equal
                     "<=" 'less-equal ">=" 'greater-equal
                     "&&" 'and "||" 'or "!" 'not
                     "+=" 'plus-assign "-=" 'minus-assign "*=" 'multiply-assign
                     "/=" 'divide-assign "%=" 'modulo-assign
                     "(" 'left-paren ")" 'right-paren
                     "[" 'left-bracket "]" 'right-bracket
                     "{" 'left-brace "}" 'right-brace
                     "," 'comma ":" 'colon "." 'dot
                     "=" 'assign "+" 'plus "-" 'minus
                     "*" 'multiply "/" 'divide "%" 'modulo
                     "<" 'less ">" 'greater "&" 'ampersand)
               lexeme
               #f))
            (unless kind
              (advance!)
              (return (fail 'LEX-UNEXPECTED-CHAR
                            (format "unexpected character ~s" char)
                            start)))
            (for ([unused (in-string lexeme)]) (advance!))
            (when (memq kind '(left-paren left-bracket left-brace))
              (set! delimiters (cons (cons char start) delimiters)))
            (when (memq kind '(right-paren right-bracket right-brace))
              (define expected (case char [(#\)) #\(] [(#\]) #\[] [else #\{]))
              (unless (and (pair? delimiters)
                           (char=? (caar delimiters) expected))
                (return (fail 'LEX-UNMATCHED-DELIMITER
                              (format "unmatched ~a delimiter" char)
                              start)))
              (set! delimiters (cdr delimiters)))
            (emit! kind start lexeme)
            (scan)])]))))
