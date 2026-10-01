# Agentica: gramática y diseño del lenguaje

Estado: implementada por el intérprete en Racket (`src/`). Este documento describe solo lo que el intérprete acepta; la sintaxis planeada está en [`future.md`](future.md).

## 1. Qué queremos validar

Agentica es un lenguaje pensado para que agentes de IA puedan escribir, leer y corregir programas con facilidad. La prioridad es experimentar con la sintaxis, las reglas y los diagnósticos. El rendimiento, la concurrencia y el runtime definitivo se abordarán después.

La dirección es KISS: una sintaxis cercana a Ruby, tipos estáticos, inferencia local y pocas formas de expresar cada operación. Esta especificación no depende del lenguaje en que se implemente el intérprete.

## 2. Decisiones de diseño

| Aspecto | Regla |
|---|---|
| Sintaxis | `def`, `struct`, `if`, `while`, `for`, `end`; los bloques terminan con `end` |
| Tipos | Estáticos, con inferencia local donde sea evidente |
| Llamadas | Paréntesis obligatorios |
| Firmas | Retorno explícito y anotaciones obligatorias |
| Datos | Reasignación de variables; listas, maps y structs inmutables |
| Números | `Int` de 64 bits, sin conversiones implícitas |
| Nombres | Sufijo `?` (predicado) o `!` (versión que termina la ejecución) en funciones, solo seguido de `(` |
| Biblioteca | Módulos incorporados `Map`, `List`, `String`, `IO` y `System` |

Enums, `Result`, `Option`, interpolación, funciones como valores, JSON, red y otras extensiones no forman parte del lenguaje actual: están en [`future.md`](future.md).

## 3. Un programa del núcleo

```ruby
struct User
  name: String
  age: Int
end

def is_adult(user: User) -> Bool
  return user.age >= 18
end

def main() -> Nil
  users = [
    User(name: "Ana", age: 25),
    User(name: "Luis", age: 16)
  ]

  for user in users
    if is_adult(user)
      puts(user.name)
    end
  end
end
```

Los bloques terminan con `end`. La indentación mejora la lectura, pero no determina la estructura. Las llamadas usan paréntesis, incluso cuando no reciben argumentos. Los structs se construyen con campos nombrados; las funciones ordinarias reciben argumentos posicionales.

El ejecutable comienza llamando a `main()`. En el núcleo no hay instrucciones ejecutables en el nivel superior: solo declaraciones. Esto evita tener dos modelos distintos de entrada al programa.

## 4. Convenciones léxicas

- El archivo usa UTF-8; los identificadores del núcleo usan caracteres ASCII.
- Un comentario empieza con `#` y termina al final de la línea.
- Los nombres de variables, funciones y campos empiezan con minúscula o `_`.
- Los nombres de tipos empiezan con mayúscula.
- Los identificadores distinguen mayúsculas de minúsculas.
- Las palabras reservadas no pueden usarse como identificadores.
- Los espacios y tabuladores separan tokens; no tienen significado estructural.
- Un salto de línea separa instrucciones, salvo dentro de `(...)` y `[...]`.
- CRLF se normaliza a LF. Un comentario no elimina el salto de línea que lo sigue.
- El lexer emite un token `NL` por cada salto de línea fuera de delimitadores, salvo que agrupa las líneas vacías consecutivas; una línea con comentario produce su propio `NL`. El parser ignora los `NL` sobrantes entre declaraciones e instrucciones.
- Si el archivo no termina con salto de línea, el lexer añade uno antes de `EOF`.
- No se admiten `;`, continuación con barra inversa ni expresiones que continúen implícitamente tras un operador.

Por tanto, una expresión larga debe encerrarse en paréntesis. Dentro de listas y llamadas se pueden usar varias líneas y una coma final.

```ruby
total = (
  base +
  extra
)

names = [
  "Ana",
  "Luis",
]
```

Palabras reservadas del núcleo:

```text
def struct end if elsif else while for in return
true false nil and or not
```

Las extensiones futuras introducirán más palabras reservadas; no están disponibles.

El sufijo `?` o `!` solo forma parte del `NAME` cuando el carácter siguiente es `(`: `contains?(`, `to_int!(`. Así `a!=b` sigue siendo `a != b`, y `x?` o `x!` sin paréntesis no son nombres. Por convención, `?` marca un predicado que devuelve `Bool` y `!` marca la versión que termina la ejecución con error en vez de devolver un `Result`. Variables, campos y parámetros no pueden llevar el sufijo.

