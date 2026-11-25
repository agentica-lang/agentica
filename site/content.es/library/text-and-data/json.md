---
title: JSON
weight: 3
description: Codifica valores como JSON, decodifica JSON en estructuras y lee JSON dinámico.
source_hash: "ea47ed1dbea4"
---

Dos formas de trabajar con JSON:

- Para una forma conocida, declara una estructura, o un [enum](#enums) para elegir entre formas. `JSON.encode` lo escribe y `JSON.decode` lo lee de vuelta, con comprobación de tipos.
- Para datos cuya forma cambia, usa el tipo `JSON.Value` y las funciones de `JSON` para crearlos y leerlos.

`JSON` es un nombre reservado; `JSON.Value` y `JSON.Field` son sus miembros. Un `JSON.Value` no tiene constructor, campos ni indexación. `a == b` es verdadero cuando los dos son el mismo JSON, igual que `Hash#==` de Ruby: objetos con las mismas claves y valores iguales en cualquier orden de claves (una clave repetida cuenta una vez, con su último valor), arreglos con elementos iguales en orden, y números por valor, así que `1 == 1.0`, `1e2 == 100` y `-0.0 == 0.0` (un entero fuera de `Int` se compara con exactitud, sin redondeo); `!=` es su negación, y una lista, estructura o mapa que contiene un `JSON.Value` lo compara del mismo modo. El costo de `==` es el tamaño de ambos valores. Se imprime como texto JSON con `puts`, `to_s`, interpolación y `JSON.encode`; `inspect` e `IO.inspect` muestran `<JSON.Value>`, también dentro de una lista. Cada objeto conserva el orden de sus claves, como hacen `to_json` y `JSON.parse` de Ruby: una estructura escribe sus campos en el orden de declaración, un mapa en orden de inserción, y un objeto analizado en el orden de su texto (ver `JSON.parse`). `JSON.from`, `JSON.object` y `JSON.decode` mantienen los mismos órdenes, así que una lista de estructuras y una estructura muestran sus claves de la misma forma. Las funciones cuyo primer parámetro es un `JSON.Value` también son métodos: `JSON.get(j, "a")` es `j.get("a")`.

## JSON.encode {#jsonencode}

```signature
JSON.encode(value: T) -> String
```

Escribe JSON compacto. Acepta números, `Bool`, `String`, `nil`, `JSON.Value`, listas, mapas con claves `String`, estructuras, [enums](#enums) y [Optional](#optional-values) de esos tipos. Los campos de una estructura conservan su orden de declaración, y los pares clave-valor de un mapa su orden de inserción. Una instancia de una estructura o enum genérico cuenta por sus campos o payloads después de la sustitución (`Box[List[Int]]`). Los valores `Result`, los enums integrados como `TaskExit` y los mapas cuyas claves no son `String` son `CHECK-NOT-ENCODABLE`, y un contenedor vacío sin tipo necesita una anotación. Un `Float` no finito detiene el programa con `RUNTIME-JSON-ENCODE`; nunca se escribe como `null`. Un [`Float32`](/library/text-and-data/numbers/#float32) se escribe como su texto más corto (`0.1`), y `JSON.from` lo amplía a un `Float`. Un campo `JSON.Field` (ver [campos opcionales y nulos](#optional-and-nullable-fields)) no escribe nada cuando es `Absent`.

`JSON.encode` de un `JSON.Value` escribe las claves de cada objeto en el orden que tiene el valor, así que `JSON.encode(JSON.parse(x))` conserva el orden de las claves de `x`: ya no es una forma canónica, y dos textos que solo difieren en el orden de las claves dan dos textos. Compara los valores analizados con `==`, en su lugar.

```agentica
struct User
  name: String
  age: Int
  tags: List[String]
end

def main() -> Void
  puts(JSON.encode(User(name: "Ana", age: 25, tags: ["admin"])))
  puts(JSON.encode({"a": 1, "b": 2}))
  puts(JSON.encode([nil, nil]))
end
```

```output
{"name":"Ana","age":25,"tags":["admin"]}
{"a":1,"b":2}
[null,null]
```

## JSON.decode {#jsondecode}

```signature
JSON.decode(text: String, type: T) -> Result[T]
JSON.decode(json: JSON.Value, type: T) -> Result[T]
```

Lee JSON en una estructura o un [enum](#enums), o en un `List[T]` o `Map[String, T]` de ese tipo. El primer argumento es texto JSON o un `JSON.Value`, y el segundo el tipo: un tipo de estructura o enum con nombre, una instancia de una estructura genérica (`Box[Int]`), o `List[T]` o `Map[String, T]` escritos como tipo, no como valor. Un tipo suelto solo vale para `decode`, `schema` y `codec`, y `schema` y `codec` solo aceptan un tipo con nombre. Los campos pueden ser `Int`, los [tipos enteros de menos bits](/library/text-and-data/numbers/#int8-int16-int32-uint8-uint16-and-uint32) (`UInt8` y los demás), `UInt64`, `Float`, [`Float32`](/library/text-and-data/numbers/#float32) (el más cercano al texto del número, redondeado una sola vez), `Bool`, `String`, listas, mapas con clave `String`, estructuras y enums anidados o recursivos, instancias de estructuras genéricas cuyos campos son esos tipos para sus argumentos (`Box[List[Int]]`, `Tree[String]`), y `Optional` y `JSON.Field` de esos tipos; cualquier otro tipo anidado, incluida una instancia de enum genérico, es `CHECK-NOT-DECODABLE`, y también lo es una instancia cuyos argumentos anidan más de 32 niveles, como ocurre con una estructura cuyo campo se pasa a sí mismo un argumento más grande. Una clave que falta en un campo con valor predeterminado (`wire: String = ""`) da ese valor, así que una estructura más nueva sigue leyendo lo que escribió una versión anterior; `null` sigue siendo un error para ese campo salvo que sea un `Optional`. El JSON mal formado, los campos que faltan, los tipos incorrectos, el desbordamiento de `Int`, un entero fuera de su tipo de menos bits (`r: expected UInt8 from 0 to 255`), un número más allá del mayor `Float32` en un campo `Float32` y los números no finitos dan un Result de error con la ruta del campo o del índice. Las claves extra se ignoran. Un entero JSON puede decodificarse como `Float`; un decimal o un exponente nunca se decodifica como `Int`. Un mapa decodificado conserva el orden de las claves del objeto. Un valor `JSON.Value` se lee tal cual, con las mismas reglas y errores que su texto, así que no hace falta escribirlo con `JSON.encode` antes.

```agentica
struct User
  name: String
  age: Int
end

def main() -> Void
  good = JSON.decode("{\"name\": \"Ana\", \"age\": 25, \"extra\": true}", User)
  case good
    ok(user) -> puts("#{user.name} is #{user.age}")
    error(message) -> puts(message)
  end

  bad = JSON.decode("{\"name\": \"Bob\"}", User)
  puts(bad.ok?)
end
```

```output
Ana is 25
false
```

```agentica
struct Point
  x: Int
  y: Int
end

def main() -> Void
  data = JSON.parse("{\"points\": [{\"x\": 1, \"y\": 2}, {\"x\": 3}]}").unwrap!
  for item in data.get("points").unwrap!.list.unwrap!
    puts(JSON.decode(item, Point))
  end
end
```

```output
ok(Point(x: 1, y: 2))
error("y: expected required field", kind: "json.decode")
```

Un arreglo o un objeto JSON de nivel superior con elementos se decodifica en una sola llamada. Una ruta de error empieza en el índice o la clave:

```agentica
struct Point
  x: Int
  y: Int
end

def main() -> Void
  points = JSON.decode("[{\"x\": 1, \"y\": 2}, {\"x\": 3, \"y\": 4}]", List[Point]).unwrap!
  puts(points)
  puts(JSON.decode("{\"a\": {\"x\": 5}}", Map[String, Point]))
end
```

```output
[Point(x: 1, y: 2), Point(x: 3, y: 4)]
error("[\"a\"].y: expected required field", kind: "json.decode")
```

## JSON.schema {#jsonschema}

```signature
JSON.schema(type: T) -> JSON.Value
```

Describe una estructura como un JSON Schema: un esquema de objeto con `properties` y `required`. Un enum se describe con un `oneOf` (ver [enums](#enums)). `required` lista cada campo que no es un `JSON.Field` ni un `Optional` y no tiene valor predeterminado, y se omite cuando ningún campo es obligatorio (también en una estructura vacía). Los límites de `Int` son de 64 bits con signo y un tipo entero de menos bits tiene su propio `minimum` y `maximum`, las listas usan `items`, los mapas con clave `String` usan `additionalProperties`, y las estructuras y enums anidados y recursivos usan `$defs` y `$ref`; una instancia de estructura genérica tiene una definición propia en `$defs`, con nombre según sus argumentos (`Box[Int]`), que su `$ref` codifica en porcentaje como fragmento URI (`#/$defs/Box%5BInt%5D`). Las claves extra siguen permitidas.

```agentica
struct Point
  x: Int
  y: Int
end

def main() -> Void
  schema = JSON.schema(Point)
  puts(schema.get("required").unwrap!)
end
```

```output
["x","y"]
```

## T.codec {#tcodec}

`User.codec` (sobre el tipo, sin paréntesis, como `User.members`) es el `Codec[User]` de una estructura o enum que `JSON.decode` recibe.

```signature
codec.decode(text: String) -> Result[T]
codec.decode(json: JSON.Value) -> Result[T]
codec.encode(value: T) -> String
codec.from(value: T) -> JSON.Value
codec.members() -> List[StructMember]
```

Una función genérica puede llamar a `JSON.encode` y `JSON.from` sobre un valor de su parámetro de tipo `T` (o de `List[T]`, `Map[String, T]`, `Optional[T]`, o de una estructura o enum genérico de `T`): cada llamada a la función comprueba entonces que el tipo que vincula a `T` se puede escribir como JSON, y una llamada con un `Fn`, un `Bytes` o un `Task` es `CHECK-NOT-ENCODABLE` en ese argumento. Una función genérica que pasa su `T` a otra lleva la misma comprobación a sus propios llamadores.

```agentica
def to_json[T](value: T) -> String = JSON.encode(value)

def main() -> Void
  puts(to_json([1, 2]))
  puts(to_json({"ok": true}))
end
```

```output
[1,2]
{"ok":true}
```

`JSON.decode` necesita el tipo en runtime, así que una función genérica no puede llamarlo sobre `T`. En su lugar recibe un `Codec[T]`, y el llamador pasa `User.codec`, el códec de un nombre de estructura o enum que `JSON.decode` recibe. `decode`, `encode` y `from` funcionan como lo hacen `JSON.decode`, `JSON.encode` y `JSON.from` para ese tipo: `codec.encode(x)` y `codec.from(x)` reciben un `x` de tipo `T`. `codec.members` es la lista que da [`User.members`](/tour/structs/#list-the-fields), vacía en un enum, así que el código genérico que necesita los campos de un tipo no necesita JSON.

```agentica
struct User
  name: String
  age: Int
end

def body_as[T](body: String, codec: Codec[T]) -> Result[T] = codec.decode(body)

def show[T](codec: Codec[T], value: T) -> String = codec.encode(value)

def main() -> Void
  user = body_as("{\"name\": \"Ana\", \"age\": 25}", User.codec).unwrap!
  puts(show(User.codec, user))
end
```

```output
{"name":"Ana","age":25}
```

Un códec puede ser un parámetro, un campo de estructura o un elemento de lista, igual que un valor de función. Como un valor de función, no se puede imprimir ni comparar, ni ser una constante o un valor `ATS`. `IO.inspect` rechaza un valor que contiene un códec (`CHECK-TYPE-MISMATCH`; en un cuerpo genérico, `IO.inspect(x)` de un `T` que es un códec imprime el registro de su nombre y sus miembros). `Codec` está reservado, como nombre de tipo y como alias de importación (`import Codec from "..."` es `CHECK-REDEFINED-NAME`; elige otro alias).

## Valores opcionales {#optional-values}

Un [`Optional[T]`](/library/data-structures/optional/) es el `null` de JSON o un `T`: `none` escribe `null` y `some(x)` escribe `x`. `JSON.decode` lee `null` como `none`, y también una clave que falta en un campo `Optional`; cualquier otro valor se decodifica como `T` y da `some(...)`, con los textos de error de `JSON.Field` (`age: expected signed 64-bit Int or null`, `tags[0]: expected String or null`). Funciona para un campo, un elemento de lista, un valor de mapa, un `Optional` como elemento y el valor completo de `JSON.encode` y `JSON.from`; `JSON.decode`, `JSON.schema` y `T.codec` reciben un nombre de estructura, así que un `Optional` de nivel superior se decodifica como un campo de una estructura. Un campo `none` conserva su clave al codificarse. `JSON.schema` escribe un campo `Optional` como `{"anyOf": [<schema of T>, {"type": "null"}]}`. `JSON.schema` deja un campo `Optional` fuera de `required` y permite `null`.

```agentica
struct Server
  host: String
  port: Optional[Int] = none
  tags: List[Optional[String]]
end

def main() -> Void
  server = JSON.decode("{\"host\": \"a\", \"tags\": [\"x\", null]}", Server).unwrap!
  puts(server)
  puts(JSON.encode(server))
  puts(JSON.encode(server.with(port: some(8080))))
end
```

```output
Server(host: "a", port: none, tags: [some("x"), none])
{"host":"a","port":null,"tags":["x",null]}
{"host":"a","port":8080,"tags":["x",null]}
```

Lo que da `JSON.decode` se codifica de vuelta en el mismo JSON, salvo que una clave que falta vuelve como `null`. JSON tiene un solo `null`, así que en un `Optional[Optional[T]]` el valor `some(none)` escribe `null` y se lee de vuelta como `none`. Usa `JSON.Field` (abajo) cuando una clave que falta y `null` signifiquen cosas distintas. `Optional[Nil]`, `Optional[JSON.Field[T]]` y `JSON.Field[Optional[T]]` los rechaza el comprobador (ver la [referencia de integrados](/reference/builtins/)).

## Campos opcionales y nulos {#optional-and-nullable-fields}

Algunas APIs (llamadas a herramientas, cuerpos PATCH, archivos de configuración) distinguen tres estados de una clave: la clave está ausente, es `null`, o tiene un valor. Un campo de estructura de tipo `JSON.Field[T]` las mantiene separadas. Es un enum integrado con las variantes `JSON.Field.Absent`, `JSON.Field.Null` y `JSON.Field.Value(x)`.

- `JSON.decode` da `Absent` para una clave que falta, `Null` para `null`, y `Value(...)` para cualquier otro valor, decodificado como `T`. `Value` no añade ningún paso a la ruta del error, así que un error dentro del valor conserva su ruta y su texto (`address.zip: expected String`, `tags[0]: expected String`). Solo cuando el propio valor es de otro tipo, el mensaje añade "or null": `age: expected signed 64-bit Int or null`, `address: expected object or null`. Un campo que falta y que no es un `JSON.Field` sigue dando "required field".
- `JSON.encode` y `JSON.from` omiten una clave `Absent`, escriben `null` para `Null`, y escriben el valor de `Value`.
- `JSON.schema` deja el campo fuera de `required` y permite `null`: `{"anyOf": [<schema of T>, {"type": "null"}]}`, sin una definición propia en `$defs`.
- Un objeto con solo las claves declaradas de la estructura, con valores en la forma que escribe `encode`, se decodifica y se codifica de vuelta en el mismo objeto, salvo el orden de las claves: una clave ausente sigue ausente y un `null` sigue siendo `null`. Las claves extra se descartan, y un entero en un campo `Float` vuelve como `1.0`.

```agentica
struct UpdateUser
  name: JSON.Field[String]
  age: JSON.Field[Int]
end

def describe_age(age: JSON.Field[Int]) -> String
  text = ""
  case age
    JSON.Field.Absent -> text = "age: keep"
    JSON.Field.Null -> text = "age: clear"
    JSON.Field.Value(n) -> text = "age: set to #{n}"
  end

  text
end

def show(text: String) -> Result[Void]
  update = try JSON.decode(text, UpdateUser)
  puts(describe_age(update.age))
  name = ""
  case update.name
    JSON.Field.Value(n) -> name = "set to #{n}"
    _ -> name = "keep" # this API treats null like absent
  end

  puts("name: #{name}")
  puts(JSON.encode(update))
  ok()
end

def main() -> Void
  for text in ["{}", "{\"age\": null}", "{\"name\": \"Ana\", \"age\": 30}"]
    Result.unwrap!(show(text))
  end

  reply = UpdateUser(name: JSON.Field.Value("Bo"), age: JSON.Field.Null)
  puts(JSON.encode(reply))
end
```

```output
age: keep
name: keep
{}
age: clear
name: keep
{"age":null}
age: set to 30
name: set to Ana
{"name":"Ana","age":30}
{"name":"Bo","age":null}
```

Las variantes siempre van calificadas (`JSON.Field.Value(x)`), y `Absent` y `Null` necesitan un tipo esperado, que da un campo de estructura. Un `case` necesita las tres ramas o una rama `_`, que es como un programa trata por igual lo ausente y lo nulo. `JSON.Field` solo puede ser el tipo directo de un campo de estructura en un tipo JSON; en cualquier otro lugar de uno es `CHECK-JSON-FIELD-PLACE`. Las reglas del comprobador para `JSON.Field` y los demás nombres reservados están en la [referencia de integrados](/reference/builtins/).

## Enums {#enums}

Un enum de usuario se escribe como un objeto con el nombre de la variante bajo `tag` y sus elementos de payload, en orden, bajo `values`:

```agentica
enum Shape
  Circle(Float)
  Rect(Float, Float)
  Empty
end

struct Drawing
  shapes: List[Shape]
end

def main() -> Void
  drawing = Drawing(shapes: [Shape.Circle(2.0), Shape.Rect(1.0, 3.0), Shape.Empty])
  text = JSON.encode(drawing)
  puts(text)
  puts(JSON.decode(text, Drawing).unwrap! == drawing)
end
```

```output
{"shapes":[{"tag":"Circle","values":[2.0]},{"tag":"Rect","values":[1.0,3.0]},{"tag":"Empty","values":[]}]}
true
```

- `JSON.encode` y `JSON.from` escriben las dos claves, `tag` primero en el texto; una variante sin payload escribe `"values":[]`. Aceptan cualquier enum de usuario cuyos payloads se puedan escribir, incluidas las instancias genéricas como `Maybe[Int]`.
- `JSON.decode(text, Shape)` y un campo de estructura de tipo `Shape` leen la misma forma. `values` puede omitirse en una variante sin payload, y las claves extra se ignoran, como en las estructuras. Solo se puede decodificar un enum no genérico, y solo cuando sus payloads se puedan decodificar: un enum con un payload que `decode` rechaza es `CHECK-NOT-DECODABLE`, al igual que una instancia genérica como `Maybe[Int]` en cualquier parte del destino.
- Un error da la ruta como en una estructura, con `values[i]` para un elemento de payload, para un `tag` desconocido o que falta, para un `values` que falta o es incorrecto, para un número de elementos incorrecto o para un elemento incorrecto.
- `JSON.schema(Shape)` da un `oneOf` con un objeto para cada variante: `tag` es `{"enum": ["Rect"]}`, y `values` es un arreglo con `minItems` y `maxItems` iguales al número de elementos de payload, y `prefixItems` con un esquema por elemento. Una variante sin payload recibe `"maxItems": 0` y solo `tag` es obligatorio. Un enum alcanzado desde una estructura va en `$defs`.
- Un `JSON.Field` en un payload es `CHECK-JSON-FIELD-PLACE`: pertenece a un campo de estructura.

```agentica
enum Shape
  Circle(Float)
  Rect(Float, Float)
  Empty
end

def main() -> Void
  puts(JSON.decode("{\"tag\": \"Empty\"}", Shape))
  puts(JSON.decode("{\"tag\": \"Rect\", \"values\": [1.0]}", Shape))
  puts(JSON.decode("{\"tag\": \"Oval\"}", Shape))
end
```

```output
ok(Shape.Empty)
error("values: expected array of 2 items", kind: "json.decode")
error("tag: expected one of Circle, Rect, Empty", kind: "json.decode")
```

## JSON.parse {#jsonparse}

```signature
JSON.parse(text: String) -> Result[JSON.Value]
```

Lee exactamente un valor JSON de cualquier forma, con espacios en blanco opcionales alrededor (espacio, tabulador, CR, LF). Un JSON mal formado da un Result de error: la entrada vacía, el contenido sobrante, los escapes no válidos, los caracteres de control sin escapar y los números no finitos son todos errores. Un número decimal o con exponente conserva su signo, así que `-0.0` y `-0e5` se leen como `-0.0`, y cada `Float` finito que escribe `JSON.encode` se lee de vuelta con los mismos bits. `-0` es el entero 0, así que se decodifica en un `Float` como `0.0`, como en Python.

```agentica
def main() -> Void
  data = JSON.parse("{\"items\": [1, 2, 3]}").unwrap!
  puts(data)
  puts(JSON.parse("{oops").ok?)
end
```

```output
{"items":[1,2,3]}
false
```

Un objeto analizado conserva sus claves en el orden del texto. Una clave repetida se conserva una vez, en su primera posición, con su último valor, como hace `JSON.parse` de Ruby. Los arreglos conservan su orden, y `1` sigue siendo un entero y `1.0` un flotante, aunque `==` los dé por iguales. `==` y `Test.eq` comparan dos `JSON.Value` en cualquier orden de claves.

```agentica
def main() -> Void
  puts(JSON.parse("{\"b\": [2, 1], \"a\": 1, \"a\": 3}").unwrap!)
end
```

```output
{"b":[2,1],"a":3}
```

## JSON.get y JSON.at {#jsonget-and-jsonat}

```signature
JSON.get(json: JSON.Value, key: String) -> Result[JSON.Value]
JSON.at(json: JSON.Value, index: Int) -> Result[JSON.Value]
```

`get` lee un miembro de un objeto; `at` lee un elemento de un arreglo. Una clave que falta, un índice no válido o un tipo incorrecto dan un Result de error. `false` y `null` de JSON son valores presentes.

```agentica
def main() -> Void
  data = JSON.parse("{\"items\": [10, 20]}").unwrap!
  items = data.get("items").unwrap!
  puts(items.at(1).unwrap!)
  puts(data.get("nope").ok?)
end
```

```output
20
false
```

## JSON.string, JSON.int, JSON.float y JSON.bool {#jsonstring-jsonint-jsonfloat-and-jsonbool}

```signature
JSON.string(json: JSON.Value) -> Result[String]
JSON.int(json: JSON.Value) -> Result[Int]
JSON.float(json: JSON.Value) -> Result[Float]
JSON.bool(json: JSON.Value) -> Result[Bool]
```

Extraen un valor simple de un `JSON.Value`. El tipo incorrecto da un Result de error. `JSON.int` necesita un entero dentro de los límites de 64 bits, así que `1.0` no es un `Int`; `JSON.float` redondea a un binary64 finito, y el desbordamiento es un error. Los enteros analizados pueden superar `Int` hasta que se extraen. El `null` de JSON sigue siendo un `JSON.Value`.

```agentica
def main() -> Void
  data = JSON.parse("{\"name\": \"Ana\", \"age\": 25, \"score\": 9.5, \"admin\": false}").unwrap!
  puts(data.get("name").unwrap!.string)
  puts(data.get("age").unwrap!.int)
  puts(data.get("score").unwrap!.float)
  puts(data.get("admin").unwrap!.bool)
  puts(data.get("name").unwrap!.int.ok?)
end
```

```output
ok("Ana")
ok(25)
ok(9.5)
ok(false)
false
```

Con `try`, leer JSON anidado es breve:

```agentica
def city(text: String) -> Result[String]
  root = try JSON.parse(text)
  address = try root.get("address")
  name = try address.get("city")
  name.string
end

def main() -> Void
  puts(city("{\"address\": {\"city\": \"Lima\"}}"))
  puts(city("{}").ok?)
end
```

```output
ok("Lima")
false
```

## JSON.list {#jsonlist}

```signature
JSON.list(json: JSON.Value) -> Result[List[JSON.Value]]
```

Convierte un arreglo JSON en una lista de valores `JSON.Value`.

```agentica
def main() -> Void
  data = JSON.parse("[1, \"two\", null]").unwrap!
  for item in data.list.unwrap!
    puts(item)
  end
end
```

```output
1
"two"
null
```

## JSON.kind {#jsonkind}

```signature
JSON.kind(value: JSON.Value) -> String
```

Da la clase de un `JSON.Value`: `"null"`, `"bool"`, `"int"`, `"float"`, `"string"`, `"array"` u `"object"`. Nunca falla. Un número escrito sin fracción ni exponente, o creado a partir de un Int, es `"int"`, incluso fuera de los límites de 64 bits (entonces `JSON.int` sigue dando error); cualquier otro número es `"float"`.

```agentica
def main() -> Void
  data = JSON.parse("[1, 1.0, 1e2, \"x\", null, {}]").unwrap!
  puts(data.list.unwrap!.map do |item| item.kind end)
end
```

```output
["int", "float", "float", "string", "null", "object"]
```

## JSON.node {#jsonnode}

```signature
JSON.node(value: JSON.Value) -> JSON.Node
```

Abre un nivel de un `JSON.Value` para un `case`, para recorrer JSON cuya forma no se conoce de antemano. Nunca falla. `JSON.Node` es un enum integrado con las variantes `Null`, `Bool(Bool)`, `Int(Int)`, `BigInt(String)`, `Float(Float)`, `String(String)`, `Array(List[JSON.Value])` y `Object(Map[String, JSON.Value])`, que se escriben `JSON.Node.Int(n)` en un `case`. `Int` guarda un número que acepta `JSON.int`; `BigInt` guarda cualquier otro entero como su texto decimal exacto; `Float` guarda lo que da `JSON.float`, así que `1.0` y `1e2` son `Float`. Las claves de `Object` conservan el orden del objeto, igual que hace `JSON.decode` en un `Map`. Un `JSON.Node` no se puede codificar ni decodificar (`CHECK-NOT-ENCODABLE`, `CHECK-NOT-DECODABLE`). Prefiere `JSON.decode` en una estructura cuando la forma es conocida.

```agentica
def count(value: JSON.Value) -> Int
  case value.node
    JSON.Node.Array(items) -> items.map { |item| count(item) }.sum
    JSON.Node.Object(members) -> members.values.map { |item| count(item) }.sum
    _ -> 1
  end
end

def main() -> Void
  puts(count(JSON.parse("{\"a\": [1, 2.5, null], \"b\": {\"c\": \"x\"}}").unwrap!))
  puts(JSON.parse("[123456789012345678901]").unwrap!.at(0).unwrap!.node)
end
```

```output
4
JSON.Node.BigInt("123456789012345678901")
```

## JSON.null y JSON.null? {#jsonnull-and-jsonnull}

```signature
JSON.null() -> JSON.Value
JSON.null?(value: JSON.Value) -> Bool
```

```agentica
def main() -> Void
  n = JSON.null()
  puts(n)
  puts(JSON.null?(n))
  puts(JSON.null?(JSON.from(0)))
end
```

```output
null
true
false
```

## JSON.from {#jsonfrom}

```signature
JSON.from(value: T) -> JSON.Value
```

Convierte un valor que acepta `JSON.encode` en un `JSON.Value`, con las mismas reglas y errores (un `Float` no finito detiene el programa con `RUNTIME-JSON-ENCODE`). `null` y `false` siguen siendo distintos, y lo mismo ocurre con los objetos vacíos y los arreglos vacíos.

```agentica
def main() -> Void
  j = JSON.from({"ok": true})
  puts(j)
  puts(j.get("ok").unwrap!.bool)
end
```

```output
{"ok":true}
ok(true)
```

## JSON.object y JSON.array {#jsonobject-and-jsonarray}

```signature
JSON.object(fields: Map[String, JSON.Value]) -> JSON.Value
JSON.array(items: List[JSON.Value]) -> JSON.Value
```

Crean objetos y arreglos cuyos valores tienen tipos distintos: `object` recibe un `Map[String, JSON.Value]` y `array` una `List[JSON.Value]`.

```agentica
def main() -> Void
  person = JSON.object({"name": JSON.from("Ana")})
  mixed = JSON.array([JSON.from(1), JSON.from("two"), JSON.null()])
  puts(person)
  puts(mixed)
end
```

```output
{"name":"Ana"}
[1,"two",null]
```
