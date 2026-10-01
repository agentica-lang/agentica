# Agentica: gramática futura

Estado: propuesta. Nada de este documento está implementado ni es normativo. El lenguaje que ejecuta el intérprete está en [`grammar.md`](grammar.md).

Regla de trabajo: cuando una fase del [`roadmap.md`](roadmap.md) termina, su sintaxis se mueve de este documento a las secciones 4–6 de `grammar.md`, y se borra de aquí.

## 1. Cambios planeados a la biblioteca actual

- `IO.gets() -> Result[String]` y `IO.gets!() -> String`. Hoy `IO.gets` devuelve `String` y falla con `RUNTIME-END-OF-INPUT`; el cambio se cierra en la fase 5d2 para no enseñar una forma que 5e rompería.
- `CHECK-EMPTY-MAP-TYPE` para un `{}` sin tipo esperado. Hoy usa `CHECK-EMPTY-LIST-TYPE`.
- Las formas sin `!` de `String.to_int` y `String.to_float` devuelven `Result[...]` (fase 5e).

## 2. Enums y pattern matching

Esta sección documenta la dirección ya discutida. No pertenece al núcleo inicial y requiere ampliar lexer, parser, checker y evaluador.

```ruby
enum Result[T, E]
  Ok(T)
  Err(E)
end

enum Option[T]
  Some(T)
  None
end

def label(result: Result[String, String]) -> String
  case result
  in Ok(value)
    return value
  in Err(error)
    return error
  end
end
```

Propuesta de extensión EBNF, que se añade a las alternativas de declaraciones e instrucciones:

```ebnf
enum_decl        = "enum", TYPE_NAME, [ type_parameters ], NL,
                   variant_decl, { variant_decl }, "end", NL ;
type_parameters  = "[", TYPE_NAME, { ",", TYPE_NAME }, "]" ;
variant_decl     = TYPE_NAME,
                   [ "(", type, { ",", type }, ")" ], NL ;

case_statement   = "case", expression, NL,
                   match_arm, { match_arm }, "end", NL ;
match_arm        = "in", pattern, NL, block ;
pattern          = "_"
                 | INTEGER | FLOAT | STRING | "true" | "false" | "nil"
                 | "-", INTEGER | "-", FLOAT
                 | TYPE_NAME, [ "(", pattern_bindings, ")" ] ;
pattern_bindings = NAME, { ",", NAME } ;
```

`_` es un wildcard que no introduce una variable. En el primer matching solo se permiten literales y variantes con bindings directos: sin patrones anidados, guards, regex ni patrones de listas. `case` sigue siendo una instrucción, no una expresión.

El checker verifica exhaustividad para enums: deben cubrirse todas las variantes o existir un wildcard final. Para dominios abiertos como enteros y strings exige wildcard. Los bindings son locales a cada rama; las ramas se prueban en orden y las inalcanzables se diagnostican.

La gramática de expresiones también debe ampliarse para construir variantes, por ejemplo `Ok(value)` y `None`. Antes de implementar esta extensión debe decidirse la resolución de nombres: cualificación de variantes, colisiones con structs y cómo inferir parámetros de tipo que no aparecen en el payload. El núcleo no resuelve esas decisiones por anticipado.

`Point(x: 0, y:)` se discutió como posibilidad, pero queda aplazado: este primer matching no incluye patrones de structs ni abreviaturas de campos.

## 3. Extensiones sin gramática normativa

| Extensión | Dirección | Decisiones pendientes |
|---|---|---|
| Interpolación | `"Hola #{user.name}"` | Escapes, expresiones admitidas y conversión a texto |
| Propagación de errores | `value = try find_user(42)` | Fase 5e: `try` devuelve el error de la función actual, que debe devolver `Result[...]` |
| Generics de funciones | Reutilizar funciones con tipos distintos | Sintaxis, inferencia y restricciones |
| Closures y métodos | Mejor ergonomía | Captura, representación y resolución |
| Módulos | Separar programas en archivos | Importación, visibilidad y ciclos |
| FFI C | Wrappers seguros sobre llamadas nativas | Punteros, ownership, ABI y llamadas desde el intérprete |
| Async y fibers | Suspender ejecución en I/O; inicialmente un thread | API, cancelación y propagación de errores |
| Actores | Mensajes y mailboxes propios | Sintaxis, aislamiento, valores compartidos y supervisión |

## 4. Biblioteca estándar y funciones como valores (fases 5e–5m)

Se fija aquí para que cada fase del roadmap la tome como especificación.

```ebnf
postfix_expr     = primary, { ".", NAME
                            | ".", "call", "(", [ arguments ], ")"
                            | "[", expression, "]" } ;

primary          = (* …formas del núcleo, más: *)
                 | "&", NAME
                 | TYPE_NAME ;
```

- **`&nombre` y `.call(...)`:** `&nombre` convierte una función de nivel superior en un valor de tipo `Fn[...]`, y `valor.call(args)` lo invoca. `call` no es palabra reservada: solo tiene este significado justo después de un `.` y antes de `(`. No hay closures: `&nombre` no captura variables. El checker exige que `nombre` sea una función declarada y compara parámetros y retorno con el tipo esperado. Precedencia 1, como la llamada nombrada.
- **`TYPE_NAME` solo:** sin `(` ni `.`, es un tipo usado como argumento, como en `JSON.decode(text, User)`. El checker lo acepta únicamente como argumento de las funciones incorporadas que lo piden (`JSON.decode`, `JSON.schema`); en cualquier otro lugar es un error.
- **Tipos:** `Fn[A, ..., R]` (los tipos finales son el retorno, fase 5j), `Result[T]` (error siempre `String`), `Json`, `Socket`, `Listener`, `Process` y `Response` (struct incorporado con `status`, `body` y `headers`). Los tipos opacos no se pueden construir ni inspeccionar, solo pasar a las funciones incorporadas.
- **Nombres reservados al empezar cada fase:** `Fn`, `Result`, `Json`, `Socket`, `Listener`, `Process`, `Response`, `JSON`, `TCP` y `HTTP`.

```ruby
def double(n: Int) -> Int
  return n * 2
end

def main() -> Nil
  f: Fn[Int, Int] = &double
  puts(String.from_int(f.call(21)))
  if String.contains?("agentica", "gent")
    puts("found")
  end
end
```

Programas que esa fase debe rechazar:

```ruby
x = User               # Un tipo solo es válido como argumento de JSON.decode o JSON.schema.
f = &missing           # &nombre exige una función declarada.
ok = done?             # El sufijo ? solo existe seguido de "(".
```

## 5. Runtime nativo

Para un runtime nativo posterior se ha planteado C++20 procedural, structs y funciones libres, Boehm GC y, más adelante, libevent. Esas decisiones no forman parte de la gramática ni deben aparecer en los programas Agentica.

La integración del host C++ con una librería C no resuelve por sí sola el FFI de Agentica: un intérprete necesita wrappers nativos o una capa de llamadas que respete el ABI. Tampoco incluir libevent proporciona automáticamente fibers o actores.

No se introducen de momento interfaces, traits, herencia, JIT, distribución ni paralelismo. La semántica del lenguaje debe conservarse al cambiar el evaluador de AST por una VM futura.
