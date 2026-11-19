---
title: Estructuras
weight: 10
description: Declara registros con campos tipados, créalos, lee sus campos y cópialos con algunos campos cambiados.
source_hash: "07f78c1b7abf"
---

## Declarar una estructura {#declare-a-struct}

Una estructura es un registro con campos con nombre y tipo. Decláralo al principio del archivo.

```agentica
struct User
  name: String
  age: Int
end

def main() -> Void
  user = User(name: "Ana", age: 25)
  puts(user.name)
  puts(user)
end
```

```output
Ana
User(name: "Ana", age: 25)
```

Crea una estructura con todos sus campos, cada uno por su nombre, en cualquier orden. Un campo que falta es un error:

```agentica {expect="CHECK-MISSING-FIELD"}
struct Point
  x: Int
  y: Int
end

def main() -> Void
  p = Point(x: 1)
end
```

## Valores predeterminados {#default-values}

Un campo escrito `name: Type = value` tiene un valor predeterminado, y el constructor puede omitirlo. Un campo sin valor predeterminado debe recibir un valor igualmente.

```agentica
struct Options
  name: String
  retries: Int = 3
  tags: List[String] = []
end

def main() -> Void
  puts(Options(name: "a"))
  puts(Options(name: "b", retries: 1))
end
```

```output
Options(name: "a", retries: 3, tags: [])
Options(name: "b", retries: 1, tags: [])
```

Un valor predeterminado sigue las mismas reglas que el de un parámetro: un literal, los bytes de un literal de cadena (`head: Bytes = "GET".bytes`), `true`, `false`, `nil`, `none`, `[]`, `{}`, una variante de enum sin payload o el nombre de una constante con ese valor (`retries: Int = RETRIES`). No vale una estructura creada sin argumentos, que solo admite un parámetro. Cualquier otra cosa es `CHECK-DEFAULT-VALUE`, y un valor de tipo incorrecto es `CHECK-TYPE-MISMATCH`.

```agentica {expect="CHECK-DEFAULT-VALUE"}
struct Options
  retries: Int = 1 + 2
end

def main() -> Void
  puts(Options())
end
```

`with` y `JSON.decode` no usan valores predeterminados: `with` copia un valor, y al decodificar siguen haciendo falta todas las claves.

## Cambiar un campo {#change-a-field}

Los campos no se pueden asignar. `value.with(...)` copia la estructura con los campos indicados cambiados. El original queda como estaba.

```agentica
struct Account
  owner: String
  balance: Int
end

def deposit(account: Account, amount: Int) -> Account = account.with(balance: account.balance + amount)

def main() -> Void
  account = Account(owner: "Bob", balance: 10)
  richer = deposit(account, 5)
  puts(richer)
  puts(account)
end
```

```output
Account(owner: "Bob", balance: 15)
Account(owner: "Bob", balance: 10)
```

Cada valor se calcula a partir de la estructura antes de la actualización, así que los campos pueden intercambiarse:

```agentica
struct Pair
  left: Int
  right: Int
  label: String
end

def main() -> Void
  pair = Pair(left: 1, right: 2, label: "p")
  swapped = pair.with(left: pair.right, right: pair.left)
  puts(swapped)
  puts(pair.with(label: "q", left: 0))
end
```

```output
Pair(left: 2, right: 1, label: "p")
Pair(left: 0, right: 2, label: "q")
```

Para un campo dentro de una estructura, actualiza los dos niveles. Las actualizaciones se encadenan:

```agentica
struct Address
  city: String
  zip: Int
end

struct User
  name: String
  address: Address
end

def main() -> Void
  ana = User(name: "Ana", address: Address(city: "Cusco", zip: 8))
  moved = ana.with(address: ana.address.with(city: "Lima"))
  puts(moved)
  puts(moved.with(name: "Bea").with(address: Address(city: "Quito", zip: 1)))
end
```

```output
User(name: "Ana", address: Address(city: "Lima", zip: 8))
User(name: "Bea", address: Address(city: "Quito", zip: 1))
```

