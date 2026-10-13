#lang racket

(require "ast.rkt" "builtins.rkt" "builtin-types.rkt" "diagnostic.rkt" "source.rkt")

(provide lower
         format-ir
         vm-builtins
         (struct-out ir-program)
         (struct-out ir-struct)
         (struct-out ir-enum)
         (struct-out ir-function)
         (struct-out ir-label)
         (struct-out ir-instr))

(struct ir-program (sources structs enums functions entry span) #:transparent)
(struct ir-struct (name fields types) #:transparent)
(struct ir-enum (name variants) #:transparent)
(struct ir-function (name params captures slots body span) #:transparent)
(struct ir-label (id) #:transparent)
(struct ir-instr (op args spans) #:transparent)

(define int-min (- (expt 2 63)))
(define int-max (sub1 (expt 2 63)))

(define value-types '(Int Float Bool Nil String Range Json FileHandle Process Socket Listener HttpClient))

(define builtin-structs
  (for/list ([name (in-list '("FileInfo" "Header" "HttpResponse" "HttpClientOptions" "ProcessOutput"))])
    (define fields (hash-ref builtin-records name))
    (ir-struct name (map car fields) (map cdr fields))))

(define builtin-struct-needs (hash "HttpResponse" '("Header")))

(define (mentions-struct? type name)
  (cond
    [(equal? type (list 'Struct name)) #t]
    [(pair? type) (for/or ([part (in-list type)]) (mentions-struct? part name))]
    [else #f]))

(define (used-builtin-structs types declarations)
  (define written '())
  (walk-ast declarations
            (lambda (node)
              (when (type-expression? node) (set! written (cons (type-expression-name node) written)))
              (when (type-ref? node) (set! written (cons (type-ref-name node) written)))
              #f))
  (define named
    (for*/list ([entry (in-list builtin-structs)]
                #:when (or (member (ir-struct-name entry) written)
                           (for/or ([type (in-hash-values types)]) (mentions-struct? type (ir-struct-name entry)))))
      (ir-struct-name entry)))
  (define wanted (append named (append-map (lambda (name) (hash-ref builtin-struct-needs name '())) named)))
  (filter (lambda (entry) (member (ir-struct-name entry) wanted)) builtin-structs))

(define max-list-chunk 255)
(define max-map-chunk 255)

(define (vm-type? type user-types)
  (cond
    [(list-type? type) (vm-type? (cadr type) user-types)]
    [(map-type? type) (vm-type? (caddr type) user-types)]
    [(result-type? type) (or (eq? (cadr type) 'Void) (vm-type? (cadr type) user-types))]
    [(and (pair? type) (eq? (car type) 'Task))
     (or (eq? (cadr type) 'Void) (vm-type? (cadr type) user-types))]
    [(and (pair? type) (memq (car type) '(Struct Enum)))
     (eq? (hash-ref user-types (cadr type) #f) (car type))]
    [(and (pair? type) (eq? (car type) 'Fn))
     (and (for/and ([parameter (in-list (drop-right (cdr type) 1))])
            (vm-type? parameter user-types))
          (or (eq? (last type) 'Void) (vm-type? (last type) user-types)))]
    [else (and (memq type value-types) #t)]))

(define (json-field-type reference struct-names)
  (define name (type-ref-name reference))
  (define args (type-ref-args reference))
  (cond
    [(and (null? args) (member name '("Int" "Float" "Bool" "String"))) (string->symbol name)]
    [(and (equal? name "List") (= (length args) 1))
     (define item (json-field-type (car args) struct-names))
     (and item (list 'List item))]
    [(and (equal? name "Map") (= (length args) 2)
          (equal? (type-ref-name (car args)) "String") (null? (type-ref-args (car args))))
     (define value (json-field-type (cadr args) struct-names))
     (and value (list 'Map 'String value))]
    [(and (null? args) (member name struct-names)) (list 'Struct name)]
    [else #f]))

(define (struct-names-in type)
  (cond
    [(symbol? type) '()]
    [(eq? (car type) 'Struct) (list (cadr type))]
    [else (struct-names-in (last type))]))

(define (decodable-structs structs)
  (define names (append (map struct-decl-name structs) (map ir-struct-name builtin-structs)))
  (define candidates
    (for*/fold ([table (for/hash ([entry (in-list builtin-structs)])
                         (values (ir-struct-name entry) (ir-struct-types entry)))])
               ([declaration (in-list structs)]
                [types (in-value (for/list ([field (in-list (struct-decl-fields declaration))])
                                   (json-field-type (field-decl-type field) names)))]
                #:when (andmap values types))
      (hash-set table (struct-decl-name declaration) types)))
  (let loop ([table candidates])
    (define kept
      (for/hash ([(name types) (in-hash table)]
                 #:when (for/and ([type (in-list types)])
                          (andmap (lambda (n) (hash-has-key? table n)) (struct-names-in type))))
        (values name types)))
    (if (= (hash-count kept) (hash-count table)) kept (loop kept))))

(define (has-type-expression? node)
  (define seen (make-hasheq))
  (let walk ([node node])
    (cond
      [(type-expression? node) #t]
      [(pair? node) (or (walk (car node)) (walk (cdr node)))]
      [(and (struct? node) (not (hash-ref seen node #f)))
       (hash-set! seen node #t)
       (for/or ([field (in-vector (struct->vector node) 1)]) (walk field))]
      [else #f])))

(define (user-tables declarations)
  (define struct-decls (filter struct-decl? declarations))
  (define decodable
    (if (has-type-expression? (filter function-decl? declarations))
        (decodable-structs struct-decls)
        (hash)))
  (values
   (for/list ([declaration (in-list struct-decls)])
     (ir-struct (struct-decl-name declaration) (map field-decl-name (struct-decl-fields declaration))
                (hash-ref decodable (struct-decl-name declaration) #f)))
   (for/list ([declaration (in-list declarations)] #:when (enum-decl? declaration))
     (ir-enum (enum-decl-name declaration)
              (for/list ([variant (in-list (enum-decl-variants declaration))])
                (cons (enum-variant-name variant) (length (enum-variant-payload-types variant))))))))

(define (list-type? type)
  (and (pair? type) (eq? (car type) 'List)))

(define (map-type? type)
  (and (pair? type) (eq? (car type) 'Map)))

(define (result-type? type)
  (and (pair? type) (eq? (car type) 'Result)))

(define int-ops
  (hasheq 'plus 'add-i 'minus 'sub-i 'multiply 'mul-i 'divide 'div-i 'modulo 'mod-i
          'less 'lt-i 'less-equal 'le-i 'greater 'lt-i 'greater-equal 'le-i))

(define float-ops
  (hasheq 'plus 'add-f 'minus 'sub-f 'multiply 'mul-f 'divide 'div-f
          'less 'lt-f 'less-equal 'le-f 'greater 'lt-f 'greater-equal 'le-f))

(define string-ops (hasheq 'plus 'concat))

(define vm-builtins '("puts" "IO.print" "IO.warn" "IO.inspect" "IO.gets" "IO.gets!" "IO.read"
                      "IO.read_bytes" "IO.flush" "IO.eof?" "System.args" "System.exit"
                      "String.from_int" "String.from_float" "ok" "error" "Result.ok?" "Result.unwrap!" "Result.unwrap_or" "Result.message"
                      "List.map" "List.filter" "List.reduce" "List.each" "List.any?" "List.all?" "List.sort_by"
                      "Range.size" "Range.to_a" "Range.include?" "Range.each" "Range.first" "Range.last"
                      "Int.times" "Int.upto" "Int.downto"
                      "List.size" "List.append" "List.set" "List.repeat" "List.concat" "List.take"
                      "List.drop" "List.at" "List.reverse" "List.sort"
                      "Map.has_key?" "Map.keys" "Map.size" "Map.put" "Map.get" "Map.delete" "Map.values"
                      "String.length" "String.upcase" "String.downcase" "String.trim" "String.split" "String.join"
                      "String.contains?" "String.starts_with?" "String.ends_with?" "String.replace" "String.slice"
                      "String.index_of" "String.at" "String.reverse" "String.code" "String.from_code" "String.from_bytes"
                      "String.to_int" "String.to_int!" "String.to_float" "String.to_float!"
                      "Float.from_int" "Float.to_int" "Float.to_int!" "Time.now_ms" "Time.monotonic_ms"
                      "Random.int" "Random.float"
                      "JSON.parse" "JSON.encode" "JSON.from" "JSON.object" "JSON.array" "JSON.null" "JSON.null?"
                      "JSON.get" "JSON.at" "JSON.string" "JSON.int" "JSON.float" "JSON.bool" "JSON.list"
                      "JSON.decode" "JSON.schema"
                      "File.open" "File.read_bytes" "File.read_line" "File.write" "File.write_bytes" "File.flush"
                      "File.close" "File.read_text" "File.write_text" "File.append_text" "File.stat"
                      "Dir.list" "Dir.mkdir" "Path.cwd" "Path.join" "Path.resolve"
                      "Task.spawn" "Task.await" "Task.sleep"
                      "Process.spawn" "Process.send" "Process.send_bytes" "Process.read_line" "Process.read_bytes"
                      "Process.close_stdin" "Process.wait" "Process.close"
                      "TCP.connect" "TCP.listen" "TCP.accept" "TCP.local_port" "TCP.close_listener"
                      "TCP.send" "TCP.send_bytes" "TCP.recv_bytes" "TCP.read_line" "TCP.close"
                      "TLS.connect" "TLS.listen"
                      "HttpWire.client" "HttpWire.exchange" "HttpWire.close_client"
                      "Process.spawn_captured" "Process.output" "Task.pending_count"))

(define (walk-ast node visit)
  (define seen (make-hasheq))
  (let walk ([node node])
    (cond
      [(visit node) (void)]
      [(pair? node) (walk (car node)) (walk (cdr node))]
      [(and (struct? node) (not (hash-ref seen node #f)))
       (hash-set! seen node #t)
       (for ([field (in-vector (struct->vector node) 1)]) (walk field))]
      [else (void)])))

(define (referenced-names node)
  (define found (make-hash))
  (define names '())
  (walk-ast node
            (lambda (node)
              (and (name-ref? node)
                   (unless (hash-ref found (name-ref-name node) #f)
                     (hash-set! found (name-ref-name node) #t)
                     (set! names (cons (name-ref-name node) names)))
                   #t)))
  (reverse names))

(define (lower program types)
  (let/ec return
    (define (unsupported what span)
      (return (diagnostic 'LOWER-UNSUPPORTED
                          (format "the VM does not support ~a yet" what)
                          span)))
    (with-handlers ([exn:fail? (lambda (failure)
                                 (diagnostic 'LOWER-INTERNAL (exn-message failure)
                                             (program-span program)))])
      (define declarations
        (for/list ([declaration (in-list (program-declarations program))]
                   #:when (function-decl? declaration))
          declaration))
      (define-values (declared-structs enums) (user-tables (program-declarations program)))
      (define structs (append declared-structs (used-builtin-structs types (program-declarations program))))
      (define user-types (make-hash))
      (define struct-info (make-hash))
      (for ([entry (in-list structs)] [index (in-naturals)])
        (hash-set! user-types (ir-struct-name entry) 'Struct)
        (hash-set! struct-info (ir-struct-name entry) (cons index (ir-struct-fields entry))))
      (define variant-ids (make-hash))
      (for/fold ([id 0]) ([entry (in-list enums)])
        (hash-set! user-types (ir-enum-name entry) 'Enum)
        (for/fold ([id id]) ([variant (in-list (ir-enum-variants entry))])
          (hash-set! variant-ids (cons (ir-enum-name entry) (car variant)) id)
          (add1 id)))
      (define json-structs
        (for/hash ([entry (in-list structs)] #:when (ir-struct-types entry)) (values (ir-struct-name entry) #t)))
      (define program-types (list user-types struct-info variant-ids json-structs))
      (define function-index
        (for/hash ([declaration (in-list declarations)] [index (in-naturals)])
          (values (function-decl-name declaration) index)))
      (define sources '())
      (define (note-source! span)
        (define text-source (source-span-source span))
        (unless (memq text-source sources)
          (set! sources (append sources (list text-source)))))
      (note-source! (program-span program))
      (define blocks (make-hasheqv))
      (define block-count (length declarations))
      (define (new-block! make)
        (define index block-count)
        (set! block-count (add1 block-count))
        (hash-set! blocks index (make))
        index)
      (define env (list types program-types function-index unsupported note-source! new-block!))
      (define functions
        (for/list ([declaration (in-list declarations)])
          (lower-function (function-decl-name declaration)
                          (map param-name (function-decl-params declaration))
                          '()
                          (function-decl-body declaration)
                          (function-decl-span declaration)
                          #f
                          env)))
      (ir-program sources structs enums
                  (append functions
                          (for/list ([index (in-range (length declarations) block-count)])
                            (hash-ref blocks index)))
                  (hash-ref function-index "main")
                  (program-span program)))))

(define (lower-function name parameter-names capture-names statements function-span block? env)
  (match-define (list types program-types function-index unsupported note-source! new-block!) env)
  (match-define (list user-types struct-info variant-ids json-structs) program-types)
  (define code '())
  (define next 0)
  (define high 0)
  (define scopes (list (make-hash)))
  (define label-count 0)
  (define loop-labels #f)
  (define after-step #f)

  (define (emit! op args . spans)
    (for-each note-source! spans)
    (set! code (cons (ir-instr op args spans) code)))
  (define (new-label!)
    (set! label-count (add1 label-count))
    (sub1 label-count))
  (define (place! label) (set! code (cons (ir-label label) code)))
  (define (alloc!)
    (define slot next)
    (set! next (add1 next))
    (set! high (max high next))
    slot)
  (define (lookup name)
    (for/or ([scope (in-list scopes)]) (hash-ref scope name #f)))
  (define (scoped thunk)
    (define saved next)
    (set! scopes (cons (make-hash) scopes))
    (thunk)
    (set! scopes (cdr scopes))
    (set! next saved))

  (define (type-of expression)
    (hash-ref types expression #f))
  (define (require-type! expression void? [type (type-of expression)])
    (unless (or (vm-type? type user-types) (and void? (eq? type 'Void)))
      (unsupported (if type (format "values of type ~a" (type->string type)) "this expression")
                   (node-span expression))))

  (define (target want)
    (or want (alloc!)))
  (define (resolved-of expression)
    (cond
      [(method-call? expression) (method-call-resolved expression)]
      [(field-access? expression) (field-access-resolved expression)]
      [else #f]))
  (define (static-type expression)
    (if (typed-target? expression) (typed-target-type expression) (type-of expression)))

  (define (lower-expression expression want #:void? [void? #f] #:known? [known? #f])
    (cond
      [(and (unary? expression) (eq? (unary-op expression) 'minus)
            (literal? (unary-operand expression))
            (eqv? (literal-value (unary-operand expression)) (- int-min)))
       (emit! 'step '() (unary-span expression))
       (emit! 'step '() (literal-span (unary-operand expression)))
       (define dst (target want))
       (emit! 'const (list dst int-min) (unary-span expression))
       dst]
      [(call? expression) (lower-call expression want void?)]
      [(resolved-of expression)
       => (lambda (resolved)
            (require-type! expression void?)
            (if (call? resolved)
                (lower-call resolved want void? #:checked? #t)
                (lower-expression resolved want)))]
      [(typed-target? expression)
       (define inner (typed-target-expression expression))
       (require-type! inner #f (typed-target-type expression))
       (lower-expression inner want)]
      [(type-expression? expression)
       (define name (type-expression-name expression))
       (define span (node-span expression))
       (unless (hash-has-key? json-structs name)
         (unsupported (format "the type ~a" (display-name name)) span))
       (emit! 'step '() span)
       (define dst (target want))
       (emit! 'const (list dst name) span)
       dst]
      [(or (interpolation? expression) (inspection? expression)) (lower-value expression want)]
      [(or (try-expr? expression) (invoke? expression))
       (require-type! expression void?)
       (lower-value expression want)]
      [else
       (unless known? (require-type! expression #f))
       (lower-value expression want)]))

  (define (lower-value expression want)
    (define span (node-span expression))
    (cond
      [(literal? expression)
       (emit! 'step '() span)
       (define dst (target want))
       (emit! 'const (list dst (literal-value expression)) span)
       dst]
      [(name-ref? expression)
       (emit! 'step '() span)
       (define slot (lookup (name-ref-name expression)))
       (cond
         [want (emit! 'move (list want slot) span) want]
         [else slot])]
      [(unary? expression)
       (emit! 'step '() span)
       (define saved next)
       (define dst (target want))
       (define operand (lower-expression (unary-operand expression) #f))
       (emit! (cond [(eq? (unary-op expression) 'not) 'not]
                    [(eq? (type-of (unary-operand expression)) 'Float) 'neg-f]
                    [else 'neg-i])
              (list dst operand)
              (unary-op-span expression))
       (set! next (if want saved (add1 dst)))
       dst]
      [(binary? expression) (lower-binary expression want)]
      [(list-lit? expression) (lower-list expression want)]
      [(map-lit? expression) (lower-map expression want)]
      [(enum-constructor? expression)
       (lower-enum (enum-constructor-enum-name expression) (enum-constructor-variant-name expression)
                   (enum-constructor-args expression) span want)]
      [(construct? expression)
       (define parts (string-split (construct-type-name expression) "."))
       (if (and (= (length parts) 2) (eq? (hash-ref user-types (car parts) #f) 'Enum))
           (lower-enum (car parts) (cadr parts)
                       (for/list ([argument (in-list (construct-args expression))])
                         (if (named-arg? argument) (named-arg-value argument) argument))
                       span want)
           (lower-struct expression want))]
      [(field-access? expression)
       (emit! 'step '() span)
       (define saved next)
       (define dst (target want))
       (define target-node (field-access-target expression))
       (define source (lower-expression target-node #f))
       (define fields (cdr (hash-ref struct-info (cadr (static-type target-node)))))
       (emit! 'field (list dst source (index-of fields (field-access-name expression))) span)
       (set! next (if want saved (add1 dst)))
       dst]
      [(index-access? expression)
       (define target-node (index-access-target expression))
       (emit! 'step '() span)
       (define saved next)
       (define dst (target want))
       (define items (lower-expression target-node #f))
       (define index (lower-expression (index-access-index expression) #f))
       (emit! (if (map-type? (static-type target-node)) 'map-get 'list-get)
              (list dst items index) (node-span (index-access-index expression)))
       (set! next (if want saved (add1 dst)))
       dst]
      [(try-expr? expression)
       (emit! 'step '() span)
       (define saved next)
       (define dst (target want))
       (define operand (lower-expression (try-expr-operand expression) #f))
       (emit! 'try (list dst operand) span)
       (set! next (if want saved (add1 dst)))
       dst]
      [(inspection? expression)
       (emit! 'step '() span)
       (define saved next)
       (define dst (target want))
       (define operand (lower-expression (inspection-target expression) #f))
       (emit! 'inspect (list dst operand) span)
       (set! next (if want saved (add1 dst)))
       dst]
      [(interpolation? expression)
       (emit! 'step '() span)
       (define saved next)
       (define dst (target want))
       (define parts (interpolation-parts expression))
       (define (lower-part! part slot)
         (cond
           [(string? part) (emit! 'const (list slot part) span)]
           [else
            (lower-expression part slot)
            (unless (eq? (static-type part) 'String)
              (emit! 'to-text (list slot slot) span))]))
       (cond
         [(null? parts) (emit! 'const (list dst "") span)]
         [else
          (lower-part! (car parts) dst)
          (for ([part (in-list (cdr parts))])
            (define slot (alloc!))
            (lower-part! part slot)
            (emit! 'concat (list dst dst slot) span)
            (set! next slot))])
       (set! next (if want saved (add1 dst)))
       dst]
      [(function-ref? expression)
       (emit! 'step '() span)
       (lower-closure (hash-ref function-index (function-ref-name expression)) '() span want)]
      [(block-lit? expression)
       (emit! 'step '() span)
       (define captured
         (for/list ([name (in-list (referenced-names (block-lit-body expression)))]
                    #:when (lookup name))
           name))
       (define index
         (new-block!
          (lambda ()
            (lower-function (format "block@~a:~a" (block-file span) (span-text span))
                            (map block-param-name (block-lit-params expression))
                            captured
                            (block-lit-body expression)
                            span
                            #t
                            env))))
       (lower-closure index (map lookup captured) span want)]
      [(invoke? expression)
       (emit! 'step '() span)
       (define saved next)
       (define base (alloc!))
       (lower-expression (invoke-target expression) base)
       (for ([argument (in-list (invoke-args expression))] [index (in-naturals 1)])
         (set! next (+ base index))
         (lower-expression argument (alloc!)))
       (emit! 'call-value (list base (length (invoke-args expression))) span)
       (cond
         [want (emit! 'move (list want base) span)
               (set! next saved)
               want]
         [else (set! next (add1 base)) base])]
      [else (unsupported "this expression" span)]))

  (define (lower-closure index slots span want)
    (if (and want (<= (length slots) 1))
        (lower-closure-into index slots span want)
        (lower-closure-window index slots span want)))

  (define (lower-closure-into index slots span want)
    (for ([slot (in-list slots)])
      (emit! 'move (list want slot) span))
    (emit! 'closure (list want index) span)
    want)

  (define (lower-closure-window index slots span want)
    (define saved next)
    (define base (alloc!))
    (for ([slot (in-list slots)] [k (in-naturals)])
      (emit! 'move (list (if (zero? k) base (alloc!)) slot) span))
    (emit! 'closure (list base index) span)
    (cond
      [want (emit! 'move (list want base) span)
            (set! next saved)
            want]
      [else (set! next (add1 base)) base]))

  (define (lower-list expression want)
    (define span (list-lit-span expression))
    (emit! 'step '() span)
    (define saved next)
    (define elements (list-lit-elements expression))
    (define (lower-elements! items)
      (define start next)
      (for ([element (in-list items)])
        (lower-expression element (alloc!) #:known? #t))
      start)
    (define dst
      (cond
        [(<= (length elements) max-list-chunk)
         (define dst (target want))
         (define start (lower-elements! elements))
         (emit! 'list (list dst (if (null? elements) dst start) (length elements)) span)
         dst]
        [else
         (define base (alloc!))
         (let loop ([items elements] [first? #t])
           (define-values (chunk rest)
             (if (> (length items) max-list-chunk)
                 (split-at items max-list-chunk)
                 (values items '())))
           (set! next (add1 base))
           (define start (lower-elements! chunk))
           (cond
             [first? (emit! 'list (list base start (length chunk)) span)]
             [else
              (emit! 'list (list start start (length chunk)) span)
              (emit! 'call-builtin (list base "List.concat" 2) span span span)])
           (unless (null? rest) (loop rest #f)))
         (cond
           [want (emit! 'move (list want base) span) want]
           [else base])]))
    (set! next (if want saved (add1 dst)))
    dst)

  (define (lower-map expression want)
    (define span (node-span expression))
    (emit! 'step '() span)
    (define saved next)
    (define entries (map-lit-entries expression))
    (define (lower-entry! entry)
      (lower-expression (map-entry-key entry) (alloc!) #:known? #t)
      (lower-expression (map-entry-value entry) (alloc!) #:known? #t))
    (define dst
      (cond
        [(<= (length entries) max-map-chunk)
         (define dst (target want))
         (define start next)
         (for-each lower-entry! entries)
         (emit! 'map (list dst (if (null? entries) dst start) (length entries)) span)
         dst]
        [else
         (define base (alloc!))
         (define-values (chunk rest) (split-at entries max-map-chunk))
         (define start next)
         (for-each lower-entry! chunk)
         (emit! 'map (list base start (length chunk)) span)
         (for ([entry (in-list rest)])
           (set! next (add1 base))
           (lower-entry! entry)
           (emit! 'call-builtin (list base "Map.put" 3) span span span span))
         (cond
           [want (emit! 'move (list want base) span) want]
           [else base])]))
    (set! next (if want saved (add1 dst)))
    dst)

  (define (lower-enum enum-name variant-name arguments span want)
    (emit! 'step '() span)
    (define saved next)
    (define dst (target want))
    (define id (hash-ref variant-ids (cons enum-name variant-name)))
    (define start next)
    (for ([argument (in-list arguments)])
      (lower-expression argument (alloc!)))
    (emit! 'enum (list dst (if (null? arguments) dst start) id) span)
    (set! next (if want saved (add1 dst)))
    dst)

  (define (lower-struct expression want)
    (define span (construct-span expression))
    (match-define (cons index fields) (hash-ref struct-info (construct-type-name expression)))
    (emit! 'step '() span)
    (define saved next)
    (define dst (target want))
    (define start next)
    (for ([_ (in-list fields)]) (alloc!))
    (define after next)
    (for ([argument (in-list (construct-args expression))])
      (lower-expression (named-arg-value argument)
                        (+ start (index-of fields (named-arg-name argument))))
      (set! next after))
    (emit! 'struct (list dst (if (null? fields) dst start) index) span)
    (set! next (if want saved (add1 dst)))
    dst)

  (define (lower-binary expression want)
    (emit! 'step '() (binary-span expression))
    (define op (binary-op expression))
    (define op-span (binary-op-span expression))
    (define saved next)
    (define dst (target want))
    (cond
      [(memq op '(dot-dot dot-dot-dot))
       (define window (alloc!))
       (lower-expression (binary-left expression) window)
       (lower-expression (binary-right expression) (alloc!))
       (emit! 'range (list dst window (if (eq? op 'dot-dot-dot) 1 0)) op-span)]
      [(memq op '(and or))
       (define end (new-label!))
       (lower-expression (binary-left expression) dst)
       (emit! (if (eq? op 'and) 'jump-if-false 'jump-if-true) (list dst end) op-span)
       (lower-expression (binary-right expression) dst)
       (place! end)]
      [else
       (define ops (case (type-of (binary-left expression))
                     [(Float) float-ops]
                     [(String) string-ops]
                     [else int-ops]))
       (define left (lower-expression (binary-left expression) #f))
       (define right (lower-expression (binary-right expression) #f))
       (case op
         [(equal not-equal)
          (emit! (if (eq? op 'equal) 'eq 'ne) (list dst left right) op-span)]
         [(greater greater-equal)
          (emit! (hash-ref ops op) (list dst right left) op-span)]
         [else (emit! (hash-ref ops op) (list dst left right) op-span)])])
    (set! next (if want saved (add1 dst)))
    dst)

  (define (tail-call? expression)
    (and (call? expression)
         (not (builtin-ref (call-name expression) (length (call-args expression))))))

  (define (lower-call expression want void? #:checked? [checked? #f] #:tail? [tail? #f])
    (define name (call-name expression))
    (define arguments (call-args expression))
    (define span (call-span expression))
    (define entry (builtin-ref name (length arguments)))
    (define key (and entry (builtin-implementation entry)))
    (define builtin? (and key (member key vm-builtins) #t))
    (when (and entry (not builtin?))
      (unsupported (format "the builtin ~a" name) span))
    (unless (or builtin? (hash-has-key? function-index name))
      (unsupported (format "the call to ~a" name) span))
    (unless checked?
      (require-type! expression void?))
    (emit! 'step '() span)
    (define saved next)
    (define base (alloc!))
    (for ([argument (in-list arguments)] [index (in-naturals)])
      (set! next (+ base index))
      (define slot (alloc!))
      (lower-expression argument slot))
    (cond
      [builtin?
       (apply emit! 'call-builtin (list base key (length arguments)) span (map node-span arguments))]
      [else (emit! (if tail? 'tail-call 'call) (list base (hash-ref function-index name)) span)])
    (when (and tail? builtin?)
      (emit! 'return (list base) span))
    (cond
      [want (emit! 'move (list want base) span)
            (set! next saved)
            want]
      [else (set! next (add1 base)) base]))

  (define (lower-block statements)
    (for ([statement (in-list statements)])
      (lower-statement statement)))

  (define (lower-statement statement)
    (define span (node-span statement))
    (define saved next)
    (emit! 'step '() span)
    (when after-step
      (define hook after-step)
      (set! after-step #f)
      (hook))
    (cond
      [(binding? statement)
       (define name (binding-name statement))
       (define existing (lookup name))
       (cond
         [existing
          (define slot (lower-expression (binding-value statement) #f))
          (unless (= slot existing)
            (emit! 'move (list existing slot) span))
          (set! next saved)]
         [else
          (define slot (alloc!))
          (lower-expression (binding-value statement) slot)
          (hash-set! (car scopes) name slot)])]
      [(return-stmt? statement)
       (define value (return-stmt-value statement))
       (cond
         [(and value (tail-call? value)) (lower-call value #f #t #:tail? #t)]
         [else
          (define slot
            (cond
              [value (lower-expression value #f #:void? #t)]
              [else (define slot (alloc!)) (emit! 'const (list slot (void)) span) slot]))
          (emit! 'return (list slot) span)])
       (set! next saved)]
      [(expr-stmt? statement)
       (lower-expression (expr-stmt-value statement) #f #:void? #t)
       (set! next saved)]
      [(if-stmt? statement)
       (define end (new-label!))
       (define branches (if-stmt-branches statement))
       (define else-body (if-stmt-else-body statement))
       (for ([branch (in-list branches)] [index (in-naturals 1)])
         (define skip (new-label!))
         (define condition (lower-expression (if-branch-condition branch) #f))
         (emit! 'jump-if-false (list condition skip) (node-span (if-branch-condition branch)))
         (set! next saved)
         (scoped (lambda () (lower-block (if-branch-body branch))))
         (when (or else-body (< index (length branches)))
           (emit! 'jump (list end) span))
         (place! skip))
       (when else-body
         (scoped (lambda () (lower-block else-body))))
       (place! end)]
      [(while-stmt? statement)
       (define head (new-label!))
       (define exit (new-label!))
       (place! head)
       (define condition (lower-expression (while-stmt-condition statement) #f))
       (emit! 'jump-if-false (list condition exit) (node-span (while-stmt-condition statement)))
       (set! next saved)
       (define outer loop-labels)
       (set! loop-labels (cons head exit))
       (scoped (lambda () (lower-block (while-stmt-body statement))))
       (set! loop-labels outer)
       (emit! 'jump (list head) span)
       (place! exit)]
      [(and (loop-control? statement) loop-labels)
       (emit! 'jump (list (if (eq? (loop-control-kind statement) 'break)
                              (cdr loop-labels)
                              (car loop-labels)))
              span)]
      [(and (for-stmt? statement) (eq? (static-type (for-stmt-iterable statement)) 'Range))
       (lower-range-for statement span)
       (set! next saved)]
      [(for-stmt? statement)
       (define body (for-stmt-body statement))
       (define items (alloc!))
       (lower-expression (for-stmt-iterable statement) items)
       (unless (null? body)
         (define index (alloc!))
         (define count (alloc!))
         (define temp (alloc!))
         (define one (alloc!))
         (define top (new-label!))
         (define increment (new-label!))
         (define test (new-label!))
         (define exit (new-label!))
         (emit! 'const (list index 0) span)
         (emit! 'list-len (list count items) span)
         (emit! 'const (list one 1) span)
         (emit! 'jump (list test) span)
         (define outer loop-labels)
         (set! loop-labels (cons increment exit))
         (scoped (lambda ()
                   (define element (alloc!))
                   (hash-set! (car scopes) (for-stmt-var statement) element)
                   (place! top)
                   (set! after-step (lambda () (emit! 'list-get (list element items index) span)))
                   (lower-block body)
                   (when after-step (error 'lower "for body did not read its element"))))
         (set! loop-labels outer)
         (place! increment)
         (emit! 'add-i (list index index one) span)
         (place! test)
         (emit! 'lt-i (list temp index count) span)
         (emit! 'jump-if-true (list temp top) span)
         (place! exit))
       (set! next saved)]
      [(case-stmt? statement)
       (define scrutinee-type (static-type (case-stmt-value statement)))
       (define value (lower-expression (case-stmt-value statement) #f))
       (define end (new-label!))
       (define arms (case-stmt-arms statement))
       (for ([arm (in-list arms)] [index (in-naturals 1)])
         (define pattern (case-arm-pattern arm))
         (define pattern-span (node-span pattern))
         (define skip (new-label!))
         (define test-slot next)
         (cond
           [(wildcard-pattern? pattern) (void)]
           [(literal-pattern? pattern)
            (define literal (literal-pattern-value pattern))
            (cond
              [(and (exact-integer? literal) (not (<= int-min literal int-max)))
               (emit! 'jump (list skip) pattern-span)]
              [else
               (define slot (alloc!))
               (emit! 'const (list slot literal) pattern-span)
               (emit! 'same (list slot value slot) pattern-span)
               (emit! 'jump-if-false (list slot skip) pattern-span)])]
           [(result-type? scrutinee-type)
            (define slot (alloc!))
            (emit! 'is-ok (list slot value) pattern-span)
            (emit! (if (equal? (variant-pattern-variant-name pattern) "Ok") 'jump-if-false 'jump-if-true)
                   (list slot skip) pattern-span)]
           [else
            (define id (hash-ref variant-ids (cons (variant-pattern-enum-name pattern)
                                                   (variant-pattern-variant-name pattern))))
            (define slot (alloc!))
            (emit! 'is-variant (list slot value id) pattern-span)
            (emit! 'jump-if-false (list slot skip) pattern-span)])
         (set! next test-slot)
         (scoped (lambda ()
                   (when (variant-pattern? pattern)
                     (for ([name (in-list (variant-pattern-bindings pattern))] [item (in-naturals)]
                           #:when name)
                       (define slot (alloc!))
                       (hash-set! (car scopes) name slot)
                       (if (result-type? scrutinee-type)
                           (emit! 'result-value (list slot value) pattern-span)
                           (emit! 'payload (list slot value item) pattern-span))))
                   (lower-block (case-arm-body arm))))
         (when (< index (length arms))
           (emit! 'jump (list end) span))
         (place! skip))
       (place! end)
       (set! next saved)]
      [else (unsupported "this statement" span)]))

  (define (lower-range-for statement span)
    (define iterable (for-stmt-iterable statement))
    (define body (for-stmt-body statement))
    (define bounds (alloc!))
    (define last-slot (alloc!))
    (define nonempty (alloc!))
    (define literal? (and (binary? iterable) (memq (binary-op iterable) '(dot-dot dot-dot-dot)) #t))
    (define exclusive? (and literal? (eq? (binary-op iterable) 'dot-dot-dot)))
    (cond
      [literal?
       (emit! 'step '() (binary-span iterable))
       (lower-expression (binary-left iterable) bounds)
       (lower-expression (binary-right iterable) last-slot)
       (emit! (if exclusive? 'lt-i 'le-i) (list nonempty bounds last-slot) span)]
      [else
       (define source (lower-expression iterable #f))
       (emit! 'range-bounds (list bounds source) span)])
    (define exit (new-label!))
    (define top (new-label!))
    (define increment (new-label!))
    (define one (alloc!))
    (define temp (alloc!))
    (emit! 'jump-if-false (list nonempty exit) span)
    (emit! 'const (list one 1) span)
    (when exclusive?
      (emit! 'sub-i (list last-slot last-slot one) span))
    (define outer loop-labels)
    (set! loop-labels (cons increment exit))
    (scoped (lambda ()
              (hash-set! (car scopes) (for-stmt-var statement) bounds)
              (place! top)
              (emit! 'step '() span)
              (lower-block body)))
    (set! loop-labels outer)
    (place! increment)
    (emit! 'eq (list temp bounds last-slot) span)
    (emit! 'jump-if-true (list temp exit) span)
    (emit! 'add-i (list bounds bounds one) span)
    (emit! 'jump (list top) span)
    (place! exit))

  (for ([parameter (in-list parameter-names)])
    (hash-set! (car scopes) parameter (alloc!)))
  (define params next)
  (unless (null? capture-names)
    (define captures (make-hash))
    (for ([capture (in-list capture-names)])
      (hash-set! captures capture (alloc!)))
    (set! scopes (list (car scopes) captures)))
  (define final
    (and block? (pair? statements) (expr-stmt? (last statements)) (last statements)))
  (cond
    [final
     (lower-block (drop-right statements 1))
     (define final-span (node-span final))
     (emit! 'step '() final-span)
     (define slot (lower-expression (expr-stmt-value final) #f #:void? #t))
     (emit! 'return (list slot) final-span)]
    [else
     (lower-block statements)
     (define void-slot (alloc!))
     (emit! 'const (list void-slot (void)) function-span)
     (emit! 'return (list void-slot) function-span)])
  (ir-function name params (length capture-names) high (reverse code) function-span))

(define (block-file span)
  (define-values (_ file __) (split-path (source-name (source-span-source span))))
  (path->string file))

(define (span-text span)
  (define start (source-span-start span))
  (format "~a:~a" (source-position-line start) (source-position-column start)))

(define (format-arg op index value)
  (cond
    [(and (eq? op 'const) (= index 1))
     (cond [(void? value) "void"] [else (format "~s" value)])]
    [(and (memq op '(jump jump-if-false jump-if-true))
          (= index (if (eq? op 'jump) 0 1)))
     (format "L~a" value)]
    [(and (memq op '(call tail-call closure)) (= index 1)) (format "fn~a" value)]
    [(and (eq? op 'call-value) (= index 1)) (format "~a" value)]
    [(and (memq op '(enum is-variant)) (= index 2)) (format "v~a" value)]
    [(and (eq? op 'struct) (= index 2)) (format "s~a" value)]
    [(and (memq op '(field payload)) (= index 2)) (format "~a" value)]
    [(and (memq op '(list map)) (= index 2)) (format "~a" value)]
    [(and (eq? op 'range) (= index 2)) (if (= value 1) "..." "..")]
    [(and (eq? op 'call-builtin) (>= index 1)) (format "~a" value)]
    [else (format "r~a" value)]))

(define (format-tables ir)
  (define structs
    (for/list ([entry (in-list (ir-program-structs ir))] [index (in-naturals)])
      (format "struct s~a ~a~a" index (ir-struct-name entry)
              (string-append*
               (for/list ([field (in-list (ir-struct-fields entry))])
                 (format " ~a" field))))))
  (define enums
    (let loop ([entries (ir-program-enums ir)] [id 0] [out '()])
      (cond
        [(null? entries) (reverse out)]
        [else
         (define variants (ir-enum-variants (car entries)))
         (loop (cdr entries) (+ id (length variants))
               (cons (format "enum ~a~a" (ir-enum-name (car entries))
                             (string-append*
                              (for/list ([variant (in-list variants)] [k (in-naturals id)])
                                (format " v~a=~a/~a" k (car variant) (cdr variant)))))
                     out))])))
  (append structs enums))

(define (format-ir ir)
  (define tables (format-tables ir))
  (string-append
   (if (null? tables) "" (string-append (string-join tables "\n") "\n\n"))
   (format-functions ir)))

(define (format-functions ir)
  (string-join
   (for/list ([function (in-list (ir-program-functions ir))] [index (in-naturals)])
     (string-join
      (cons (format "fn~a ~a params=~a~a slots=~a~a" index (ir-function-name function)
                    (ir-function-params function)
                    (if (zero? (ir-function-captures function))
                        ""
                        (format " captures=~a" (ir-function-captures function)))
                    (ir-function-slots function)
                    (if (= index (ir-program-entry ir)) " entry" ""))
            (for/list ([item (in-list (ir-function-body function))])
              (cond
                [(ir-label? item) (format "  L~a:" (ir-label-id item))]
                [else
                 (define op (ir-instr-op item))
                 (format "    ~a~a  @ ~a" op
                         (string-append*
                          (for/list ([arg (in-list (ir-instr-args item))] [i (in-naturals)])
                            (string-append " " (format-arg op i arg))))
                         (string-join (map span-text (ir-instr-spans item)) " "))])))
      "\n"))
   "\n\n"))