Los nombres de tipo y módulo `Int`, `Float`, `Bool`, `String`, `Nil`, `List`, `Map`, `IO` y `System` están reservados y no se pueden redefinir.

### Literales

```ebnf
NAME       = LOWER_OR_UNDERSCORE, { LETTER | DIGIT | "_" }, [ "?" | "!" ] ;
TYPE_NAME  = UPPER, { LETTER | DIGIT | "_" } ;
INTEGER    = DIGIT, { DIGIT } ;
FLOAT      = DIGIT, { DIGIT }, ".", DIGIT, { DIGIT } ;
STRING     = '"', { STRING_CHAR | ESCAPE }, '"' ;
ESCAPE     = "\\", ( '"' | "\\" | "n" | "r" | "t" ) ;
```

`LETTER` representa `A`–`Z` o `a`–`z`; `DIGIT`, `0`–`9`; `LOWER_OR_UNDERSCORE`, `a`–`z` o `_`; `UPPER`, `A`–`Z`. `STRING_CHAR` es cualquier carácter Unicode salvo comillas dobles, barra inversa y saltos de línea. `NL` y `EOF` son tokens producidos por el lexer.

El signo negativo es un operador, no parte del literal. El núcleo no incluye exponentes, bases alternativas, separadores numéricos, strings multilínea ni interpolación. `"#{name}"` es texto literal en esta versión.

## 5. Gramática EBNF del núcleo

Esta es una gramática descriptiva: se traducirá a la notación de la herramienta elegida. `{ X }` significa cero o más repeticiones, `[ X ]` significa opcional y `|` expresa alternativas. Los terminales aparecen entre comillas; los nombres en mayúsculas son tokens léxicos.

### Archivo y declaraciones

```ebnf
program          = [ NL ], { declaration }, EOF ;
declaration      = function_decl | struct_decl ;

function_decl    = "def", NAME, "(", [ parameters ], ")",
                   "->", type, NL, block, "end", NL ;
parameters       = parameter, { ",", parameter }, [ "," ] ;
parameter        = NAME, ":", type ;

struct_decl      = "struct", TYPE_NAME, NL,
                   { field_decl }, "end", NL ;
field_decl       = NAME, ":", type, NL ;

type             = TYPE_NAME, [ "[", type, { ",", type }, "]" ] ;
```

El parser permite aplicaciones de tipos como `List[Int]`. El checker restringe el núcleo a tipos primitivos, structs y `List[T]`: no basta con que una forma sea sintácticamente válida para que exista ese tipo. No hay parámetros de tipo declarados por el usuario en el núcleo.

Las declaraciones de structs y funciones solo aparecen en el nivel superior. No hay métodos, clases, herencia, closures ni funciones anidadas.

### Instrucciones y bloques

```ebnf
block            = { statement } ;
statement        = simple_statement, NL
                 | if_statement
                 | while_statement
                 | for_statement ;

simple_statement = binding | return_statement | expression ;
binding          = NAME, [ ":", type ], "=", expression ;
return_statement = "return", [ expression ] ;

if_statement     = "if", expression, NL, block,
                   { "elsif", expression, NL, block },
                   [ "else", NL, block ], "end", NL ;
while_statement  = "while", expression, NL, block, "end", NL ;
for_statement    = "for", NAME, "in", expression, NL,
                   block, "end", NL ;
```

Las asignaciones son instrucciones: no producen un valor. `if`, `while` y `for` tampoco son expresiones. El núcleo no incluye `break`, `continue`, asignaciones compuestas ni asignación a campos o índices.

### Expresiones y precedencia