`with` necesita al menos un campo. Cada uno debe tener nombre (si no, `PARSE-UNEXPECTED-TOKEN`), aparecer una sola vez, existir en la estructura y tener el tipo correcto (`CHECK-TYPE-MISMATCH`):

```agentica {expect="CHECK-UNKNOWN-FIELD"}
struct Point
  x: Int
  y: Int
end

def main() -> Void
  p = Point(x: 1, y: 2)
  q = p.with(z: 5)
end
```

Un `p.with(x: 2)` suelto no cambia nada, así que es `CHECK-UNUSED-VALUE`. Asigna el resultado: `p = p.with(x: 2)`.

```agentica {expect="CHECK-UNUSED-VALUE"}
struct Point
  x: Int
  y: Int
end

def main() -> Void
  p = Point(x: 1, y: 2)
  p.with(x: 2)
end
```

`with` no es una palabra reservada: una estructura puede tener un campo que se llame `with`, salvo que ese campo sea una función (`CHECK-REDEFINED-NAME`).

## Estructuras dentro de estructuras y listas {#structs-in-structs-and-lists}

Los campos pueden ser listas, mapas, otras estructuras y enums.

```agentica
struct Item
  name: String
  price: Int
end

struct Order
  id: Int
  items: List[Item]
end

def main() -> Void
  order = Order(id: 7, items: [Item(name: "tea", price: 3), Item(name: "cake", price: 5)])
  total = order.items.reduce(0) do |sum, item| sum + item.price end
  puts("order #{order.id}: #{total}")
end
```

```output
order 7: 8
```

## Listar los campos {#list-the-fields}

`Type.members` es una `List[StructMember]` con una entrada por cada campo de un tipo de estructura, en el orden de declaración. Un `StructMember` tiene dos campos `String`: `name` y `type`, el tipo del campo escrito como código fuente. Una herramienta, como un mapeador de tablas, puede construir SQL a partir de una estructura con él.

```agentica
type Id = Int

struct Address
  city: String
end

struct User
  id: Id
  name: String
  tags: List[String]
  home: Address
end

def main() -> Void
  User.members.each do |m| puts("#{m.name}: #{m.type}") end
end
```

```output
id: Int
name: String
tags: List[String]
home: Address
```

El tipo es el que muestra el comprobador, así que un alias se expande (`Id` da `Int`). `members` está en el tipo y no en un valor: `user.members` lee un campo con ese nombre, y una estructura puede tener uno. Un enum, un recurso o un alias no es una estructura, así que `Color.members` es `CHECK-UNKNOWN-METHOD` e `Id.members` es `CHECK-UNKNOWN-TYPE`.

```agentica {expect="CHECK-UNKNOWN-METHOD"}
enum Color
  Red
end

def main() -> Void
  puts(Color.members.size)
end
```

