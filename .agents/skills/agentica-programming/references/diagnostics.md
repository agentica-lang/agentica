# Diagnostics

`CHECK-VOID-TYPE` rejects Void in a data type position; `CHECK-VOID-VALUE` rejects using completion as data. Process ownership and explicit cleanup diagnostics are `RUNTIME-PROCESS-CONTEXT` and `RUNTIME-PROCESS-CLOSE` at the call span. Expected process failures return error Results.

A failure prints to stderr and exits 1 (the run stops at the first error):

```text
file.agc:2:14 error[CHECK-TYPE-MISMATCH]
expected Int, found String

2 |   age: Int = "25"
  |              ^^^^
```

The code prefix is the stage: `LEX-` (characters), `PARSE-` (syntax), `CHECK-` (names and types, before running), `RUNTIME-` (while running).

| Code | Meaning |
|---|---|
| `LEX-UNEXPECTED-CHAR`, `LEX-UNTERMINATED-STRING`, `LEX-INVALID-ESCAPE`, `LEX-UNCLOSED-DELIMITER`, `LEX-UNMATCHED-DELIMITER` | bad character, string, or bracket |
| `PARSE-UNEXPECTED-TOKEN` | the parser expected something else here |
| `PARSE-UNCLOSED-BLOCK` | missing `end` |
| `PARSE-MISSING-BLANK-LINE` | no blank line between the `end` of a declaration and the next one |
| `PARSE-TOP-LEVEL-STATEMENT` | a statement outside a function |
| `PARSE-CHAINED-COMPARISON` | `a < b < c` |
| `PARSE-INVALID-ASSIGNMENT-TARGET` | assignment to an index or field |
| `CHECK-TYPE-MISMATCH` | a value, operand, condition, argument, or return has the wrong type |
| `CHECK-UNKNOWN-NAME`, `CHECK-UNKNOWN-TYPE`, `CHECK-UNKNOWN-FIELD` | a name, type, or field that does not exist |
| `CHECK-REDEFINED-NAME`, `CHECK-SHADOWED-NAME`, `CHECK-ANNOTATION-ON-EXISTING` | duplicate declaration, shadowing, annotation on an existing name |
| `CHECK-ARITY` | wrong number of arguments |
| `CHECK-MISSING-FIELD`, `CHECK-DUPLICATE-FIELD` | struct construction fields |
| `CHECK-EMPTY-LIST-TYPE`, `CHECK-EMPTY-MAP-TYPE` | an empty `[]` or `{}`, respectively, with no expected type |
| `CHECK-RESULT-TYPE` | an error constructor without an expected Result type |
| `CHECK-TRY-CONTEXT` | try in a function not returning Result |
| `CHECK-MISSING-RETURN` | a path without `return` in a non-`Void` function |
| `CHECK-MAIN` | missing or wrong `main` |
| `CHECK-NOT-A-STRUCT`, `CHECK-NOT-INDEXABLE`, `CHECK-NOT-A-LIST` | field access on a non-struct, index on a non-list/map, `for` over a non-list |
| `CHECK-MAP-KEY-TYPE` | a map key that is not `Int` or `String` |
| `CHECK-IMPORT-IO`, `CHECK-IMPORT-PATH`, `CHECK-IMPORT-CYCLE`, `CHECK-IMPORT-NAME` | Missing/unreadable import, invalid path, cycle, or unknown/private imported name |
| `CHECK-MODULE-CONTEXT` | Raw import/export declarations need module resolution before checking |
| `CHECK-NOT-DECODABLE` | JSON.decode/schema target is not a struct or contains unsupported field types |
| `CHECK-NOT-ENCODABLE` | JSON.encode on a type with unsupported nested values or Int-keyed maps |
| `CHECK-IMMUTABLE-ASSIGNMENT` | assignment to a `for` variable |
| `CHECK-INT-RANGE` | an integer literal that does not fit in `Int` |
| `CHECK-UNKNOWN-METHOD` | method not defined for the receiver's type, or a method call on a struct |
| `CHECK-UNUSED-VALUE` | result of a builtin without effects is ignored (`xs.push(1)` alone) |
| `CHECK-BLOCK-TYPE` | a block parameter has no type from the call; annotate it (`do |x: Int|`) |
| `CHECK-BLOCK-TARGET` | a block is passed to a function whose last parameter is not a `Fn` |
| `CHECK-LOOP-CONTROL` | `break` or `next` outside a `while`/`for` body, or inside a block |
| `CHECK-CAPTURED-ASSIGNMENT` | a block assigns to an outer variable; use `reduce` or a `for` loop |
| `RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-INTEGER-OVERFLOW` | arithmetic failure |
| `RUNTIME-INDEX-OUT-OF-RANGE`, `RUNTIME-KEY-NOT-FOUND` | list index or map key not present |
| `RUNTIME-INVALID-COUNT` | List.repeat count outside 0..1048576, or negative List.take/drop count |
| `RUNTIME-INVALID-NUMBER` | `String.to_int!` / `String.to_float!` on bad text, `Float.to_int!` on NaN or infinity |
| `RUNTIME-INVALID-RANGE` | `Random.int` with `min > max` |
| `RUNTIME-INVALID-CHARACTER` | `String.code` without exactly one character, or `String.from_code` outside Unicode scalar values |
| `RUNTIME-END-OF-INPUT` | `IO.gets!` with no input left |
| `RUNTIME-UNWRAP-ERROR` | Result.unwrap! on an error |
| `RUNTIME-JSON-ENCODE` | JSON.encode cannot represent a non-finite Float |
| `RUNTIME-STEP-LIMIT` | execution step budget exhausted |
| `RUNTIME-STACK-OVERFLOW` | recursion too deep |