```ebnf
expression       = or_expr ;
or_expr          = and_expr, { "or", and_expr } ;
and_expr         = equality_expr, { "and", equality_expr } ;
equality_expr    = comparison_expr,
                   [ ( "==" | "!=" ), comparison_expr ] ;
comparison_expr  = additive_expr,
                   [ ( "<" | "<=" | ">" | ">=" ), additive_expr ] ;
additive_expr    = multiplicative_expr,
                   { ( "+" | "-" ), multiplicative_expr } ;
multiplicative_expr = unary_expr,
                   { ( "*" | "/" | "%" ), unary_expr } ;
unary_expr       = ( "-" | "not" ), unary_expr | postfix_expr ;
postfix_expr     = primary, { ".", NAME | "[", expression, "]" } ;

primary          = literal
                 | NAME, [ "(", [ arguments ], ")" ]
                 | TYPE_NAME, ".", NAME, "(", [ arguments ], ")"
                 | TYPE_NAME, "(", [ named_arguments ], ")"
                 | list_literal
                 | map_literal
                 | "(", expression, ")" ;

arguments        = expression, { ",", expression }, [ "," ] ;
named_arguments  = named_argument, { ",", named_argument }, [ "," ] ;
named_argument   = NAME, ":", expression ;
list_literal     = "[", [ arguments ], "]" ;
map_literal      = "{", [ map_entry, { ",", map_entry }, [ "," ] ], "}" ;
map_entry        = expression, ":", expression ;
literal          = INTEGER | FLOAT | STRING | "true" | "false" | "nil" ;
```

Las llamadas del núcleo son a funciones nombradas, y no se admite `user.method()`. `user.name`, `users[0]` y `find_user(1).name` sí encajan en la gramática.

`TYPE_NAME, ".", NAME, "(" … ")"` es la llamada a una función de un módulo incorporado (`Map.put(...)`); el núcleo no admite módulos de usuario.

`and` y `or` evalúan con cortocircuito. Las sumas, restas, multiplicaciones, divisiones y módulos se agrupan de izquierda a derecha. Las comparaciones y comprobaciones de igualdad no se encadenan: `a < b < c` es inválido; se escribe `a < b and b < c`.

| Precedencia, de mayor a menor | Operaciones |
|---|---|
| 1 | Llamada nombrada, campo `.`, índice `[]`, agrupación |
| 2 | `-`, `not` unarios |
| 3 | `*`, `/`, `%` |
| 4 | `+`, `-` |
| 5 | `<`, `<=`, `>`, `>=` |
| 6 | `==`, `!=` |
| 7 | `and` |
| 8 | `or` |

`not` tiene precedencia alta: para negar una comparación se recomienda `not (age >= 18)`.

## 6. Reglas semánticas mínimas

La gramática determina qué se puede escribir. Las siguientes reglas determinan qué programas son válidos y cómo se ejecutan. Son las reglas que implementa el intérprete.

### Tipos e inferencia

| Tipo | Regla |
|---|---|
| `Int` | Entero con signo de 64 bits; overflow produce error de ejecución |
| `Float` | IEEE 754 binary64 |
| `Bool` | Solo `true` y `false`; no existe truthiness |
| `String` | Texto Unicode; concatenación con `+` |
| `Nil` | Un único valor, `nil`; también indica retorno sin resultado |
| `List[T]` | Lista homogénea e inmutable; índices `Int`, desde cero |
| `Map[K, V]` | Diccionario homogéneo e inmutable; la clave `K` es `Int` o `String`; conserva el orden de inserción |
| Struct declarado | Tipo nominal, campos tipados e inmutables |

Los parámetros y el retorno de las funciones requieren anotación. Las variables locales pueden inferirse del inicializador:

```ruby
count = 3
names: List[String] = []
```

Una lista vacía necesita un tipo esperado, que puede venir de una anotación, un parámetro, un campo o el retorno de una función. Una lista no vacía debe tener elementos del mismo tipo. No hay conversión numérica implícita ni tipo dinámico `Any`.

`Nil` no es un comodín nullable: `name: String = nil` es inválido. Los valores opcionales llegarán con `Option[T]`.

### Operadores

- `+`, `-`, `*` y `/` aceptan dos operandos del mismo tipo numérico. Además, `+` concatena dos `String`.
- La división de enteros trunca hacia cero. `%` solo acepta enteros y se define mediante `a = (a / b) * b + (a % b)`.
- Dividir por cero es un error de ejecución, también con `Float`. Las operaciones enteras que no caben en `Int` producen error.
- Los operadores de orden solo aceptan dos números del mismo tipo.
- `==` y `!=` aceptan valores del mismo tipo primitivo. En el núcleo no hay igualdad de listas ni structs.
- `and`, `or` y `not` solo aceptan `Bool`.
- No hay sobrecarga de operadores definida por el usuario.

Las expresiones, argumentos y campos de constructor se evalúan de izquierda a derecha. Una comparación entre floats sigue IEEE 754; en particular, un NaN no es igual a sí mismo.

