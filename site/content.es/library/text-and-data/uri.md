---
title: URI (std)
weight: 9
description: El módulo std/uri, que codifica y decodifica por porcentaje los componentes de una URL y las cadenas de consulta.
source_hash: "d0da97f370fc"
---

`std/uri` está escrito en Agentica y sigue los nombres y las reglas de `URI` de Ruby: `import URI from "std/uri"`. Codifica texto para una URL, lo decodifica de vuelta, y convierte una cadena de consulta en una lista de pares de nombre y valor, y viceversa. Un decodificador devuelve un `Result` y nunca detiene el programa, sea cual sea la entrada.

```ruby
URI.encode_www_form_component(text: String) -> String
URI.encode_uri_component(text: String) -> String
URI.decode_www_form_component(text: String) -> Result[String]
URI.decode_uri_component(text: String) -> Result[String]
URI.encode_www_form(pairs: List[URI.Pair]) -> String
URI.decode_www_form(query: String) -> Result[List[URI.Pair]]
```

`URI.Pair(name: String, value: String)` es una parte de una cadena de consulta.

```agentica
import URI from "std/uri"

def main() -> Void
  puts(URI.encode_www_form_component("café au lait"))
  puts(URI.encode_uri_component("café au lait"))
  puts(URI.decode_uri_component("a+b%20c"))
  puts(URI.decode_www_form("a=1&a=2&b=&k"))
  puts(URI.encode_www_form([URI.Pair(name: "q", value: "a b"), URI.Pair(name: "q", value: "~")]))
  puts(URI.decode_www_form_component("100%"))
end
```

```output
caf%C3%A9+au+lait
caf%C3%A9%20au%20lait
ok("a+b c")
ok([URI.Pair(name: "a", value: "1"), URI.Pair(name: "a", value: "2"), URI.Pair(name: "b", value: ""), URI.Pair(name: "k", value: "")])
q=a+b&q=%7E
error("invalid %-encoding (100%)", kind: "argument")
```

## Componentes {#components}

El texto es UTF-8. Un codificador escribe los bytes de cada carácter como `%XX` en hexadecimal en mayúsculas, y solo deja `A-Z a-z 0-9 * - . _`; `~` se codifica (`%7E`), como en Ruby. Los dos codificadores difieren en el espacio: `encode_www_form_component` escribe `+` (cadenas de consulta y formularios), y `encode_uri_component` escribe `%20` (segmentos de ruta y otros componentes).

Un decodificador lee `%XX` en cualquier caso. `decode_www_form_component` convierte `+` en un espacio; `decode_uri_component` deja `+` tal cual, así que es el que se usa en un segmento de ruta. El texto que no es ASCII pasa sin cambios.

Un decodificador devuelve un `error` cuando un `%` no va seguido de dos dígitos hexadecimales (`invalid %-encoding (%zz)`, el mensaje del `ArgumentError` de Ruby) y cuando los bytes decodificados no son UTF-8 válido (`invalid UTF-8 after decoding (%ff)`). Ruby devuelve una cadena con bytes no válidos en el segundo caso, algo que un `String` no puede guardar.

## Cadenas de consulta {#query-strings}

Una cadena de consulta es una lista de `URI.Pair`, los arreglos `[name, value]` de Ruby. Un nombre puede repetirse y se conserva el orden, así que `a=1&a=2` son dos pares. `decode_www_form` parte por `&` y luego por el primer `=`: una parte sin `=` tiene el valor `""`, y `a=b=c` tiene el valor `b=c`. Devuelve el error de la primera parte que no se decodifica.

`decode_www_form` se diferencia de Ruby en dos cosas. Una parte vacía (`a=1&&b=2`, o un `&` suelto) se omite, como en Python, Rack y los navegadores, donde Ruby devuelve `["", ""]` para ella. Un `&` final no añade nada en ninguno de los dos. Un `%` mal formado es un error, donde Ruby lo deja en el texto. Solo `&` separa las partes.

`encode_www_form` une los pares como `name=value` con `encode_www_form_component` y no puede fallar, así que la salida de `decode_www_form` vuelve sin cambios. El par de un solo elemento de Ruby (un nombre sin `=`) no tiene forma aquí: escribe `Pair(name: "k", value: "")`, que da `k=`.