`Type.codec` está junto a él: el [códec](/library/text-and-data/json/#tcodec) de una estructura o enum que JSON puede leer, un `Codec[T]` con los mismos `members` más `decode`, `encode` y `from`. Así el código genérico obtiene los campos y el JSON de un tipo que no puede nombrar.

## Parámetros de tipo {#type-parameters}

Una estructura puede tomar parámetros de tipo después de su nombre, igual que un enum. El argumento de tipo sale de los valores que das:

```agentica
struct Box[T]
  value: T
end

struct Pair[A, B]
  first: A
  second: B
end

def main() -> Void
  count = Box(value: 41)
  puts(count.value + 1)
  pair = Pair(first: "one", second: count)
  puts(pair.second.value)
  puts(pair)
  puts(count.with(value: 7))
end
```

```output
42
41
Pair(first: "one", second: Box(value: 41))
Box(value: 7)
```

`count` es un `Box[Int]`, así que `count.value` es un `Int`. Un tipo nombra todos sus argumentos: `Box[Int]`, `Pair[String, Box[Int]]`. Un `Box` suelto o con un número incorrecto de argumentos es `CHECK-UNKNOWN-TYPE`.

```agentica
struct Box[T]
  value: T
end

def total(box: Box[List[Int]]) -> Int = box.value.sum

def main() -> Void
  puts(total(Box(value: [1, 2, 3])))
  puts(total(Box(value: [])))
end
```

```output
6
0
```

Una lista o un mapa vacíos no pueden decir cuál es el argumento, así que necesitan un tipo del lugar donde se usa la estructura: un parámetro, como arriba, un tipo de retorno, un campo o una variable con tipo. Sin uno, es `CHECK-ENUM-TYPE-INFERENCE`.

```agentica {expect="CHECK-ENUM-TYPE-INFERENCE"}
struct Box[T]
  value: T
end

def main() -> Void
  box = Box(value: [])
end
```

Los valores incompatibles son `CHECK-TYPE-MISMATCH`. Un parámetro no puede ser clave de un `Map` (`CHECK-MAP-KEY-TYPE`), y un campo llamado `with` no puede tener como tipo un parámetro (`CHECK-REDEFINED-NAME`), porque el argumento podría ser una función. `JSON.encode` escribe una instancia genérica, pero `JSON.decode` y `JSON.schema` la rechazan (`CHECK-NOT-DECODABLE`). Una estructura importada se escribe `Models.Box[Int]`.

## Sin métodos {#no-methods}

Las estructuras solo tienen campos. Un campo llamado `to_s` oculta la forma de texto, así que escribe funciones que reciban la estructura:

```agentica
struct Rect
  width: Int
  height: Int
end

def area(r: Rect) -> Int = r.width * r.height

def main() -> Void
  puts(area(Rect(width: 3, height: 4)))
end
```

```output
12
```

## Igualdad {#equality}

Dos estructuras del mismo tipo son iguales cuando todos sus campos son iguales, comparados en profundidad. Las listas, los mapas, los conjuntos, los Result y los enums se comparan de la misma forma:

```agentica
struct User
  name: String
  tags: List[String]
end

def main() -> Void
  a = User(name: "Ana", tags: ["admin"])
  b = User(name: "Ana", tags: ["admin"])
  puts(a == b)
  puts(a.with(tags: []) != b)
  puts([a, b] == [b, a])
end
```

```output
true
true
true
```

Una estructura que contiene un campo de función (`Fn`), una tarea, un canal o un handle no tiene igualdad: `==` sobre ella es `CHECK-TYPE-MISMATCH`, y el mensaje nombra el campo. Un campo `Float` sigue IEEE 754, así que una estructura que contiene un NaN no es igual a sí misma.

## Campos privados {#private-fields}

Una línea `private` en el cuerpo de una estructura, sola y con una línea en blanco antes y después, hace privados los campos que vienen después para el módulo que declara la estructura: su archivo, o el bloque `module` en el que está. Ese módulo lee, asigna y pasa los campos como siempre. Fuera de él, el valor puede pasarse, guardarse, enviarse, compararse e imprimirse, pero sus campos privados no se pueden leer, pasar al construir ni cambiar con `with`, y solo las funciones del módulo pueden construir la estructura:

```agentica
module Bank
  struct Account
    owner: String

    private

    cents: Int
  end

  def open(owner: String) -> Account = Account(owner: owner, cents: 0)

  def deposit(account: Account, cents: Int) -> Account = account.with(cents: account.cents + cents)

  def balance(account: Account) -> Int = account.cents
end

def main() -> Void
  account = Bank.deposit(Bank.open("Ana"), 150)
  puts("#{account.owner} #{Bank.balance(account)}")
  puts(account)
end
```

```output
Ana 150
Account(owner: "Ana", cents: 150)
```

`==` compara cada campo, y `inspect`, `to_s` y la interpolación muestran cada campo. Fuera del módulo, `account.cents`, `Account(owner: "Bo")`, `account.with(cents: 0)`, `Account.codec` y `JSON.encode(account)` son `CHECK-PRIVATE-FIELD`:

```agentica {expect="CHECK-PRIVATE-FIELD"}
module Bank
  struct Account
    owner: String

    private

    cents: Int
  end

  def open(owner: String) -> Account = Account(owner: owner, cents: 0)
end

def main() -> Void
  puts(Bank.open("Ana").cents)
end
```

`agentica doc` lista los campos públicos y dice que la estructura tiene campos privados.