### Variables y scope

La primera asignación introduce una variable en el scope actual. Una asignación posterior cambia su valor sin cambiar su tipo. Una anotación solo puede aparecer al introducir la variable.

Cada función y cada bloque de control introduce un scope léxico. No se permite ocultar una variable visible con otra del mismo nombre. Una asignación sin anotación actualiza la variable visible si ya existe; de lo contrario introduce una local al bloque actual.

Los parámetros y la variable de `for` son bindings ya inicializados. La variable de `for` es local al cuerpo y no puede reasignarse. Las variables creadas en un bloque no son visibles después de su `end`.

```ruby
count = 0
while count < 3
  puts("hello")
  count = count + 1
end
```

### Funciones y entrada

- Las funciones pueden llamarse antes de su declaración y ser recursivas.
- No hay sobrecarga, valores por defecto ni argumentos nombrados en funciones ordinarias.
- Una función con retorno distinto de `Nil` debe retornar en todos los caminos alcanzables. En el checker inicial, un bucle no garantiza por sí solo un retorno.
- La última expresión no retorna implícitamente.
- `return` sin valor equivale a `return nil`.
- Llegar al final de una función `-> Nil` retorna `nil`.
- Un ejecutable debe declarar exactamente una función `main() -> Nil` sin parámetros.

### Structs y listas

Todos los campos de un constructor son obligatorios y se proporcionan una sola vez. El orden de los campos nombrados es libre. No hay campos por defecto ni campos adicionales.

```ruby
user = User(age: 25, name: "Ana")
```

Los índices de listas deben estar entre cero y longitud menos uno; un índice negativo o fuera de rango produce error. `for` itera sobre `List[T]` en orden. No se admiten slices ni indexación de strings en el núcleo.

### Maps

`Map[K, V]` asocia claves con valores. La clave `K` solo puede ser `Int` o `String`; `V` puede ser cualquier tipo. `Map` lleva exactamente dos argumentos de tipo.

```ruby
stock: Map[String, Int] = {"apple": 3, "pear": 0}
apples = stock["apple"]
more = Map.put(stock, "kiwi", 7)
```

- Un literal usa llaves y `clave: valor`; admite varias líneas y coma final. Un `{}` vacío necesita un tipo esperado, como `[]`.
- `m[clave]` devuelve el valor. La clave debe tener el tipo `K`. Una clave ausente produce error de ejecución.
- Si un literal repite una clave, gana la última.
- Los maps son inmutables, como las listas: no hay `m[clave] = valor`. `Map.put` devuelve un map nuevo y deja el original intacto.
- No hay igualdad de maps ni `for` sobre un map; se recorre con `Map.keys`, que devuelve las claves en orden de inserción.

### Funciones incorporadas mínimas

```text
puts(value: String) -> Nil
```

`puts` escribe el texto y un salto de línea. Se reserva ese nombre y no se puede redefinir.

Para trabajar con maps y listas hay dos módulos incorporados, `Map` y `List`, que se llaman con `Modulo.funcion(...)`. Sus funciones son genéricas, así que el checker las trata de forma especial. Los nombres `Map` y `List` están reservados y no se pueden redefinir.

```text
Map.has_key?(map: Map[K, V], key: K) -> Bool
Map.keys(map: Map[K, V]) -> List[K]
Map.size(map: Map[K, V]) -> Int
Map.put(map: Map[K, V], key: K, value: V) -> Map[K, V]
List.size(list: List[T]) -> Int
```

El módulo `String` opera sobre texto. `String.length` y `String.slice` cuentan caracteres Unicode, no bytes; un `slice` fuera de rango es error de ejecución. `String.split(s, "")` devuelve una lista con un carácter Unicode por elemento. Las conversiones `String.to_int!` y `String.to_float!` aceptan números decimales con signo opcional; `to_int!` falla con `RUNTIME-INVALID-NUMBER` si el texto no es un entero decimal y con `RUNTIME-INTEGER-OVERFLOW` si está fuera del rango de `Int`, mientras `to_float!` rechaza texto que no sea un decimal real con `RUNTIME-INVALID-NUMBER`.

