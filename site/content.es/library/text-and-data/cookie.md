---
title: Cookie (std)
weight: 11
description: El módulo std/cookie, que lee una cabecera Cookie de la solicitud y escribe una cabecera Set-Cookie de la respuesta.
source_hash: "903a506bf550"
---

`std/cookie` está escrito en Agentica y tiene el comportamiento de `parse_cookies_header` y `set_cookie_header` de Rack: `import Cookie from "std/cookie"`. Lee una cabecera `Cookie` de la solicitud y escribe una cabecera `Set-Cookie` de la respuesta. Nada en él se detiene, sea cual sea la entrada.

```ruby
Cookie.parse(header: String) -> Map[String, String]
Cookie.set_header(cookie: Cookie.Cookie) -> Result[String]
```

`Cookie.Cookie(name: String, value: String, ...)` es una cookie para enviar. Los demás campos tienen valores predeterminados, y un atributo que se deja en su valor predeterminado no se escribe.

```ruby
struct Cookie.Cookie
  name: String
  value: String
  path: String = ""
  domain: String = ""
  max_age: Int = Cookie.NO_MAX_AGE  # no Max-Age; 0 or less writes Max-Age=0, which deletes the cookie
  expires: String = ""              # written as it is: "Wed, 21 Oct 2015 07:28:00 GMT"
  secure: Bool = false
  http_only: Bool = false
  same_site: String = ""            # "Strict", "Lax" or "None"
end
```

```agentica
import Cookie from "std/cookie"

def main() -> Void
  puts(Cookie.parse("sid=abc123; theme=dark; sid=other"))
  cookie = Cookie.Cookie(
    name: "sid",
    value: "abc123",
    path: "/",
    max_age: 3600,
    secure: true,
    http_only: true,
    same_site: "Lax",
  )

  puts(Cookie.set_header(cookie))
  puts(Cookie.set_header(Cookie.Cookie(name: "sid", value: "a b")))
end
```

```output
{"sid": "abc123", "theme": "dark"}
ok("sid=abc123; Path=/; Max-Age=3600; Secure; HttpOnly; SameSite=Lax")
error("invalid cookie value (byte 1)", kind: "argument")
```

`parse` divide la cabecera por `;`, quita los espacios alrededor de cada parte y divide una parte por su primer `=`. Una parte sin `=` o con un nombre vacío se omite, y el primer valor de un nombre repetido gana, como en `parse_cookies_header` de Rack. El mapa conserva el orden de la primera aparición.

`set_header` escribe `name=value` y luego los atributos en el orden de Rack: `Domain`, `Path`, `Max-Age`, `Expires`, `Secure`, `HttpOnly`, `SameSite` (Rack 3 escribe los nombres de los atributos en minúscula; esta función los escribe con la inicial en mayúscula). No hay tipo de fecha, así que `expires` es texto que tú formateas. `max_age` es `Cookie.NO_MAX_AGE`, el `Int` más pequeño, cuando no hay `Max-Age`, así que un número negativo calculado nunca se toma por él: escribe `Max-Age=0` y el navegador borra la cookie. Devuelve un `error` que nombra el campo cuando:

- `name` está vacío o no es un token de RFC 7230 (letras, dígitos y ``!#$%&'*+-.^_`|~``),
- `value` tiene un byte que RFC 6265 no permite: un espacio, `"`, `,`, `;`, `\`, un byte de control o un byte no ASCII; el error da la posición del byte (`invalid cookie value (byte 3)`) y nunca el valor, que puede ser un secreto,
- `path`, `domain` o `expires` tiene un carácter de control, un byte no ASCII o `;`, `domain` tiene un espacio, o `path` o `expires` empieza o termina con un espacio,
- `same_site` no es `Strict`, `Lax` ni `None`, o es `None` sin `secure: true`,
- el nombre empieza con `__Secure-` y `secure` es false, o empieza con `__Host-` y `secure` es false, `path` no es `/` o `domain` no está vacío (el prefijo se compara sin distinguir mayúsculas, como hacen los navegadores).

Al texto de un error sobre un nombre o un atributo se le quitan los bytes de control, así que es seguro en una línea de registro.

A diferencia de `CGI::Cookie` de Ruby y de Rack, que escapan el valor al escribirlo y lo decodifican al leerlo, las funciones de cookie nunca codifican en porcentaje, decodifican ni ponen entre comillas, y esto es definitivo. El valor se escribe tal cual y se lee tal como lo envió el cliente, así que un llamador que necesite un valor con un espacio, una coma o texto no ASCII lo codifica antes de `set_header` y lo decodifica después de `parse`. Un `%41` en una cabecera sigue siendo `%41`.

Un programa que tiene su propio nombre `Cookie` importa el módulo con otro alias, como `import C from "std/cookie"`, porque `import Cookie` chocaría con él (`CHECK-REDEFINED-NAME`).
