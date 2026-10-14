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
  (test-case "range operators lex after integers without making a Float"
    (check-equal? (kinds (lex-text "1..5 0...n 1.5 x.y"))
                  '(integer dot-dot integer integer dot-dot-dot name float name dot name NL EOF))
    (check-equal? (token-value (car (lex-text "1..5"))) 1)
    (check-equal? (map token-lexeme (take (lex-text "a...b..c") 5)) '("a" "..." "b" ".." "c")))

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
                  '(name not-equal name NL EOF))
    (check-equal? (kinds (lex-text "a&&!b||c\nx+=1"))
                  '(name and not name or name NL name plus-assign integer NL EOF)))

  (test-case "interpolated strings split into pieces around expression tokens"
    (define result (lex-text "x = \"a#{n + {\"k\": 1}[\"k\"]}b#{\"q\"}c\\#{d}\""))
    (check-equal? (kinds result)
                  '(name assign interp-start name plus left-brace string colon integer right-brace
                    left-bracket string right-bracket interp-middle string interp-end NL EOF))
    (check-equal? (map token-value (filter (lambda (t) (memq (token-kind t) '(interp-start interp-middle interp-end)))
                                           result))
                  '("a" "b" "c#{d}"))
    (check-equal? (map token-lexeme (filter (lambda (t) (memq (token-kind t) '(interp-middle interp-end)))
                                            result))
                  '("}b" "}c\\#{d}\""))
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

  (test-case "blocks inside parentheses keep their newlines"
    (check-equal? (kinds (lex-text "f(xs.map do |x|\n  if x\n  end\n  x\nend, 1)\ny"))
                  '(name left-paren name dot name do pipe name pipe NL
                    if name NL end NL name NL end comma integer right-paren NL name NL EOF))
    (check-equal? (kinds (lex-text "f(\n1)\ndef g()\nend"))
                  '(name left-paren integer right-paren NL def name left-paren right-paren NL end NL EOF))
    (define unclosed (lex-text "f(xs.map do |x|\n  x\n)"))
    (check-equal? (diagnostic-code unclosed) 'LEX-UNMATCHED-DELIMITER)
    (check-equal? (source-position-line (source-span-start (diagnostic-span unclosed))) 3)
    (check-equal? (diagnostic-code (lex-text "f(xs.map do |x|\n")) 'LEX-UNCLOSED-DELIMITER)
    (check-equal? (kinds (lex-text "def f()\n  if x\n")) '(def name left-paren right-paren NL if name NL EOF)))

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

  (test-case "a run of ## lines is one DOC token with its text and span"
    (define result (lex-text "## First\n##\n##   Third\n  ### Heading\ndef"))
    (check-equal? (kinds result) '(DOC NL def NL EOF))
    (define doc (car result))
    (check-equal? (doc-block-text (token-value doc)) "First\n\n  Third\n# Heading")
    (check-equal? (doc-block-next (token-value doc)) 'code)
    (define span (token-span doc))
    (check-equal? (list (source-position-line (source-span-start span))
                        (source-position-column (source-span-start span))
                        (source-position-line (source-span-end span))
                        (source-position-column (source-span-end span)))
                  '(1 1 4 14))
    (check-equal? (token-lexeme doc) "## First\n##\n##   Third\n  ### Heading")
    (define indented (car (lex-text "  ## a\n\t## b\n")))
    (check-equal? (doc-block-text (token-value indented)) "a\nb")
    (check-equal? (source-position-column (source-span-start (token-span indented))) 3)
    (check-equal? (doc-block-text (token-value (car (lex-text "##tight\n")))) "tight")
    (check-equal? (doc-block-text (token-value (car (lex-text "###\n")))) "#"))

  (test-case "a DOC token records what follows its block"
    (define (next-of text) (doc-block-next (token-value (car (lex-text text)))))
    (check-equal? (next-of "## a\ndef") 'code)
    (check-equal? (next-of "## a\n  def") 'code)
    (check-equal? (next-of "## a\n\ndef") 'blank)
    (check-equal? (next-of "## a\n   \ndef") 'blank)
    (check-equal? (next-of "## a\n# note\ndef") 'comment)
    (check-equal? (next-of "## a\n  # note\ndef") 'comment)
    (check-equal? (next-of "## a\n") 'eof)
    (check-equal? (next-of "## a") 'eof)
    (check-equal? (next-of "## a\r\n\r\ndef") 'blank))

  (test-case "doc blocks are split by blank and comment lines, and keep one NL each"
    (define result (lex-text "## a\n\n## b\n# c\n## d\ndef"))
    (check-equal? (kinds result) '(DOC NL NL DOC NL NL DOC NL def NL EOF))
    (check-equal? (map (lambda (t) (doc-block-text (token-value t)))
                       (filter (lambda (t) (eq? (token-kind t) 'DOC)) result))
                  '("a" "b" "d"))
    (check-equal? (kinds (lex-text "## a\r\n## b\r\ndef")) '(DOC NL def NL EOF))
    (check-equal? (doc-block-text (token-value (car (lex-text "## a\r\n## b\r\ndef")))) "a\nb")
    (check-equal? (kinds (lex-text "## a")) '(DOC NL EOF)))

  (test-case "## after code, and ## inside strings, stay ordinary text"
    (check-equal? (kinds (lex-text "x = 1 ## note")) '(name assign integer NL EOF))
    (check-equal? (kinds (lex-text "x = 1 # note\n## doc\ny = 2")) '(name assign integer NL DOC NL name assign integer NL EOF))
    (check-equal? (kinds (lex-text "x = \"## text\"")) '(name assign string NL EOF))
    (check-equal? (kinds (lex-text "\"## text\"")) '(string NL EOF))
    (check-equal? (kinds (lex-text "x = \"a#{1 + 2} ## b\" ## note"))
                  '(name assign interp-start integer plus integer interp-end NL EOF))
    (check-equal? (kinds (lex-text "# plain\n#\n#! also plain")) '(NL NL EOF)))

  (test-case "a doc line inside brackets is still a DOC token, without an NL"
    (check-equal? (kinds (lex-text "f(1,\n## doc\n2)"))
                  '(name left-paren integer comma DOC integer right-paren NL EOF)))

  (test-case "a bare carriage return after a doc line is still a lex error"
    (check-equal? (diagnostic-code (lex-text "## a\rb")) 'LEX-UNEXPECTED-CHAR))

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

  (test-case "C-style habits get a help that names the fix"
    (define semicolon (lex-text "x = 1;\ny = 2"))
    (check-equal? (diagnostic-code semicolon) 'LEX-UNEXPECTED-CHAR)
    (check-equal? (diagnostic-message semicolon) "unexpected character \";\"")
    (check-equal? (source-position-column (source-span-start (diagnostic-span semicolon))) 6)
    (check-regexp-match #rx"newline" (diagnostic-help semicolon))
    (check-false (diagnostic-help (lex-text "x @")))
    (define quote-char (lex-text "x = s[0] == '+'"))
    (check-equal? (diagnostic-code quote-char) 'LEX-UNEXPECTED-CHAR)
    (check-equal? (diagnostic-message quote-char) "unexpected character \"'\"")
    (check-regexp-match #rx"double quotes" (diagnostic-help quote-char))
    (define stray (lex-text "def main() -> Void\n  puts(1)\n}\n"))
    (check-equal? (diagnostic-code stray) 'LEX-UNMATCHED-DELIMITER)
    (check-equal? (source-position-line (source-span-start (diagnostic-span stray))) 3)
    (check-regexp-match #rx"\"end\"" (diagnostic-help stray))
    (check-false (diagnostic-help (lex-text "f(1}")))
    (check-false (diagnostic-help (lex-text ")")))
    (define unclosed (lex-text "x = {\"a\": 1"))
    (check-equal? (diagnostic-code unclosed) 'LEX-UNCLOSED-DELIMITER)
    (check-regexp-match #rx"\"end\"" (diagnostic-help unclosed)))

  (test-case "mismatched and unclosed delimiters are diagnostics"
    (check-equal? (diagnostic-code (lex-text ")"))
                  'LEX-UNMATCHED-DELIMITER)
    (check-equal? (diagnostic-code (lex-text "(["))
                  'LEX-UNCLOSED-DELIMITER)
    (check-equal? (diagnostic-code (lex-text "}"))
                  'LEX-UNMATCHED-DELIMITER)
    (check-equal? (diagnostic-code (lex-text "{"))
                  'LEX-UNCLOSED-DELIMITER))

  (test-case "the pipe token is the longest match next to | and ||"
    (check-equal? (kinds (lex-text "a |> f()"))
                  '(name pipe-forward name left-paren right-paren NL EOF))
    (check-equal? (map token-lexeme (take (lex-text "a|>b") 3)) '("a" "|>" "b"))
    (check-equal? (kinds (lex-text "a || b | c"))
                  '(name or name pipe name NL EOF))
    (check-equal? (kinds (lex-text "xs.each do |x|\nend"))
                  '(name dot name do pipe name pipe NL end NL EOF))
    (check-equal? (kinds (lex-text "a ||> b"))
                  '(name or greater name NL EOF))))
