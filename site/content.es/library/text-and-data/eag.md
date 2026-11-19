---
title: Plantillas EAG (std)
weight: 11
description: El heredoc de plantilla `<<~EAG` y el módulo std/eag que necesita.
source_hash: "a1ec3ca952f4"
---

EAG ("Embedded AGentica") es el ERB de Agentica: una plantilla es un heredoc `<<~EAG` cuyo texto tiene las etiquetas del ERB de Ruby. Una plantilla es código del archivo que la contiene: el comprobador comprueba el tipo de cada etiqueta, no hay `eval`, y el resultado es un `String`. El archivo debe tener `import EAG from "std/eag"` (con cualquier forma de importación; sin ella, `CHECK-EAG-IMPORT`), como Ruby necesita `require "erb"`. Este es el único nombre que no es de Ruby: Ruby no tiene una forma de heredoc para ERB.

```ruby
EAG.html_escape(value: String) -> String   # ERB::Util.html_escape
```

```agentica
import EAG from "std/eag"

struct Item
  title: String
  visible: Bool
end

def page(name: String, items: List[Item]) -> String
  <<~EAG
    <h1><%= EAG.html_escape(name) %></h1>
    <ul>
    <% for item in items %>
      <% if item.visible %>
      <li><%= EAG.html_escape(item.title) -%>
      </li>
      <% end %>
    <% end %>
    </ul>
  EAG
end

def main() -> Void
  puts(page("a<b", [Item(title: "x&y", visible: true), Item(title: "z", visible: false)]))
end
```

```output
<h1>a&lt;b</h1>
<ul>
  <li>x&amp;y  </li>
</ul>

```

Una plantilla con un escapador escapa lo que inserta `<%= %>` y deja en paz `<%==`:

```agentica
import EAG from "std/eag"

def card(name: String, note: String) -> String
  <<~EAG
    <%@ escape &EAG.html_escape %>
    <p><%= name %>: <%== note %></p>
  EAG
end

def main() -> Void
  puts(card("a<b", "<em>ok</em>"))
end
```

```output
<p>a&lt;b: <em>ok</em></p>

```

- `<%= code %>` inserta el valor de `code` como lo hace `"#{code}"` (`to_s`). La salida es cruda, como la de ERB: no se escapa nada, así que escribe `EAG.html_escape(...)` para HTML, o dale a la plantilla un escapador (abajo).
- `<%== code %>` inserta el valor crudo, con o sin escapador (a diferencia de Erubi, donde `<%==` escapa cuando `<%=` no lo hace).
- `<%@ escape function %>` solo en la primera línea de la plantilla le da un escapador: `function` es un valor de tipo `Fn[String, String]`, como `&EAG.html_escape`, y cada `<%= code %>` entonces inserta `function.call("#{code}")`, así que el HTML se escapa de forma predeterminada y `<%==` es la salida. Una función de otro tipo es `CHECK-TYPE-MISMATCH` en la función; `escape` es la única palabra de directiva, y una directiva con otra palabra, sin función, que no esté en la primera línea o que se dé dos veces es `PARSE-EAG-DIRECTIVE`. Cualquier `Fn[String, String]` sirve, así que una biblioteca puede ofrecer su propio escapador.
- `<% code %>` es una sentencia: `if`, `elsif`, `else`, `for`, `while`, `case`, `end`, o cualquier otra. Las etiquetas de una plantilla deben cerrar sus propios bloques (`PARSE-EAG-BLOCK`). Una plantilla es un bloque de su función, así que una etiqueta no puede asignar una variable de la función (`CHECK-CAPTURED-ASSIGNMENT`); una variable creada en una etiqueta vive en la plantilla. Por la misma razón, un bloque dentro de una etiqueta no puede escribir salida: `<% items.each do |i| %><%= i %><% end %>` es `CHECK-CAPTURED-ASSIGNMENT`, así que escribe `<% for i in items %>` (la costumbre de Ruby de usar `each do` no funciona aquí).
- `<%# note %>` se quita. `<%%` es el texto `<%`. `-%>` quita el salto de línea después de la etiqueta, y `<%-` quita los espacios antes de la etiqueta cuando solo hay espacios antes de ella en su línea (el `trim_mode: "-"` de Ruby).
- Una regla es distinta del `trim_mode: "-"` de Ruby: una línea que solo tiene una etiqueta `<% %>` o `<%# %>` y espacios se quita entera, así que un bucle no deja líneas en blanco.
- El cuerpo es texto crudo: ni `\n` ni otro escape, ni `#{}`. Se quita la sangría común, como en cualquier heredoc `<<~`, y un cuerpo puede tener una sola línea. Una etiqueta termina en su línea, en el primer `%>` (`PARSE-EAG-UNTERMINATED-TAG`).
- Una plantilla es una expresión, así que puede devolverse, asignarse, pasarse como argumento o seguirse de un método (`<<~EAG.length`). Un error en una etiqueta indica el lugar de la etiqueta en la plantilla. `agentica type-at` y `refs` en una posición dentro de una etiqueta todavía no funcionan (`QUERY-NO-EXPRESSION`); `refs` por nombre encuentra los nombres que usa una etiqueta.

`html_escape` reemplaza `&`, `<`, `>`, `"` y `'` por `&amp;`, `&lt;`, `&gt;`, `&quot;` y `&#39;`, como lo hace `ERB::Util.html_escape`. Toma un `String`; llama antes a `to_s` sobre otro valor. El alias `h` de Ruby no existe aquí.
