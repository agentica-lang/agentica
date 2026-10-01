# Agentica implementation roadmap

This roadmap turns the core specification in [`Agentica-gramatica.md`](Agentica-gramatica.md) into a usable interpreter. Keep every phase focused on the core in sections 4–6 until the prototype can run and diagnose the examples in sections 9–10. Enums and other extensions stay out of the initial milestone.

## Phase 1: Source handling and lexer

- [ ] Read UTF-8 `.agc` source files and preserve file, line, and column positions.
- [ ] Normalize CRLF, emit one `NL` per newline sequence outside delimiters, and add a final `NL` when needed.
- [ ] Tokenize identifiers, reserved words, integer and float literals, strings and escapes, comments, delimiters, and operators.
- [ ] Report lexical errors with source locations and stable error codes.

**Complete when:** lexer output and spans are inspectable, and malformed characters or strings produce Agentica diagnostics.

## Phase 2: AST and parser

- [ ] Define AST nodes for declarations, statements, types, and expressions; retain source spans.
- [ ] Parse top-level function and struct declarations, parameters, fields, and type applications.
- [ ] Parse bindings, returns, `if`/`elsif`/`else`, `while`, and `for` blocks, using `end` rather than indentation.
- [ ] Parse literals, lists, named struct construction, function calls, fields, indexes, grouping, and operators with the specified precedence and associativity.
- [ ] Reject chained comparisons, executable top-level statements, and syntax outside the core grammar.
- [ ] Report syntax errors with locations and stable error codes.

**Complete when:** the valid examples in section 10 parse, and invalid syntax is rejected without exposing host parser errors.

## Phase 3: Name resolution and type checking

- [ ] Register structs and functions before checking bodies so forward calls and recursion work.
- [ ] Check primitive, struct, and `List[T]` types; infer local variable types and require an expected type for empty lists.
- [ ] Enforce operator operand types, boolean conditions, call arity, constructor fields, and field/index access rules.
- [ ] Implement lexical block scopes, assignment updates, immutable types, and the no-shadowing rule.
- [ ] Check return types and require every reachable path in non-`Nil` functions to return.
- [ ] Require exactly one `main() -> Nil` with no parameters and reserve `puts`.

**Complete when:** valid programs pass, the rejected examples in section 10 fail for the intended reason, and each failure points to its source.

## Phase 4: Core evaluator

- [ ] Evaluate expressions and arguments left to right; implement short-circuit `and` and `or`.
- [ ] Execute scoped blocks, assignments, returns, conditionals, loops, and `for` over lists.
- [ ] Evaluate function calls, structs, fields, lists, and indexes according to the checked types.
- [ ] Implement numeric rules, integer overflow checks, division and modulo behavior, zero-division errors, and list bounds errors.
- [ ] Implement `puts(value: String) -> Nil` and start each program by calling `main()`.
- [ ] Convert runtime failures into Agentica diagnostics rather than host tracebacks.

**Complete when:** the section 10 programs that pass checking execute with the specified results and runtime errors are located in the source.

## Phase 5: CLI and diagnostic quality

- [ ] Run `.agc` files through the lexer, parser, checker, and evaluator from the command line.
- [ ] Show stable error codes, file, line, column, a concrete explanation, and a source excerpt with a caret.
- [ ] Cover syntax, unknown names, type mismatches, arity, struct fields, missing returns, and runtime errors with focused examples.
- [ ] Check every valid and invalid example in the grammar against the interpreter.

**Complete when:** a user can run the sample from the README and get useful diagnostics for the grammar's required failure cases.

## Phase 6: Validate the language design

- [ ] Ask agents to write and repair small programs using only the grammar and examples.
- [ ] Record correct programs, repair attempts, and whether diagnostics helped identify the fix.
- [ ] Use the results to revise the grammar and examples explicitly before adding exceptions to the implementation.

**Complete when:** the prototype provides evidence about whether Agentica's syntax and diagnostics help agents write and repair programs.

## Later extensions

- [ ] Decide variant name resolution and generic inference before implementing enums and pattern matching.
- [ ] Add enum construction, `case`/`in`, exhaustiveness checks, and unreachable-arm diagnostics as one extension across lexer, parser, checker, evaluator, and diagnostics.
- [ ] Define normative designs for modules, interpolation, error propagation, generics, methods, FFI, async, or actors before implementing them.

These items are deliberately outside the initial core milestone.
