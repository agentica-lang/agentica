## 4. Standard library and function values (phases 5f2–5m)

Built. The contract is the grammar (function values, blocks, typed JSON,
builders and schemas, file imports and exports) and the programming reference.
Two built rules are not stated there yet and stay here until they move:

- `call` is not a reserved word: it has the meaning of a function-value call
  only right after a `.` and before `(`.
- Opaque handles have no constructor or fields; `inspect` prints a type marker.