```text
String.length(s: String) -> Int
String.upcase(s: String) -> String
String.downcase(s: String) -> String
String.trim(s: String) -> String
String.split(s: String, separator: String) -> List[String]
String.join(parts: List[String], separator: String) -> String
String.contains?(s: String, part: String) -> Bool
String.starts_with?(s: String, prefix: String) -> Bool
String.ends_with?(s: String, suffix: String) -> Bool
String.replace(s: String, from: String, to: String) -> String
String.slice(s: String, start: Int, length: Int) -> String
String.from_int(n: Int) -> String
String.from_float(x: Float) -> String
String.to_int!(s: String) -> Int
String.to_float!(s: String) -> Float
```

El módulo `IO` escribe y lee por los puertos estándar; `IO.warn` escribe en la salida de error. `IO.inspect` imprime cualquier valor en forma de depuración estable y lo devuelve. `IO.gets` devuelve la siguiente línea sin su terminador (LF, CR o CRLF) y falla con `RUNTIME-END-OF-INPUT` al final; `IO.eof?` permite comprobarlo antes. El módulo `System` expone los argumentos del programa y termina la ejecución con un código.

```text
IO.puts(value: String) -> Nil
IO.print(value: String) -> Nil
IO.warn(value: String) -> Nil
IO.inspect(value: T) -> T
IO.gets() -> String
IO.read() -> String
IO.eof?() -> Bool
System.args() -> List[String]
System.exit(code: Int) -> Nil
```

Archivos, JSON, red y conversiones más ricas necesitan una API posterior; ver [`future.md`](future.md).

## 7. Diagnósticos para agentes

Cada error incluye un código estable, archivo, línea, columna, una explicación concreta y el fragmento de código con una marca bajo el span. Los spans viajan desde los tokens hasta el AST.

```text
example.agc:2:14 error[CHECK-TYPE-MISMATCH]
expected Int, found String

2 |   age: Int = "25"
  |              ^^^^
```

El código lleva el prefijo de la etapa que falló: `LEX-`, `PARSE-`, `CHECK-` (antes de ejecutar) o `RUNTIME-` (al ejecutar). Cada etapa se detiene en el primer error. Los casos mínimos a distinguir son: sintaxis inválida, nombre desconocido, tipo incompatible, aridad incorrecta, campo inexistente o faltante, retorno faltante y error de ejecución.

Los diagnósticos se refieren a Agentica y nunca exponen excepciones o tracebacks del host.

## 8. Ejemplos para revisar el diseño

### Función y control de flujo

```ruby
def classify(age: Int) -> String
  if age >= 18
    return "adult"
  elsif age >= 13
    return "teen"
  else
    return "child"
  end
end

def main() -> Nil
  puts(classify(25))
end
```

### Listas y acceso a campos

```ruby
struct Task
  title: String
  done: Bool
end

def main() -> Nil
  tasks: List[Task] = [
    Task(title: "Probar Agentica", done: false),
    Task(title: "Revisar gramática", done: true)
  ]

  for task in tasks
    if not task.done
      puts(task.title)
    end
  end
end
```

### Maps

```ruby
def main() -> Nil
  stock: Map[String, Int] = {"apple": 3, "pear": 0}
  stock = Map.put(stock, "kiwi", 7)
  for name in Map.keys(stock)
    if stock[name] > 0
      puts(name)
    end
  end
end
```

### Programas que deben rechazarse

```ruby
age: Int = "25"        # Tipos incompatibles.
if 1                   # La condición debe ser Bool.
  puts("hello")
end
values = []            # Falta tipo esperado para la lista vacía.
puts "hello"           # La llamada requiere paréntesis.
```

Estas instrucciones se muestran como fragmentos de cuerpo de función. En el nivel superior también serían inválidas por no ser declaraciones.

## 9. Guía para quien implemente el prototipo

Implementar primero las reglas de las secciones 4–6. Mantener independientes la gramática, el AST, el checker, el evaluador y las funciones incorporadas. No generar código del host sin preservar las reglas de Agentica: por ejemplo, `if 1` debe rechazarse aunque el host acepte truthiness.

Si una regla resulta demasiado costosa, cambiar explícitamente esta especificación y los ejemplos antes de crear una excepción silenciosa. El objetivo es que cualquier agente pueda consultar un documento breve y predecir el comportamiento del programa.

La primera evaluación del lenguaje debe medir programas correctos, intentos necesarios y utilidad de los errores. El tiempo de ejecución puede medirse después; la primera pregunta es si la sintaxis y las reglas ayudan a los agentes a producir y reparar código.
