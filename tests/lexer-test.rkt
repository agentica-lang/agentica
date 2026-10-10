#lang racket

(require rackunit
         "../src/diagnostic.rkt"
         "../src/lexer.rkt"
         "../src/source.rkt"
         "../src/token.rkt")

(define (lex-text text)
  (lex (source "test.agc" text)))

(define (kinds result)
  (map token-kind result))

(module+ test
  (test-case "keywords, identifiers, numeric literals, and EOF"
    (define result (lex-text "def main() -> Void\n  count = 12\n  ratio = 1.25"))
    (check-equal? (kinds result)
                  '(def name left-paren right-paren arrow type-name NL
                    name assign integer NL name assign float NL EOF))
    (check-equal? (token-value (list-ref result 9)) 12)
    (check-equal? (token-value (list-ref result 13)) 1.25)
    (check-equal? (source-position-line
                   (source-span-start (token-span (list-ref result 9))))
                  2))

  (test-case "Ruby-style operators keep name suffixes and inequality"
    (check-equal? (kinds (lex-text "!a && b || ready! != c"))
                  '(not name and name or name not-equal name NL EOF))
    (check-equal? (map token-lexeme (take (lex-text "!a && b") 3)) '("!" "a" "&&"))
    (check-equal? (kinds (lex-text "x += 1\nx -= 1\nx *= 1\nx /= 1\nx %= 1"))
                  '(name plus-assign integer NL name minus-assign integer NL
                    name multiply-assign integer NL name divide-assign integer NL
                    name modulo-assign integer NL EOF))
    (check-equal? (kinds (lex-text "a!=b"))
                  '(name not-equal name NL EOF)))

  (test-case "interpolated strings split into pieces around expression tokens"
    (define result (lex-text "x = \"a#{n + {\"k\": 1}[\"k\"]}b#{\"q\"}c\\#{d}\""))
    (check-equal? (kinds result)
                  '(name assign interp-start name plus left-brace string colon integer right-brace
                    left-bracket string right-bracket interp-middle string interp-end NL EOF))
    (check-equal? (map token-value (filter (lambda (t) (memq (token-kind t) '(interp-start interp-middle interp-end)))
                                           result))
                  '("a" "b" "c#{d}"))
    (check-equal? (source-position-column (source-span-start (token-span (list-ref result 2)))) 5)
    (check-equal? (kinds (lex-text "\"plain # text\"")) '(string NL EOF))
    (for ([text '("x = \"a#{n\n}\"" "x = \"a#{n" "x = \"#{n}")])
      (define problem (lex-text text))
      (check-true (diagnostic? problem) text)
      (check-equal? (diagnostic-code problem) 'LEX-UNTERMINATED-STRING text)
      (check-equal? (source-position-column (source-span-start (diagnostic-span problem))) 5 text)))

  (test-case "CRLF and comment newlines produce one NL each"
    (check-equal? (kinds (lex-text "x # comment\r\ny\r\n"))
                  '(name NL name NL EOF)))

  (test-case "newlines inside parentheses and brackets are suppressed"
    (check-equal? (kinds (lex-text "x = ([\n1,\n2\n])\ny"))
                  '(name assign left-paren left-bracket integer comma integer
                    right-bracket right-paren NL name NL EOF)))

  (test-case "newlines inside braces are suppressed"
    (check-equal? (kinds (lex-text "x = {\n\"a\": 1,\n}\ny"))
                  '(name assign left-brace string colon integer comma
                    right-brace NL name NL EOF)))

  (test-case "operators and delimiters are recognized"
    (check-equal? (kinds (lex-text "-> == != <= >= ( ) [ ] , : . = + - * / % < >"))
                  '(arrow equal not-equal less-equal greater-equal
                    left-paren right-paren left-bracket right-bracket
                    comma colon dot assign plus minus multiply divide modulo
                    less greater NL EOF)))

  (test-case "function suffixes do not depend on parentheses or whitespace"
    (define qualified (lex-text "String.contains?(s, p)"))
    (check-equal? (kinds qualified)
                  '(type-name dot name left-paren name comma name right-paren NL EOF))
    (check-equal? (token-lexeme (list-ref qualified 2)) "contains?")
    (define bang (lex-text "x = to_int!(\"1\")"))
    (check-equal? (token-lexeme (list-ref bang 2)) "to_int!")
    (check-equal? (kinds (lex-text "a!=b")) '(name not-equal name NL EOF))
    (check-equal? (map token-lexeme (take (lex-text "ready? save! a!=b") 5))
                  '("ready?" "save!" "a" "!=" "b"))
    (check-equal? (token-lexeme (list-ref (lex-text "String.contains? (s, p)") 2)) "contains?"))

  (test-case "each blank or comment newline emits NL without changing parsing"
    (check-equal? (kinds (lex-text "x\n\n# comment\ny"))
                  '(name NL NL NL name NL EOF)))

  (test-case "strings decode only the specified escapes"
    (define result (lex-text "\"quote: \\\" slash: \\\\ newline: \\n return: \\r tab: \\t\""))
    (check-equal? (token-value (car result))
                  "quote: \" slash: \\ newline: \n return: \r tab: \t"))

  (test-case "empty input receives NL and EOF"
    (check-equal? (kinds (lex-text "")) '(NL EOF)))

  (test-case "unexpected characters and invalid strings are diagnostics"
    (define bad-char (lex-text "x @"))
    (check-true (diagnostic? bad-char))
    (check-equal? (diagnostic-code bad-char) 'LEX-UNEXPECTED-CHAR)
    (check-equal? (source-position-column
                   (source-span-start (diagnostic-span bad-char)))
                  3)
    (check-equal? (diagnostic-code (lex-text "\"unfinished"))
                  'LEX-UNTERMINATED-STRING)
    (check-equal? (diagnostic-code (lex-text "\"bad\\q\""))
                  'LEX-INVALID-ESCAPE))

  (test-case "mismatched and unclosed delimiters are diagnostics"
    (check-equal? (diagnostic-code (lex-text ")"))
                  'LEX-UNMATCHED-DELIMITER)
    (check-equal? (diagnostic-code (lex-text "(["))
                  'LEX-UNCLOSED-DELIMITER)
    (check-equal? (diagnostic-code (lex-text "}"))
                  'LEX-UNMATCHED-DELIMITER)
    (check-equal? (diagnostic-code (lex-text "{"))
                  'LEX-UNCLOSED-DELIMITER)))
