---
title: TCP, TLS y HTTP
weight: 4
description: Búsquedas DNS, sockets TCP y TLS, y el cliente y el servidor HTTP/1.1 de std/http.
source_hash: "9af1f25b0881"
---

Las funciones de red devuelven un `Result` y reciben los tiempos de espera en milisegundos.

- Con `--deny-net` (o `--sandbox`), cada búsqueda DNS, cada conexión y cada escucha devuelve un error que empieza con `denied: --deny-net`, antes de cualquier consulta DNS. Con `--deny-fs`, una llamada TLS que nombra un archivo (un archivo de CA, un certificado o una clave) devuelve `denied: --deny-fs`.
- Los sockets, los listeners, los clientes y los servidores son handles: `IO.inspect` imprime `<TCP.Socket>`, no se pueden comparar, y se cierran cuando termina el programa.
- Un handle pertenece a la tarea que lo abrió y se cierra cuando esa tarea termina, así que ábrelo en la tarea que lo conserva. [Task.spawn_owning](/library/concurrency/task/#taskspawn_owning) se lo da a una tarea nueva.
- Los tiempos de espera son milisegundos positivos, hasta el `Int` más grande, y se toman tal como se dan: `0` o un valor negativo devuelve `network: timeout must be positive milliseconds`. Un tiempo de espera cubre la llamada completa, incluida la espera a otra tarea que usa el mismo socket. Tras un tiempo de espera durante E/S activa, el socket se cierra, y las llamadas posteriores fallan de inmediato con `network: socket is closed`; un tiempo de espera mientras solo se espera un bloqueo lo deja abierto.

## DNS {#dns}

### DNS.lookup {#dnslookup}

```signature
DNS.lookup(host: String, timeout_ms: Int = 30000) -> Result[List[String]]
```

Devuelve las direcciones de un nombre de host según el resolutor del sistema, el mismo que usa `TCP.connect`, así que se aplican el archivo hosts y la configuración de DNS de la plataforma. Cada dirección IPv4 e IPv6 llega como texto (`"127.0.0.1"`, `"::1"`), en el orden del resolutor y sin duplicados. Una dirección IP se devuelve a sí misma, y una IPv6 en su forma abreviada. Un nombre que no se resuelve es un error que empieza con `network: host not found`, seguido del host y del motivo que dio el resolutor. Un nombre vacío o uno que contiene un NUL es un error, y también lo es un tiempo de espera (`network: operation timed out`). Solo espera la tarea: una tarea cancelada deja de esperar, y la búsqueda termina en segundo plano.

```agentica
def main() -> Void
  IO.inspect(DNS.lookup("127.0.0.1"))
  IO.inspect(DNS.lookup("2001:DB8:0:0:0:0:0:1"))
  IO.inspect(DNS.lookup(""))
end
```

```output
ok(["127.0.0.1"])
ok(["2001:db8::1"])
error("network: the host name is empty", kind: "argument")
```

## TCP {#tcp}

### TCP.listen y TCP.local_port {#tcplisten-and-tcplocal_port}

```signature
TCP.listen(host: String, port: Int) -> Result[TCP.Listener]
TCP.local_port(listener: TCP.Listener) -> Int
```

El puerto `0` elige un puerto libre, y `local_port` dice cuál (aquí los puertos van de 0 a 65535, y de 1 a 65535 en `connect`). Un host que contiene un NUL es un error. El listener acepta en todas las direcciones que representa el nombre de host: `"localhost"` acepta `127.0.0.1` y `::1`.

```agentica
def main() -> Void
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  puts(TCP.local_port(listener) > 0)
  TCP.close_listener(listener)
end
```

```output
true
```

### TCP.connect y TCP.accept {#tcpconnect-and-tcpaccept}

```signature
TCP.connect(host: String, port: Int, timeout_ms: Int) -> Result[TCP.Socket]
TCP.accept(listener: TCP.Listener, timeout_ms: Int) -> Result[TCP.Socket]
```

`connect` abre una conexión con un servidor. `accept` espera al siguiente cliente de un listener.

### TCP.remote_address {#tcpremote_address}

```signature
TCP.remote_address(socket: TCP.Socket) -> String
```

La dirección IP del otro extremo, sin el puerto: `"127.0.0.1"` o `"::1"`, como `REMOTE_ADDR` de Rack. Un cliente IPv4 de un listener IPv6 aparece como IPv4 (`"127.0.0.1"`, no `"::ffff:127.0.0.1"`). Se descarta el identificador de zona de IPv6, así que los peers link-local (`fe80::...`) en interfaces distintas pueden parecer iguales. Un socket cerrado devuelve `""`. Los sockets TLS también lo tienen.

```agentica
def main() -> Void
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  client = TCP.connect("127.0.0.1", TCP.local_port(listener), 2000).unwrap!
  server = TCP.accept(listener, 2000).unwrap!
  puts(TCP.remote_address(server))
  TCP.close(server)
  IO.inspect(TCP.remote_address(server))
  TCP.close(client)
  TCP.close_listener(listener)
end
```

```output
127.0.0.1
""
```

### TCP.send y TCP.read_line {#tcpsend-and-tcpread_line}

```signature
TCP.send(socket: TCP.Socket, text: String, timeout_ms: Int) -> Result[Void]
TCP.read_line(socket: TCP.Socket, timeout_ms: Int) -> Result[String]
```

`send` escribe texto UTF-8 y vacía el búfer de escritura. `read_line` lee una línea sin su fin de línea (LF o CRLF).

- Una última línea sin fin de línea cuenta cuando el otro extremo cierra la conexión.
- `read_line` devuelve un error al final de la entrada, cuando la conexión se rompe (aunque sea a mitad de línea), y con una línea de más de 1 MiB (que además cierra el socket).
- TCP es un flujo de bytes: un `send` puede llegar en varias lecturas, y un `read_line` puede abarcar varios envíos. Un carácter partido entre dos lecturas se une antes de comprobar el UTF-8.

Un programa que se habla a sí mismo, con una tarea como servidor:

```agentica
def echo_once(listener: TCP.Listener) -> Result[Void]
  client = try TCP.accept(listener, 2000)
  line = try TCP.read_line(client, 2000)
  try TCP.send(client, "echo: #{line}\n", 2000)
  TCP.close(client)
  ok()
end

def main() -> Void
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  server = Task.spawn(&echo_once, listener)
  socket = TCP.connect("127.0.0.1", TCP.local_port(listener), 2000).unwrap!
  _ = TCP.send(socket, "hello\n", 2000)
  puts(TCP.read_line(socket, 2000))
  puts(Task.await(server))
  TCP.close(socket)
  TCP.close_listener(listener)
end
```

```output
ok("echo: hello")
ok()
```

### TCP.send_bytes y TCP.recv_bytes {#tcpsend_bytes-and-tcprecv_bytes}

```signature
TCP.send_bytes(socket: TCP.Socket, bytes: Bytes, timeout_ms: Int) -> Result[Void]
TCP.recv_bytes(socket: TCP.Socket, max_bytes: Int, timeout_ms: Int) -> Result[Bytes]
TCP.recv_bytes(socket: TCP.Socket, max_bytes: Int) -> Result[Bytes]
```

Bytes en bruto, como [`Bytes`](/library/data-structures/bytes/). `send_bytes` acepta como máximo 1 MiB por llamada. `recv_bytes` acepta un `max_bytes` de 1 a 1048576 y devuelve lo que ha llegado, hasta `max_bytes`, y `Bytes` vacío cuando el otro extremo ha cerrado.

Sin `timeout_ms`, `recv_bytes` espera sin límite, hasta que llegan bytes, el otro extremo cierra o la tarea se cancela. Un servidor lo usa para la siguiente solicitud de un cliente inactivo: un tiempo de espera cerraría el socket y así desconectaría al cliente. Una lectura cancelada no toma nada, y los bytes que llegan después van a la siguiente lectura.

### TCP.write y TCP.flush {#tcpwrite-and-tcpflush}

```signature
TCP.write(socket: TCP.Socket, text: String, timeout_ms: Int) -> Result[Void]
TCP.write_bytes(socket: TCP.Socket, bytes: Bytes, timeout_ms: Int) -> Result[Void]
TCP.flush(socket: TCP.Socket, timeout_ms: Int) -> Result[Void]
TCP.write_limit(socket: TCP.Socket, bytes: Int) -> Result[Void]
```

`write` toma los bytes y devuelve sin esperar al otro extremo: lo que el sistema no acepta de una vez espera en el búfer de escritura del socket y sale en segundo plano, en el orden de las escrituras. Una tarea que envía a muchos sockets lo usa para que un lector lento no retrase a los demás. `write_bytes` es lo mismo para `Bytes`, con un máximo de 1 MiB por llamada.

- Una escritura solo espera cuando deja en el búfer más bytes que el límite, y entonces espera hasta que sale la mitad del límite. El límite es 65536 bytes; `write_buffer` lo fija para un socket, de 1024 a 16777216.
- `flush` espera hasta que el búfer está vacío. Un `send` tras una escritura va detrás de los bytes en espera y devuelve cuando todos han salido, así que `send` equivale a una escritura más un vaciado.
- Cuando falla una escritura en el búfer, `flush` y toda escritura posterior en el socket devuelven el error de la escritura fallida. Un `timeout_ms` que se agota cierra el socket, igual que en `send`.
- `TCP.close`, el final de la tarea propietaria del socket y el final de la ejecución envían los bytes que aún esperan antes de que la conexión se cierre. Esperan a lo sumo el límite de vaciado de la ejecución (`--flush-timeout`, valor predeterminado: 30 segundos), y un socket cerrado cuyo peer no lee conserva su búfer y su descriptor durante ese tiempo. Los bytes que siguen sin enviarse al llegar al límite se descartan, y también los de una conexión que el peer reinicia y los que esperan cuando una señal de parada termina la ejecución; la ejecución imprime al final, en el error estándar, una advertencia con su cantidad. Un programa que necesita saber si los bytes salieron llama a `flush`, que devuelve el error.
- El límite no es la memoria máxima que puede ocupar el búfer de un socket: cada tarea que escribe en el socket puede dejar sobre él los bytes de una llamada (hasta 1 MiB con `write_bytes`), y los bytes se copian una vez más mientras salen.
- Un socket TLS almacena sus registros en búfer de la misma forma.

```agentica
def read_two(listener: TCP.Listener) -> Result[String]
  client = try TCP.accept(listener, 2000)
  first = try TCP.read_line(client, 2000)
  second = try TCP.read_line(client, 2000)
  TCP.close(client)
  ok("#{first} #{second}")
end

def main() -> Void
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  reader = Task.spawn(&read_two, listener)
  socket = TCP.connect("127.0.0.1", TCP.local_port(listener), 2000).unwrap!
  _ = TCP.write(socket, "one\n", 2000)
  _ = TCP.write(socket, "two\n", 2000)
  puts(TCP.flush(socket, 2000))
  puts(Task.await(reader))
  TCP.close(socket)
  TCP.close_listener(listener)
end
```

```output
ok()
ok("one two")
```

### TCP.close y TCP.close_listener {#tcpclose-and-tcpclose_listener}

```signature
TCP.close(socket: TCP.Socket) -> Void
TCP.close_listener(listener: TCP.Listener) -> Void
```

Cerrar dos veces no es un error. Cierra antes solo cuando no debe esperar a que la tarea termine. `TCP.close` devuelve de inmediato; los bytes del búfer de escritura siguen saliendo ([TCP.write](#tcpwrite-and-tcpflush)).

## TLS {#tls}

```signature
TLS.alpn(socket: TCP.Socket) -> String
TLS.client_context(options: TLS.ClientOptions) -> Result[TLS.Context]
TLS.server_context(options: TLS.ServerOptions) -> Result[TLS.Context]
TLS.connect(host: String, port: Int, context: TLS.Context, timeout_ms: Int) -> Result[TCP.Socket]
TLS.listen(host: String, port: Int, context: TLS.Context) -> Result[TCP.Listener]
TLS.upgrade(socket: TCP.Socket, context: TLS.Context, host: String, timeout_ms: Int) -> Result[TCP.Socket]
```

```text
struct TLS.ClientOptions
  ca_file: String = ""
  cert_file: String = ""
  key_file: String = ""
  alpn: List[String] = []
end

struct TLS.ServerOptions
  cert_file: String
  key_file: String
  alpn: List[String] = []
end
```

Un `TLS.Context` es la configuración TLS de un rol. Se crea una vez y lo comparten todos los sockets, listeners y clientes HTTP creados a partir de él. `HTTP.ClientOptions` lo guarda, así que `JSON.schema`, `JSON.decode` y `JSON.encode` lo rechazan. Los sockets y listeners TLS usan las mismas funciones `TCP`, con los mismos límites y tiempos de espera.

- `TLS.client_context` y `TLS.server_context` leen y comprueban los archivos PEM al ejecutarse, así que un archivo malo falla ahí, no en cada conexión. Un archivo que cambia después no cambia el contexto: crea uno nuevo.
- `TLS.connect` toma un contexto de cliente y `TLS.listen` un contexto de servidor; el rol contrario detiene el programa con `RUNTIME-TLS-CONTEXT-ROLE`. Un contexto sigue válido mientras un socket o listener creado a partir de él esté abierto.
- `TLS.connect` usa TLS 1.2 o posterior y siempre comprueba el certificado y el nombre de host (una dirección IP como host, contra las direcciones IP del certificado).
- Un `ca_file` vacío usa los certificados de confianza del sistema, leídos una vez por proceso, y rechaza los que el sistema no considera de confianza. `SSL_CERT_FILE` reemplaza el almacén, `SSL_CERT_DIR` añade un directorio. Un `ca_file` no vacío es un archivo PEM que los reemplaza; uno que falta o está vacío hace que `TLS.client_context` falle.

  | Sistema | Almacén |
  |---|---|
  | Linux | el paquete de CA |
  | macOS | las raíces del sistema y la configuración de confianza de Keychain |
  | Windows | el almacén ROOT (los intermedios de su almacén de CA ayudan a formar una cadena, pero nunca son raíces) |

- Un contexto de servidor necesita archivos PEM para la cadena de certificados y la clave privada, y falla cuando un archivo es malo o la clave no coincide.
- `alpn` lista los protocolos que ALPN negocia en el handshake (`["h2", "http/1.1"]`), para una biblioteca que habla HTTP/2 o gRPC sobre un socket TLS. Un cliente los ofrece; un servidor elige el primero de los suyos que el cliente también ofrece, y rechaza el handshake cuando no hay ninguno en común (un cliente que no ofrece ninguno no recibe ninguno). `TLS.alpn(socket)` devuelve el protocolo elegido, o `""`. Cada nombre mide de 1 a 255 bytes y la lista como máximo 65535 bytes (cada nombre ocupa un byte más), y se comprueba al crear el contexto. `HTTP.client`, `HTTP.start` y `HTTP.serve_tls` hablan solo HTTP/1.1: un contexto cuyo `alpn` no es `[]` ni `["http/1.1"]` detiene el programa con `RUNTIME-TLS-CONTEXT-ALPN`.
- Un contexto de cliente envía un certificado de cliente cuando `cert_file` y `key_file` nombran archivos PEM, comprobados como en un servidor. Déjalos vacíos los dos para no enviar ninguno; dar solo uno es un error.
- Un peer que cierra sin el mensaje de cierre de TLS termina el flujo como EOF.

Un cliente que habla HTTP/2 lo ofrece primero y lee qué protocolo eligió el servidor:

```agentica {mode="check"}
def protocol(host: String) -> Result[String]
  context = try TLS.client_context(TLS.ClientOptions(alpn: ["h2", "http/1.1"]))
  socket = try TLS.connect(host, 443, context, 5000)
  ok(TLS.alpn(socket))
end
```

### TLS.upgrade {#tlsupgrade}

`TLS.upgrade` inicia TLS en un socket TCP abierto, para protocolos que empiezan en texto plano (`STARTTLS` de SMTP e IMAP, `SSLRequest` de PostgreSQL). Devuelve un socket TLS nuevo.

- Con un contexto de cliente actúa como cliente y comprueba `host` igual que `TLS.connect`. Con un contexto de servidor actúa como servidor y `host` debe ser `""`; otro host detiene el programa con `RUNTIME-TLS-CONTEXT-ROLE`.
- Una vez que sus argumentos pasan las comprobaciones, el socket en texto plano se cierra para el programa, funcione o no el handshake: una llamada posterior sobre él devuelve `network: socket is closed`.
- Los bytes que llegaron y aún no se leyeron hacen fallar la actualización (`network: data came before the TLS handshake`): STARTTLS los prohíbe. Un envío que sigue en curso en el socket también la hace fallar. Con varios planificadores, una actualización mientras otra tarea lee el socket puede fallar con `network: a read on the socket is in progress`, y el socket en texto plano queda entonces abierto: depende del momento (esa lectura está dentro de la recepción del núcleo). Actualiza en la tarea que lee el socket.
- El handshake se ejecuta dentro de `timeout_ms`; un tiempo de espera cierra la conexión. Un socket TLS no se puede actualizar otra vez.

Un cliente SMTP lee cada respuesta hasta su última línea, así que no queda ningún byte antes del handshake:

```agentica {mode="check"}
# An SMTP reply, up to its last line: "250-" goes on, "250 " ends it.
def reply(socket: TCP.Socket) -> Result[String]
  line = try TCP.read_line(socket, 5000)
  while line.slice(3, 1) == "-"
    line = try TCP.read_line(socket, 5000)
  end

  ok(line)
end

def starttls(host: String, context: TLS.Context) -> Result[TCP.Socket]
  plain = try TCP.connect(host, 587, 5000)
  try reply(plain)
  try TCP.send(plain, "EHLO client.example\r\n", 5000)
  try reply(plain)
  try TCP.send(plain, "STARTTLS\r\n", 5000)
  ready = try reply(plain)
  return error(ready) if !ready.start_with?("220")

  TLS.upgrade(plain, context, host, 5000)
end
```

```agentica {mode="check"}
def main() -> Void
  context = TLS.client_context(TLS.ClientOptions()).unwrap!
  socket = TLS.connect("example.com", 443, context, 5000).unwrap!
  _ = TCP.send(socket, "HEAD / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n", 5000)
  puts(TCP.read_line(socket, 5000))
  TCP.close(socket)
end
```

## Cliente HTTP {#http-client}

HTTP es la biblioteca `std/http`, escrita en Agentica: `import HTTP from "std/http"` (sin ella aparece `CHECK-UNKNOWN-NAME`). Funciona igual en Linux, macOS y Windows, sobre HTTP y HTTPS.

- Cada llamada del cliente es completa: devuelve cuando ha llegado la respuesta entera (para un cuerpo que se lee fragmento a fragmento, ver [`HTTP.start`](#httpstart-httpsend_request-httpread_body-and-httpfinish), y para un cuerpo en un canal, [`HTTP.open`](#httpopen-and-httpupload)). El cuerpo es `Bytes`, tal como llegó (cualquier contenido, hasta `max_body_bytes`); no se descomprime. [`HTTP.text`](#httptext) lo decodifica con su juego de caracteres.
- Los códigos de estado, como 404 o 500, son respuestas normales. Los resultados `error` son una URL incorrecta, una conexión rechazada, un tiempo de espera o un cuerpo por encima del límite. Los errores de protocolo empiezan con `http: `, los de conexión conservan su texto de TCP o TLS, y un tiempo de espera es `network: operation timed out`.
- `GET`, `HEAD`, `OPTIONS`, `PUT` y `DELETE` se reintentan una vez, en una conexión nueva y dentro del mismo tiempo de espera, cuando el servidor había cerrado una conexión reutilizada y no llegó ningún byte de respuesta. Los demás métodos nunca se reintentan.
- Los nombres de cabecera deben ser tokens HTTP, y los valores, texto Latin-1 sin caracteres de control.
- `HTTP.Request`, `HTTP.Response`, `HTTP.Header`, `HTTP.ClientOptions`, `HTTP.ServerOptions`, `HTTP.Client` y `HTTP.Server` son tipos integrados que `std/http` reexporta, así que `import {Request, Response} from "std/http"` los vincula por nombre. Un diagnóstico, `help` y un valor impreso muestran los nombres `HTTP.`: una respuesta se imprime como `HTTP.Response(status: ...)` y un cliente como `<HTTP.Client>`. No reservan ningún nombre: un programa puede declarar su propio `Header` o `HttpRequest`.

### HTTP.client {#httpclient}

```signature
HTTP.client(options: HTTP.ClientOptions = HTTP.ClientOptions()) -> Result[HTTP.Client]
HTTP.close_client(client: HTTP.Client) -> Void
HTTP.proxy_from_env(url: String) -> String
```

Un cliente reutiliza las conexiones abiertas para el mismo esquema, host y puerto. Cada campo de `HTTP.ClientOptions` tiene el predeterminado que aparece en la tabla, así que `HTTP.ClientOptions(timeout_ms: 5000)` cambia uno y deja los demás, y `HTTP.client()` los usa todos.

| Opción | Predeterminado | Límite |
|---|---|---|
| `timeout_ms` | 30 s, por cada llamada completa | positivo |
| `connect_timeout_ms` | 10 s, para la conexión | positivo |
| `read_timeout_ms` | 300 s, para cada espera de bytes del cuerpo | 0 (sin límite) o positivo |
| `idle_timeout_ms` | 30 s, para las conexiones mantenidas | positivo |
| `max_connections` | 4, por host | positivo, como máximo 65536 |
| `max_body_bytes` | 1 MiB, para los cuerpos guardados en memoria | positivo, como máximo 64 MiB; un cuerpo mayor pasa por `download`, `read_body` u `open`, que no tienen límite |
| `proxy` | `""`: sin proxy | un origen `http://host:port`, ver abajo |
| `tls` | `none`: los certificados de CA del sistema | un `TLS.Context` de cliente |
| `connect_to` | `""`: resolver el host de la URL | una dirección IP, no con `proxy` |

- Los tres tiempos de espera, en una llamada:
  - `timeout_ms` es la llamada completa de `get`, `post` y `request`: la espera de un hueco, la conexión, la solicitud y la respuesta, con su bloque de cabeceras incluido. Para `open`, `start` y `upload` es el tiempo hasta el bloque de cabeceras de la respuesta (con la conexión incluida en `open`).
  - `connect_timeout_ms` acota la conexión dentro de él: DNS, TCP, el handshake de TLS y el `CONNECT` del proxy. Un servidor que no acepta la conexión termina la llamada tras `connect_timeout_ms`, sea cual sea `timeout_ms`; nunca tarda más que `timeout_ms`. Un tiempo de espera de la conexión tiene `details["phase"]` igual a `"connect"`, así que un programa lo distingue de un tiempo de espera de lectura, que tiene la misma clase (`net.timeout`).
  - `read_timeout_ms` es la espera más larga por los siguientes bytes de un cuerpo (y por cada fragmento de un `upload`, y por el bloque de cabeceras de un `download`), también dentro de `timeout_ms` en las llamadas completas. `0` es sin límite, para un flujo que puede quedarse en silencio: termina con el cuerpo, con `Task.cancel` o cuando el servidor lo cierra.
  - Un bloque de cabeceras que llega tarde se espera hasta `timeout_ms`, no hasta `read_timeout_ms`, así que un servidor que tarda un minuto en responder solo necesita `timeout_ms: 60000`.
- `connect_to` se conecta a esa dirección IP (IPv4, o IPv6 sin corchetes) en lugar de resolver el host de la URL, en cada llamada y en cada conexión del cliente. `Host`, el nombre de servidor de TLS y la comprobación del certificado mantienen el host de la URL, y el puerto es el de la URL. Se aplica a toda URL que alcanzan las opciones o el cliente, no a un solo host: usa un cliente por host, y tras una redirección a otro host resuelve y comprueba de nuevo con opciones nuevas. La dirección debe tener su forma estricta (IPv4 como cuatro números decimales sin cero inicial, IPv6 con como máximo 8 grupos y un `::`, y no una dirección IPv4 mapeada, así que pasa la propia dirección IPv4), porque el resolutor del sistema leería `012.0.0.1` como un número octal; un nombre de host, otra escritura, `0.0.0.0`, `::`, o `connect_to` junto con `proxy`, es un error de `argument`. El resolutor, la caché y el filtro de direcciones viven en el paquete `http-client`, no en `std/http`. Es la parte de bajo nivel de dos usos. Uno: una solicitud que no debe llegar a una dirección privada (SSRF): resuelve con `DNS.lookup`, rechaza las direcciones privadas, de loopback, link-local y reservadas, y luego pasa una dirección comprobada (tu filtro también debe clasificar las formas IPv6 compatibles con IPv4 (`::a.b.c.d`), NAT64 (`64:ff9b::/96`) y otras formas IPv6 traducidas, que llevan una dirección IPv4 a la que la red puede llegar; `connect_to` rechaza por sí mismo `0.0.0.0` y `::`), así que nunca se usa una respuesta de DNS que cambia en ese intervalo (rebinding). El otro: un resolutor propio, una caché de DNS o una dirección fija para un host (`--resolve` de curl): resuelve como quieras y luego pasa la dirección.
- Las llamadas esperan en orden FIFO por un hueco de `max_connections`. Una llamada en curso cuando se ejecuta `close_client` falla con `http: client is closed` (salvo que la conexión ya hubiera empezado a enviar la solicitud).
- `proxy` es un origen `http://host:port` sin ruta ni consulta; si no, la llamada es un `error`. Las solicitudes `http://` van a él en forma absoluta y comparten sus conexiones; una solicitud `https://` abre un túnel `CONNECT` (uno por host y puerto de destino) y habla TLS con el destino dentro de él, con la misma verificación que sin proxy. Esto vale para `HTTP.client` y para cada llamada que toma un cliente u opciones.
- La información de usuario de la URL (`http://user:password@proxy:8080`, con los porcentajes decodificados) se envía como `Proxy-Authorization: Basic` solo al proxy, salvo que la llamada ponga esa cabecera; en una llamada `https` tu propia cabecera va al destino. Ningún error muestra la información de usuario, y una `Connection` de `HTTP.start` imprime su proxy sin ella, pero las opciones que creaste sí la guardan, así que mantenlas fuera de los registros.
- Un `407` es `http: the proxy HOST:PORT refused the credentials (407)` (o `requires credentials` cuando la URL no tiene ninguna); otro estado en un `CONNECT` es `http: the proxy HOST:PORT refused the tunnel to HOST:PORT (STATUS)`. Dentro del túnel, cualquier estado del destino es una respuesta normal.
- Un cliente nunca lee el entorno: pasa `HTTP.proxy_from_env(url)`, que devuelve el proxy que el entorno indica para `url`, o `""` si no hay ninguno. Sigue las reglas de curl: `http_proxy` o `https_proxy` según el esquema, y gana el nombre en minúsculas aunque esté definido y vacío; `HTTP_PROXY` se ignora cuando `REQUEST_METHOD` está definido (httpoxy); `ALL_PROXY` no se lee; `no_proxy` (o `NO_PROXY`) es una lista separada por comas o espacios de `*`, dominios, `:port` opcional, literales IP y rangos CIDR IPv4 (no se leen los rangos IPv6; los elementos vacíos e inválidos se ignoran; un punto final en un host o en un elemento no cuenta). Un valor sin `://` se lee como `http://`; una `url` inválida da `""`.
- El cliente se ejecuta como código de Agentica en sus propias tareas, así que gasta el presupuesto de `--max-steps` de la ejecución.

```agentica {mode="check"}
import HTTP from "std/http"

def main() -> Void
  client = HTTP.client(HTTP.ClientOptions(timeout_ms: 5000, max_connections: 2)).unwrap!
  HTTP.close_client(client)
end
```

Los clientes que confían en el mismo archivo de CA comparten un contexto: créalo una vez y pásalo a cada uno.

```agentica {mode="check"}
import HTTP from "std/http"

def main() -> Void
  tls = TLS.client_context(TLS.ClientOptions(ca_file: "ca.pem")).unwrap!
  client = HTTP.client(HTTP.ClientOptions(tls: some(tls))).unwrap!
  HTTP.close_client(client)
end
```

### HTTP.get, HTTP.post y HTTP.request {#httpget-httppost-and-httprequest}

```signature
HTTP.get(client: HTTP.Client, url: String) -> Result[HTTP.Response]
HTTP.post(client: HTTP.Client, url: String, body: Bytes, headers: List[HTTP.Header] = []) -> Result[HTTP.Response]
HTTP.request(client: HTTP.Client, method: String, url: String, body: Bytes, headers: List[HTTP.Header] = []) -> Result[HTTP.Response]
HTTP.get_response(url: String, options: HTTP.ClientOptions = HTTP.ClientOptions()) -> Result[HTTP.Response]
HTTP.post_response(url: String, body: Bytes, headers: List[HTTP.Header] = [], options: HTTP.ClientOptions = HTTP.ClientOptions()) -> Result[HTTP.Response]
```

- `HTTP.Response` tiene `status`, `headers` (nombres en minúsculas) y `body`, que es `Bytes`. `post` envía un cuerpo `Bytes`, como hace `Net::HTTP.post(uri, data, header)` de Ruby, y `request` acepta cualquier método. Envía texto como `"text".bytes`, y ningún cuerpo como `"".bytes`. El cuerpo tiene como máximo `max_body_bytes`, y `headers` vale `[]` de forma predeterminada.
- Para una sola solicitud usa `get_response` y `post_response`, como `Net::HTTP.get_response` y `Net::HTTP.post` de Ruby: cada una crea un cliente con `options`, hace la llamada y cierra el cliente y su conexión antes de devolver, así que no necesita `client` ni `close_client`. Para muchas solicitudes usa un único `HTTP.client()` con `get`, `post` y `request`, que reutiliza conexiones; llamar a `get_response` en un bucle abre una conexión cada vez, y sobre HTTPS además crea un contexto TLS nuevo y carga el paquete de CA cada vez.
- Cuando se cancela una tarea mientras una de estas llamadas espera su respuesta, la conexión de la llamada se cierra, en texto plano o TLS: el servidor ve el cierre, y la conexión del cliente no vuelve al pool.
- Las URL empiezan con `http://` o `https://`. Un host entre corchetes (`http://[::1]:8080/`) debe parecer una dirección IPv6; si no, el resultado es un error. El cliente no comprueba la longitud de la línea de solicitud (método, destino y versión): un destino largo se envía tal cual, y un servidor con un límite menor, como `HTTP.serve` (8192 bytes), puede rechazarlo.
- El cliente añade `Host` y `Content-Length`; una solicitud no puede ponerlas, ni `Transfer-Encoding` ni `Connection`.

```agentica {mode="check"}
import HTTP from "std/http"

def main() -> Void
  client = HTTP.client().unwrap!
  headers = [HTTP.Header(name: "Content-Type", value: "application/json")]
  case HTTP.post(client, "http://localhost:8080/items", "{\"name\":\"tea\"}".bytes, headers)
    ok(created) -> puts("#{created.status} #{HTTP.text(created.body, created.headers).unwrap!}")
    error(e) -> IO.warn(e.message)
  end

  deleted = HTTP.request(client, "DELETE", "http://localhost:8080/items/1", "".bytes)
  puts(deleted.ok?)
  HTTP.close_client(client)
end
```

Una solicitud, sin cliente que abrir ni cerrar:

```agentica {mode="check"}
import HTTP from "std/http"

def main() -> Void
  case HTTP.get_response("http://localhost:8080/items", HTTP.ClientOptions(timeout_ms: 5000))
    ok(response) -> puts("#{response.status} #{HTTP.text(response.body, response.headers).unwrap!}")
    error(e) -> IO.warn(e.message)
  end
end
```

### HTTP.text {#httptext}

```signature
HTTP.text(body: Bytes, headers: List[HTTP.Header] = []) -> Result[String]
```

Decodifica un cuerpo como texto. Pasa los `headers` del mismo mensaje: el cuerpo se lee con el `charset` de su `Content-Type` (en mayúsculas o minúsculas, con o sin comillas), y como UTF-8 cuando no hay ninguno. Los juegos de caracteres son las codificaciones de [`Bytes.decode`](/library/data-structures/bytes/#decode): UTF-8, UTF-16, UTF-32, ASCII, Latin-1 (`iso-8859-1`), ISO-8859-15 y Windows-1252, con cualquiera de sus nombres. Un cuerpo que no es válido en su juego de caracteres es un resultado `error` (con el desplazamiento del byte, salvo en UTF-8), y cualquier otro juego (`shift_jis`, `koi8-r`) es un `error` que lo nombra. Los demás juegos de caracteres pertenecen al paquete previsto `agentica-lang/charset`.

```agentica
import HTTP from "std/http"

def main() -> Void
  utf8 = [HTTP.Header(name: "content-type", value: "text/plain; charset=UTF-8")]
  latin1 = [HTTP.Header(name: "content-type", value: "text/plain; charset=iso-8859-1")]
  koi8 = [HTTP.Header(name: "content-type", value: "text/plain; charset=koi8-r")]
  puts(HTTP.text("café".bytes, utf8).unwrap!)
  puts(HTTP.text("caf".bytes + Bytes.from_list([233]).unwrap!, latin1).unwrap!)
  puts(HTTP.text("caf".bytes, koi8).ok?)
  puts(HTTP.text(Bytes.from_list([255, 0, 128]).unwrap!).ok?)
end
```

```output
café
café
false
false
```

### HTTP.header_values {#httpheader_values}

```signature
HTTP.header_values(headers: List[HTTP.Header], name: String) -> List[String]
```

Encuentra cada valor de una cabecera, en orden. No distingue mayúsculas.

```agentica
import HTTP from "std/http"

def main() -> Void
  headers = [HTTP.Header(name: "set-cookie", value: "a=1"), HTTP.Header(name: "Set-Cookie", value: "b=2")]
  puts(HTTP.header_values(headers, "Set-Cookie"))
end
```

```output
["a=1", "b=2"]
```

### HTTP.download {#httpdownload}

```signature
HTTP.download(client: HTTP.Client, url: String, path: String, options: DownloadOptions = DownloadOptions()) -> Result[Download]
```

- `DownloadOptions` tiene `timeout_ms`, para la llamada completa, `max_total_bytes`, para el cuerpo, y `sha256`, el resumen criptográfico en hexadecimal que debe tener el cuerpo. Cada uno es un `Optional` cuyo valor predeterminado es `none`: sin límite de tamaño, sin comprobación de resumen y sin límite de tiempo (en la práctica, un plazo de un año). Un valor que se fija debe ser positivo, sin máximo, y un resumen tiene 64 dígitos hexadecimales. `connect_timeout_ms` del cliente sigue acotando la conexión, y su `read_timeout_ms` limita cada espera del bloque de cabeceras y de los bytes del cuerpo, así que un servidor silencioso termina la llamada. `Download` tiene `status`, `headers` y `bytes_written`; el cuerpo en sí está en el archivo, nunca en el registro.
- Un `Download` impreso toma el alias con el que el programa importa `std/http`, mientras que un registro integrado conserva su nombre fijo: con `import H from "std/http"`, se imprime como `H.Download(status: 200, headers: [HTTP.Header(...)], ...)`.
- La descarga envía un `GET` y va guardando el cuerpo, con como máximo 1 MiB en memoria a la vez, en un archivo nuevo y oculto de la carpeta de `path`, con el nombre `.<name>.<8 hex digits>.agc-part` (como máximo 32 caracteres del nombre). El archivo nunca crece más allá de `max_total_bytes`.
- Solo un cuerpo que termina bien y tiene el resumen `sha256` llega a `path`, mediante [`Path.replace`](/library/io-and-system/files/#pathreplace): en un solo paso, así que `path` siempre nombra el archivo viejo o el nuevo. Un archivo existente en `path` se reemplaza, y también un enlace simbólico, que no se sigue (a diferencia de `File.replace`). El archivo nuevo es privado del usuario (`0600`) y no conserva el modo del archivo viejo. Un directorio en `path` es un error y se queda como estaba.
- Un fallo (una conexión cortada, un tiempo de espera, un cuerpo por encima de `max_total_bytes`, un resumen incorrecto, que es `http.digest`) quita el archivo nuevo y deja `path` como estaba. La única excepción es un tiempo de espera durante el último paso: el reemplazo puede terminar igual, así que `path` es entonces el archivo viejo o el nuevo completo. Una tarea cancelada durante la descarga, un programa que se detiene a la fuerza, o un tiempo de espera mientras se crea el archivo nuevo pueden dejar el archivo `.agc-part`; un programa que cancela descargas limpia esos nombres por su cuenta. Los códigos de estado como 404 son respuestas normales cuyo cuerpo se escribe igual, así que comprueba `status` antes de usar el archivo.
- La conexión no va al pool: se cierra cuando termina la descarga. No hay seguimiento de redirecciones, y `https` mantiene la comprobación del certificado.
- Con `sha256`, el cuerpo de un estado de error (una página `404`, un `503`) falla como `http.digest`, lo que oculta el estado: para reintentar un `5xx`, descarga sin `sha256`, comprueba `status`, luego el resumen (`File.sha256`) y usa `Path.replace` para poner el archivo en su sitio. Para seguir una redirección (las descargas de GitHub y Hugging Face responden `302`), envía primero solicitudes `HEAD` y sigue `Location` hasta la URL final.

```agentica {mode="check"}
import HTTP from "std/http"

def main() -> Void
  client = HTTP.client().unwrap!
  digest = "88d4266fd4e6338d13b845fcf289579d209c897823b9217da3e161936f031589"
  case HTTP.download(client, "http://localhost:8080/asset", "asset.bin", HTTP.DownloadOptions(sha256: some(digest)))
    ok(saved) -> puts("#{saved.status} #{saved.bytes_written}")
    error(e) -> IO.warn(e.message)
  end

  HTTP.close_client(client)
end
```

### HTTP.start, HTTP.send_request, HTTP.read_body y HTTP.finish {#httpstart-httpsend_request-httpread_body-and-httpfinish}

```signature
HTTP.start(origin: String, options: HTTP.ClientOptions = HTTP.ClientOptions()) -> Result[HTTP.Connection]
HTTP.send_request(conn: HTTP.Connection, method: String, target: String, body: Bytes, headers: List[HTTP.Header] = []) -> Result[HTTP.ResponseHead]
HTTP.read_body(conn: HTTP.Connection, max_bytes: Int = 65536) -> Result[Bytes]
HTTP.finish(conn: HTTP.Connection) -> Void
```

Una conexión que el programa maneja por sí mismo, fuera del pool, como hacen `Net::HTTP.start`, `send_request`, `read_body` y `finish` de Ruby (y `http.client.HTTPConnection` de Python). Úsala para leer un cuerpo fragmento a fragmento, según llega (un archivo grande, un registro que no termina, las líneas de un flujo), o para controlar la conexión: qué solicitudes van por un socket y cuándo se cierra. Para respuestas completas usa `get` y el cliente con pool, que son más simples.

- `start` toma un origen (`http://host`, `https://host:8443`) sin ruta ni consulta, y conecta en ese momento. `https` verifica el certificado con `options.tls` (los certificados de confianza del sistema cuando es `none`, que se vuelven a crear en cada `start`, así que un programa que abre muchas conexiones pasa `tls: some(context)`). De las opciones, solo se aplican `connect_timeout_ms`, `timeout_ms`, `read_timeout_ms`, `max_body_bytes`, `tls` y `proxy`: `connect_timeout_ms` acota la conexión (dentro de `timeout_ms`), `timeout_ms` cada `send_request` (la escritura y el bloque de cabeceras) y `read_timeout_ms` cada `read_body`; `max_body_bytes` es el tamaño máximo del cuerpo de la solicitud.
- `send_request` envía la solicitud y devuelve cuando se ha leído el bloque de cabeceras de la respuesta: `HTTP.ResponseHead` tiene `status` y `headers` (nombres en minúsculas). `target` es la ruta y la consulta (`/items?page=2`). Se añaden `Host` y `Content-Length`; las reglas de cabeceras son las de `HTTP.request`. Un bloque `1xx` provisional se lee y se salta.
- `read_body` espera al menos un byte y devuelve como máximo `max_bytes` (de 1 a 1 MiB) del cuerpo, decodificado (un cuerpo en trozos no lleva enmarcado). Un `Bytes` vacío es el final del cuerpo. Un cuerpo con `Content-Length` se ajusta a su longitud, uno en trozos a su enmarcado, y un cuerpo que llega hasta el cierre de la conexión debe terminar con un cierre limpio (sobre TLS, el `close_notify` del peer). Un cuerpo de respuesta no tiene límite de tamaño, sea cual sea su enmarcado: el programa lo lee fragmento a fragmento y para cuando quiere. Una respuesta a `HEAD`, un `204`, un `304` y una con `Content-Length: 0` no tienen cuerpo: la conexión está lista de inmediato, sin necesidad de `read_body` (un `read_body` devuelve el fragmento final vacío).
- Cuando un cuerpo se ha leído hasta el final, la conexión está lista para el siguiente `send_request`, salvo que el servidor la haya cerrado (`Connection: close`, una respuesta HTTP/1.0 sin `Connection: keep-alive`, o un cuerpo que llegó hasta el cierre): entonces `send_request` es `error("http: the connection is closed")`. El final llega con el último byte, así que un programa que conoce la longitud puede dejar de leer antes del fragmento vacío. La conexión también se cierra cuando queda entrada después del cuerpo (un servidor que envió una segunda respuesta en la misma escritura, o bytes después del último trozo): leer su respuesta a la siguiente solicitud sería incorrecto. Una solicitud mientras se sigue leyendo el último cuerpo es un `error`, y la conexión queda como estaba.
- Un fallo de la conexión (un cuerpo cortado, un trozo malo, un tiempo de espera, una escritura que falla) es un `error` y la termina. Una solicitud rechazada antes de escribir nada (un método, cabecera o destino malos, o un cuerpo por encima de `max_body_bytes`) también es un `error`, y la conexión queda como estaba. Un servidor que cerró una conexión inactiva se ve como un `error` del siguiente `send_request`: abre una nueva con `start`; no se reintenta nada.
- `finish` cierra el socket, descarta un cuerpo no leído hasta el final, y puede llamarse dos veces. La conexión pertenece a la tarea que la abrió (como un socket), y una llamada a la vez la usa: una segunda llamada al mismo tiempo es `error("http: the connection is in use by another call")`.
- No hay seguimiento de redirecciones, cookies ni descompresión: un programa que las necesite recorre `send_request` en un bucle.

```agentica {mode="check"}
import HTTP from "std/http"

def main() -> Void
  conn = HTTP.start("http://localhost:8080").unwrap!
  head = HTTP.send_request(conn, "GET", "/log", "".bytes).unwrap!
  puts(head.status)
  total = 0
  while true
    piece = HTTP.read_body(conn, 4096).unwrap!
    break if piece.empty?

    total = total + piece.size
  end

  puts(total)
  next_head = HTTP.send_request(conn, "GET", "/other", "".bytes)
  puts(next_head.ok?)
  HTTP.finish(conn)
end
```

### HTTP.open y HTTP.upload {#httpopen-and-httpupload}

```signature
HTTP.open(method: String, url: String, body: Bytes, headers: List[HTTP.Header] = [], options: HTTP.ClientOptions = HTTP.ClientOptions()) -> Result[HTTP.Stream]
HTTP.upload(method: String, url: String, body: Channel[Bytes], length: Int = -1, headers: List[HTTP.Header] = [], options: HTTP.ClientOptions = HTTP.ClientOptions()) -> Result[HTTP.Response]
```

Las dos formas para un cuerpo que pasa por un canal, para que otra tarea lo use según llega: una descarga demasiado grande para retenerla, una interminable (eventos, las líneas de un registro), o una subida que se genera sobre la marcha. Cada llamada usa una conexión propia, fuera del pool, construida sobre [`HTTP.start`](#httpstart-httpsend_request-httpread_body-and-httpfinish). Una llamada cuyo cuerpo entero cabe en memoria es más simple con `get`, `post` y `request`.

- `open` envía la solicitud y devuelve al leer el bloque de cabeceras de la respuesta: `HTTP.Stream` tiene `status`, `headers`, `body` (un `Channel[Bytes]`) y `done` (un `Task[Result[Void]]`). Una tarea alimenta `body` con los fragmentos de la respuesta (como máximo 64 KiB, nunca vacíos, un cuerpo en trozos ya decodificado) y lo cierra en todos los caminos. `url` tiene ruta y consulta; `method`, `body` y `headers` son los de `request`.
- El lector ejecuta el bucle de recepción habitual hasta el error de canal cerrado, y luego espera `done`: `ok` significa que el cuerpo terminó limpiamente, y un `error` dice por qué no (un cuerpo cortado, un tiempo de espera, un trozo malo). El cuerpo no tiene límite de tamaño. Un canal solo puede terminar, así que `done` es la única forma de distinguir un cuerpo completo de uno cortado: espéralo siempre.
- Para parar antes, cierra `body`: el siguiente `send` de la tarea que alimenta falla, cierra la conexión y `done` es `error("channel: closed")`. Eso solo funciona mientras fluyen datos. En un flujo silencioso (un servidor que no tiene nada que decir) la tarea espera en su lectura hasta `read_timeout_ms` (para siempre si vale 0), así que la parada rápida es `Task.cancel(stream.done)`: cierra la conexión de inmediato y `done` es un error.
- `options.timeout_ms` es el tiempo de `open` hasta que llega el bloque de cabeceras, con la conexión incluida (la conexión en sí tarda como máximo `connect_timeout_ms`), así que un servidor que no responde se da por fallido tras `timeout_ms`, y uno que no acepta la conexión tras `connect_timeout_ms`. Después del bloque de cabeceras, `read_timeout_ms` es el tiempo de cada espera: cada lectura del cuerpo y cada `send` al canal. Un lector que tarde más que eso en pedir el siguiente fragmento termina el flujo, y también lo hace un servidor en silencio durante ese tiempo. Para eventos que llegan poco, sube `read_timeout_ms`, o ponlo a `0` para no tener límite (`HTTP.ClientOptions(timeout_ms: 5000, read_timeout_ms: 0)`); para parar el flujo, usa `Task.cancel(stream.done)`. El canal guarda 8 fragmentos, así que un lector lento hace esperar a la tarea y los datos del servidor esperan en el socket.
- `upload` envía los fragmentos que otra tarea pone en `body`, hasta que cierra el canal, y devuelve la respuesta completa (como `request`: hasta `max_body_bytes`). `method` es `POST`, `PUT` o `PATCH`. `length` es el número exacto de bytes, indicado como `Content-Length`: el cuerpo termina cuando se han enviado esos bytes, y el productor no tiene que cerrar el canal. `-1` es un cuerpo en trozos, cuyos fragmentos se convierten en trozos (un fragmento de más de 512 KiB se divide en varios, y los fragmentos que esperan juntos en el canal comparten uno, de menos de 64 KiB más un fragmento) y que termina cuando se cierra el canal. Un cuerpo más largo que `length`, o un canal que se cierra antes de llegar a ese número, es un `error`, y también lo es un canal en silencio durante más que `read_timeout_ms`.
- Un canal que se cierra termina el cuerpo, también cuando su productor ha fallado: un productor que puede fallar debe fijar `length`, para que un cuerpo corto sea un `error`. `upload` cierra el canal al devolver, así que un productor que aún envía encuentra el error de canal cerrado y se detiene.
- Un servidor que responde y cierra antes de que termine la subida (un `413`) no oculta su respuesta: cuando falla una escritura, `upload` lee el bloque de cabeceras de la respuesta que está esperando (como máximo `timeout_ms`) y devuelve esa respuesta, como hacen `http.client` de Python y Go. Solo cuando no hay ninguna, el fallo de escritura es el `error` (`http: ` y el motivo): en Windows, una conexión reiniciada puede perder la respuesta temprana del servidor, así que allí `upload` devuelve el error de escritura. No se reintenta nada, y ninguna de las dos llamadas sigue redirecciones.

```agentica {mode="check"}
import HTTP from "std/http"

def produce(into: Channel[Bytes]) -> Void
  _ = into.send("line 1\n".bytes, 1000)
  _ = into.send("line 2\n".bytes, 1000)
  into.close
end

def main() -> Void
  stream = HTTP.open("GET", "http://localhost:8080/log", "".bytes).unwrap!
  total = 0
  while true
    case stream.body.recv(5000)
      ok(piece) -> total = total + piece.size
      error(_) -> break
    end
  end

  puts(total)
  puts(Task.await(stream.done).ok?)
  lines: Channel[Bytes] = Channel.new(2)
  Task.spawn(&produce, lines)
  response = HTTP.upload("PUT", "http://localhost:8080/log", lines).unwrap!
  puts(response.status)
end
```

## Servidor HTTP {#http-server}

El servidor también está en `std/http`. `serve` atiende todas las clases de ruta en un puerto: páginas, archivos enviados por fragmentos, subidas y WebSockets. Ejecuta una tarea por conexión, con keep-alive.

### HTTP.serve {#httpserve}

```signature
HTTP.serve(host: String, port: Int, app: HTTP.App, options: HTTP.ServerOptions = HTTP.ServerOptions()) -> Result[HTTP.Server]
HTTP.serve_tls(host: String, port: Int, tls: TLS.Context, app: HTTP.App, options: HTTP.ServerOptions = HTTP.ServerOptions()) -> Result[HTTP.Server]
HTTP.app(handler: HTTP.Handler, max_body_bytes: Int = 1048576) -> HTTP.App
HTTP.local_port(server: HTTP.Server) -> Int
```

- `serve` devuelve de inmediato y atiende en segundo plano; `serve_tls` hace lo mismo sobre TLS con un `TLS.Context` de servidor (`TLS.server_context`). El puerto 0 elige un puerto libre (`local_port`).
- La aplicación, un `HTTP.App`, decide para cada solicitud cómo leer el cuerpo y cómo responder. `HTTP.App` es `Fn[HTTP.Request, HTTP.RequestBody, Result[HTTP.Answer]]`: recibe la solicitud con un `body` vacío y el cuerpo en un canal ([cuerpos de solicitud](#request-bodies)).
- `HTTP.Answer` es un enum. `Answer.Whole(response)` responde con un `HTTP.Response`. `Answer.Stream(response)` envía un `HTTP.StreamResponse`, cuyo cuerpo llega por un canal ([respuestas en flujo](#streamed-responses-and-server-sent-events)). `Answer.Upgrade(upgrade)` toma lo que devuelve [`accept_websocket`](#websockets): su `Accept` ejecuta el WebSocket en la conexión, y su `Reply` se envía como `Whole`.
- `HTTP.app(handler, max_body_bytes)` crea una `App` a partir de un `Handler`, para rutas que toman la solicitud completa. Primero lee el cuerpo, como máximo `max_body_bytes` (1 MiB si no se indica, sea cual sea el tope del servidor; un límite negativo cuenta como 0), y llama a `handler` con él. Un cuerpo más grande, por su `Content-Length` o según llega, recibe un `413`; una línea de trozo o una sección de trailer por encima de los límites del bloque de cabeceras recibe un `431`, y un trozo malo un `400`. Estas respuestas llevan `Connection: close`, y no se llama a `handler`. Un cuerpo que se corta o se atasca (el cliente se marchó, un tiempo de espera) cierra la conexión.
- `HTTP.Request` tiene `method`, `target` (tal como se envió, con la consulta), `path` (antes de `?`), `headers` (nombres en minúsculas), `body` (`Bytes`, exactamente como lo envió el cliente, sea cual sea el enmarcado; decodifica el texto con [`HTTP.text`](#httptext) y `request.headers`) y `remote_addr`, la dirección IP del cliente sin el puerto (`"127.0.0.1"`, `"::1"`, como la da [`TCP.remote_address`](#tcpremote_address); como `REMOTE_ADDR` de Rack). El servidor rellena `remote_addr`; detrás de un proxy es la dirección del proxy. Su valor predeterminado es `""` en `HTTP.Request(...)`.

Un servidor que pide su propia página:

```agentica
import HTTP from "std/http"

def handle(request: HTTP.Request) -> Result[HTTP.Response]
  if request.method == "GET" and request.path == "/"
    return ok(
      HTTP.Response(
        status: 200,
        headers: [HTTP.Header(name: "Content-Type", value: "text/plain; charset=utf-8")],
        body: "hello".bytes,
      ),
    )
  end

  ok(HTTP.Response(status: 404, headers: [], body: "not found".bytes))
end

def main() -> Void
  server = HTTP.serve("127.0.0.1", 0, HTTP.app(&handle)).unwrap!
  client = HTTP.client().unwrap!
  base = "http://127.0.0.1:#{HTTP.local_port(server)}"
  response = HTTP.get(client, base + "/").unwrap!
  puts("#{response.status} #{HTTP.text(response.body, response.headers).unwrap!}")
  puts(HTTP.get(client, base + "/missing").unwrap!.status)
  HTTP.close_client(client)
  HTTP.close_server(server)
end
```

```output
200 hello
404
```

El servidor añade `Content-Length` (no en 204 ni 304, cuyo cuerpo debe estar vacío), una cabecera `Date` salvo que el handler haya puesto una, y `Connection: close` cuando la solicitud o la respuesta lo pidieron. `HEAD` recibe las cabeceras sin el cuerpo.

Un servidor con una página, un archivo enviado por fragmentos, una subida y un WebSocket en un mismo puerto:

```agentica {mode="check"}
import HTTP from "std/http"

def page(request: HTTP.Request) -> Result[HTTP.Response]
  ok(HTTP.Response(status: 200, headers: [], body: "hello".bytes))
end

def produce(pieces: Channel[Bytes]) -> Void
  for n in 1..4
    break if not Result.ok?(pieces.send("part #{n}\n".bytes, 5000))
  end

  pieces.close
end

def file() -> HTTP.Answer
  pieces: Channel[Bytes] = Channel.new(2)
  Task.spawn(&produce, pieces)
  HTTP.Answer.Stream(HTTP.StreamResponse(status: 200, headers: [], body: pieces, length: some(28)))
end

def upload(body: HTTP.RequestBody) -> Result[HTTP.Answer]
  total = 0
  while true
    case body.pieces.recv(5000)
      ok(piece) -> total = total + piece.size
      error(_) -> break
    end
  end

  try Task.await(body.done)
  ok(HTTP.Answer.Whole(HTTP.Response(status: 200, headers: [], body: "#{total} bytes".bytes)))
end

def echo(ws: HTTP.WebSocket) -> Result[Void]
  while true
    case ws.incoming.recv(60000)
      ok(HTTP.Message.Text(text)) -> try ws.outgoing.send(HTTP.Message.Text(text), 5000)
      ok(HTTP.Message.Close(_, _)) -> return ok()
      ok(_) -> next
      error(_) -> return ok()
    end
  end

  ok()
end

def route(request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  return ok(HTTP.Answer.Upgrade(try HTTP.accept_websocket(request, &echo))) if request.path == "/ws"

  return ok(file()) if request.path == "/file"

  return upload(body) if request.path == "/upload"

  HTTP.app(&page).call(request, body)
end

def main() -> Void
  server = HTTP.serve("127.0.0.1", 8080, &route).unwrap!
  HTTP.wait(server).unwrap!
end
```

#### Handler y middleware {#handler-and-middleware}

`HTTP.Handler` es el tipo de una ruta que toma la solicitud completa: `Fn[HTTP.Request, Result[HTTP.Response]]`. `HTTP.App` es el tipo de la aplicación de `serve`. Son alias de tipo, así que `&handle` es un `Handler` cuando `handle` tiene esa forma, y un framework puede guardar, almacenar y devolver handlers con ese nombre.

Un middleware es una función de un `Handler` a un `Handler`: envuelve el siguiente handler, y puede cambiar la solicitud antes de él, o la respuesta después, o responder sin llamarlo. Una [lambda](/tour/blocks/#lambdas) que captura el siguiente handler es el nuevo. Los middlewares se apilan llamando a uno con el resultado de otro. Un middleware de una `App` es una función de una `App` a otra `App`, de la misma forma.

```agentica
import HTTP from "std/http"

def hello(request: HTTP.Request) -> Result[HTTP.Response]
  ok(HTTP.Response(status: 200, headers: [], body: "hello".bytes))
end

def log_answer(next: HTTP.Handler, request: HTTP.Request) -> Result[HTTP.Response]
  response = next.call(request)
  case response
    ok(answer) -> puts("#{request.method} #{request.path} #{answer.status}")
    error(_) -> puts("#{request.method} #{request.path} failed")
  end

  response
end

# Logs the request line and the status of the answer; an error of the next handler passes through unchanged.
def logged(next: HTTP.Handler) -> HTTP.Handler = ->(request) { log_answer(next, request) }

def authorized(next: HTTP.Handler, request: HTTP.Request) -> Result[HTTP.Response]
  if HTTP.header_values(request.headers, "authorization").empty?
    return ok(HTTP.Response(status: 401, headers: [], body: "".bytes))
  end

  next.call(request)
end

# Answers 401 to a request without an Authorization header, and does not call the next handler.
def guarded(next: HTTP.Handler) -> HTTP.Handler = ->(request) { authorized(next, request) }

def main() -> Void
  app = logged(guarded(&hello))
  open = HTTP.Request(method: "GET", target: "/", path: "/", headers: [], body: "".bytes)
  signed = HTTP.Request(
    method: "GET",
    target: "/",
    path: "/",
    headers: [HTTP.Header(name: "authorization", value: "token")],
    body: "".bytes,
  )

  _ = app.call(open)
  _ = app.call(signed)
end
```

```output
GET / 401
GET / 200
```

Errores de la aplicación y de los handlers:

- Una aplicación o un handler que devuelve `error(message)` da al cliente un 500 con cuerpo vacío y cierra la conexión. stderr recibe `http: handler error: <message>`.
- Una respuesta que no se puede enviar recibe el mismo 500 y cierre, con `http: invalid response: <reason>` en stderr: un estado fuera del rango 200 a 599, una cabecera mala, una cabecera `Content-Length` o `Transfer-Encoding`, o un cuerpo con 204 o 304.
- Un error de runtime en una aplicación o un handler termina solo su conexión. El programa sigue, pero sale con código 1 al final, como ocurre con cualquier fallo de una tarea sin esperar.

Cada campo de `HTTP.ServerOptions` tiene el predeterminado que aparece abajo, así que `HTTP.ServerOptions(max_connections: 16)` cambia uno, y una llamada sin `options` los usa todos. Se aplican las mismas comprobaciones que a las opciones del cliente.

| Opción | Predeterminado | Límites |
|---|---|---|
| `request_timeout_ms` | 30 s | la primera solicitud de una conexión, cada solicitud completa desde su primer byte y el envío de cada respuesta (la aplicación no tiene límite de tiempo) |
| `idle_timeout_ms` | 30 s | la espera entre solicitudes en una conexión mantenida |
| `max_connections` | 128 | las conexiones por encima de ese número esperan hasta que una se cierre |
| `max_body_bytes` | 1 MiB | como máximo 256 MiB; un cuerpo leído completo ocupa unas cuatro veces esto en memoria por conexión, así que baja `max_connections` cuando lo subas |

Las solicitudes mal formadas nunca llegan a la aplicación: el servidor responde y cierra la conexión.

| Estado | Causa |
|---|---|
| 400 | mal formada |
| 413 | un cuerpo por encima de `max_body_bytes` |
| 417 | un `Expect` distinto de `100-continue` |
| 431 | una línea de solicitud de más de 8192 bytes (método, destino y versión), o cabeceras demasiado largas o demasiadas |
| 501 | `CONNECT`, o un `Upgrade` distinto de un handshake de WebSocket |
| 505 | distinto de `HTTP/1.1` |

Antes de cerrar, el servidor descarta hasta 256 KiB de la entrada restante del peer, para que la respuesta no se pierda por un reinicio. Un cliente que sigue enviando un cuerpo grande tras un 413 puede ver en cambio un reinicio de la conexión.

### Cuerpos de solicitud {#request-bodies}

```signature
HTTP.read_all(body: HTTP.RequestBody, max_bytes: Int) -> Result[Bytes]
HTTP.body_refusal(message: String) -> HTTP.Answer
```

La aplicación recibe el cuerpo en un canal, así que una subida demasiado grande para retenerla, o una que la aplicación guarda según llega (un archivo), nunca tiene que estar entera en memoria. Es el lado servidor de [`HTTP.upload`](#httpopen-and-httpupload).

- `HTTP.RequestBody` tiene `pieces` (un `Channel[Bytes]`) y `done` (un `Task[Result[Void]]`). Una tarea del servidor alimenta `pieces` con el cuerpo según llega (hasta 64 KiB cada fragmento, nunca vacío, un cuerpo en trozos ya decodificado) y lo cierra en todos los caminos. Una solicitud sin cuerpo recibe de inmediato un canal cerrado.
- La aplicación ejecuta el bucle de recepción habitual hasta el error de canal cerrado, y luego espera `done`: `ok` significa que llegó el cuerpo entero, y un `error` dice por qué no (el cliente se marchó, un trozo malo, un tiempo de espera, un cuerpo por encima del tope). Un canal solo puede terminar, así que `done` es la única forma de distinguir un cuerpo entero de uno cortado: espéralo siempre. Cuando `done` se cancela, con `close_server` o por la propia aplicación, vale `error("task: cancelled")` y la solicitud no recibe respuesta: la conexión se cierra. Para detener una subida antes de tiempo, responde (un `413`, por ejemplo) sin leer el resto y sin cancelar `done`: el servidor envía la respuesta y cierra la conexión.
- El canal guarda 8 fragmentos. Una aplicación que lee despacio hace esperar al servidor, y los datos del cliente esperan en el socket, así que la memoria se mantiene acotada.
- Cada cuerpo tiene como máximo `max_body_bytes` de `options` (valor predeterminado: 1 MiB; súbelo, hasta 256 MiB, para subidas). `HTTP.app` conserva su propio límite (1 MiB si no se indica), así que una ruta bajo él que acepta cuerpos mayores sube los dos. Una solicitud cuyo `Content-Length` es mayor recibe un `413` antes de que se ejecute la aplicación, sin un `100 Continue` previo, así que un cliente que lo espera nunca envía el cuerpo. Un cuerpo en trozos que crece más allá del tope termina `done` con el error de `read_all`, que `HTTP.app` responde con `413`.
- `Expect: 100-continue` dentro del tope recibe un `100` antes de que se ejecute la aplicación, así que una aplicación no puede rechazar una subida antes de que el cliente envíe el cuerpo.
- `request_timeout_ms` es la espera de cada paso (cada lectura del socket, y cada fragmento que la aplicación aún no ha tomado), no el tiempo de la subida completa.
- La conexión atiende la siguiente solicitud solo cuando el cuerpo entero había llegado al devolver la aplicación, lo lea o no: una solicitud sin cuerpo o con un cuerpo en trozos vacío la conserva. Si no (una aplicación que responde antes, con un `413` o un `401`, o un cuerpo que falló), la respuesta lleva `Connection: close` y la conexión se cierra después, así que un cliente que sigue enviando puede ver el cierre antes de leer la respuesta.
- `HTTP.read_all(body, max_bytes)` reúne el cuerpo para una ruta que lo quiere completo: devuelve los fragmentos unidos como un `Result[Bytes]`, o un `error` cuando el cuerpo es más largo que `max_bytes` o que el tope, o no llegó entero (espera `done`).
- `HTTP.body_refusal(message)` es la respuesta para ese error: `413` para un cuerpo por encima de su límite, `431` para una línea de trozo o una sección de trailer por encima de los límites del bloque de cabeceras, y `400` para cualquier otro (un trozo malo, un cuerpo cortado o atascado), una respuesta completa con `Connection: close` y sin cuerpo. `HTTP.app` responde así a un `Handler`; una ruta que lee el cuerpo por sí misma devuelve `ok(HTTP.body_refusal(message))`, como hace la ruta de flujo de más abajo.

Un servidor que cuenta una subida, y la llamada del cliente que se la envía por flujo:

```agentica
import HTTP from "std/http"

def count(request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  total = 0
  while true
    case body.pieces.recv(5000)
      ok(piece) -> total = total + piece.size
      error(_) -> break
    end
  end

  try Task.await(body.done)
  ok(HTTP.Answer.Whole(HTTP.Response(status: 200, headers: [], body: "#{total} bytes".bytes)))
end

def feed(into: Channel[Bytes]) -> Void
  _ = into.send("hello ".bytes, 1000)
  _ = into.send("world".bytes, 1000)
  into.close
end

def main() -> Void
  server = HTTP.serve("127.0.0.1", 0, &count).unwrap!
  into: Channel[Bytes] = Channel.new(2)
  Task.spawn(&feed, into)
  url = "http://127.0.0.1:#{HTTP.local_port(server)}/"
  response = HTTP.upload("PUT", url, into).unwrap!
  puts("#{response.status} #{HTTP.text(response.body, response.headers).unwrap!}")
  HTTP.close_server(server)
end
```

```output
200 11 bytes
```

### Respuestas en flujo y Server-Sent Events {#streamed-responses-and-server-sent-events}

```signature
HTTP.whole(data: Bytes) -> Channel[Bytes]

HTTP.StreamResponse(status: Int, headers: List[HTTP.Header], body: Channel[Bytes], length: Optional[Int] = none)
```

Para un cuerpo que no está listo cuando el handler devuelve: eventos, tokens tal como los genera un modelo, un archivo grande. La aplicación responde con `Answer.Stream` un `StreamResponse` cuyo `body` es un [canal](/library/concurrency/task/), y una tarea que ella inició envía los fragmentos y cierra el canal al final.

- El servidor envía el bloque de cabeceras de inmediato, luego cada fragmento según llega, como un solo trozo vaciado al momento (`Transfer-Encoding: chunked`), y termina el cuerpo cuando se cierra el canal. Los fragmentos que esperan juntos en el canal salen como un solo trozo (de menos de 64 KiB más un fragmento), así que un cliente no debe tomar un trozo por un fragmento. La aplicación no define ni `Content-Length` ni `Transfer-Encoding`. Los fragmentos son `Bytes`, que se envían tal cual sin comprobar UTF-8, así que un flujo puede llevar un archivo o cualquier dato binario (un fragmento de más de 512 KiB se divide en varios trozos). Un fragmento vacío se omite.
- Un cuerpo cuyo tamaño se conoce de antemano (un archivo grande leído por fragmentos) fija `length: some(n)`. El bloque de cabeceras lleva entonces `Content-Length: n` y los fragmentos salen en bruto, sin enmarcado de trozos. Un cuerpo que termina antes de `n`, o un fragmento que pasaría de `n`, cierra la conexión, así que el cliente ve un cuerpo incompleto y nunca lee más allá de la longitud. El cuerpo termina en cuanto se envían `n` bytes, sin esperar a que se cierre el canal, así que la conexión atiende la siguiente solicitud de inmediato: el servidor cierra entonces el canal, y un productor que sigue recibe `error("channel: closed")` y se detiene. Un fragmento tras llenarse el cuerpo no se lee; un fragmento que cruza `n` es el corte de arriba. Un cuerpo cerrado cuyo tamaño no es `n` es el 500 de una respuesta no válida, como también lo es un `length` en una respuesta 204 o 304. `HEAD` recibe el bloque de cabeceras con la longitud y sin cuerpo.
- Una ruta que responde con un texto o un archivo usa `body: HTTP.whole(data)`, un canal cerrado que guarda esos `Bytes` (`"text".bytes` para un texto). El servidor envía entonces `Content-Length`, como en una respuesta completa. Hace lo mismo con cualquier cuerpo que ya esté cerrado cuando la aplicación devuelve.
- El servidor lee la conexión durante todo el flujo. Cuando la entrada del cliente termina (se marchó, o solo cerró a medias su lado de envío) o falla un envío, el servidor cierra el canal, así que el próximo `send` del productor devuelve `error("channel: closed")` y se detiene. Un productor que envía raramente también puede mirar `body.closed?`. El cuerpo se corta entonces sin su último trozo, así que el cliente ve un cuerpo incompleto, no uno terminado. Solo el cierre del canal por el productor termina el cuerpo limpiamente.
- El productor debe cerrar el canal en todos los caminos. Un productor que nunca lo cierra retiene el flujo hasta que el cliente se va: no tiene duración máxima.
- Un productor que falla cierra con su error, `body.close(e)` ([un cierre con razón](/library/concurrency/channel/#channelclose)): los fragmentos que envió aún salen, y después el cuerpo se corta sin su último trozo, así que el cliente ve un cuerpo incompleto.
- Los bytes que el cliente envía durante el flujo (una solicitud en pipelining) se descartan, y la conexión se cierra cuando termina el flujo; el servidor sigue vigilando, así que un cliente que se va después también se detecta.
- Un canal acotado (`Channel.new(8)`) es la contrapresión: un cliente que lee despacio hace esperar al servidor, y así espera el `send` del productor.
- Un productor lento no es un error. La espera del siguiente fragmento no tiene límite de tiempo, e `idle_timeout_ms` cuenta solo entre solicitudes, desde el final de un flujo. `request_timeout_ms` acota el envío de cada fragmento (y de un cuerpo entero enviado con `Content-Length`): un cliente que deja de leer durante ese tiempo es cortado, y el canal se cierra.
- `HEAD` recibe el bloque de cabeceras, y el canal se cierra de inmediato. Un estado 204 o 304 con un cuerpo que sigue abierto, o cualquier otra respuesta que no se pueda enviar, da el mismo 500 que una respuesta completa, y el canal se cierra.
- Un cuerpo que aún llega cuando la aplicación responde cierra la conexión tras el flujo, como ocurre con cualquier respuesta. Una ruta de flujo que toma un cuerpo lo lee primero, y responde a un cuerpo que no puede leer con [`HTTP.body_refusal`](#request-bodies), como hace `HTTP.app`:

```agentica {mode="check"}
import HTTP from "std/http"

def echoed(data: Bytes) -> HTTP.Answer
  HTTP.Answer.Stream(HTTP.StreamResponse(status: 200, headers: [], body: HTTP.whole(data)))
end

def handle(request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  case HTTP.read_all(body, 65536)
    ok(data) -> ok(echoed(data))
    error(e) -> ok(HTTP.body_refusal(e.message))
  end
end

def main() -> Void
  server = HTTP.serve("127.0.0.1", 8080, &handle).unwrap!
  HTTP.wait(server).unwrap!
end
```

- El servidor habla solo HTTP/1.1: una solicitud HTTP/1.0 recibe un 505 antes de que se ejecute la aplicación.

Server-Sent Events son un flujo con `Content-Type: text/event-stream` cuyos fragmentos son líneas `data: ...` terminadas por una línea en blanco:

```agentica
import HTTP from "std/http"

def produce(events: Channel[Bytes]) -> Void
  for n in 1..3
    break if not Result.ok?(events.send("data: tick #{n}\n\n".bytes, 5000))

    Task.sleep(100)
  end

  events.close
end

def handle(request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  if request.method == "GET" and request.path == "/events"
    events: Channel[Bytes] = Channel.new(8)
    Task.spawn(&produce, events)
    headers = [
      HTTP.Header(name: "Content-Type", value: "text/event-stream"),
      HTTP.Header(name: "Cache-Control", value: "no-cache"),
    ]

    return ok(HTTP.Answer.Stream(HTTP.StreamResponse(status: 200, headers: headers, body: events)))
  end

  ok(HTTP.Answer.Whole(HTTP.Response(status: 404, headers: [], body: "not found\n".bytes)))
end

def main() -> Void
  server = HTTP.serve("127.0.0.1", 0, &handle).unwrap!
  client = HTTP.client().unwrap!
  base = "http://127.0.0.1:#{HTTP.local_port(server)}"
  response = HTTP.get(client, base + "/events").unwrap!
  puts(HTTP.header_values(response.headers, "transfer-encoding"))
  puts(HTTP.text(response.body, response.headers).unwrap!)
  puts(HTTP.get(client, base + "/missing").unwrap!.status)
  HTTP.close_client(client)
  HTTP.close_server(server)
end
```

```output
["chunked"]
data: tick 1

data: tick 2

data: tick 3


404
```

`HTTP.get` espera el cuerpo entero, así que el cliente de arriba ve los eventos juntos; el `EventSource` de un navegador o `curl -N` ve cada uno según se envía.

### WebSockets {#websockets}

```signature
HTTP.accept_websocket(request: HTTP.Request, session: HTTP.WebSocketSession, options: HTTP.WebSocketOptions = HTTP.WebSocketOptions()) -> Result[HTTP.Upgrade]
HTTP.prepare(message: HTTP.Message) -> HTTP.Message
```

`serve` actualiza una solicitud a WebSocket (RFC 6455) cuando la aplicación responde con `Answer.Upgrade` y lo que devuelve `accept_websocket`. `HTTP.Upgrade` es un enum: `Upgrade.Accept(...)` actualiza la solicitud, y `Upgrade.Reply(response)` la responde como una respuesta completa (y la conexión atiende la siguiente solicitud); crea un `Accept` con `accept_websocket`, nunca a mano.

- `accept_websocket(request, session, options)` comprueba el handshake: un `GET` con `Upgrade: websocket`, `Connection: Upgrade`, `Sec-WebSocket-Version: 13` y un `Sec-WebSocket-Key` de 16 bytes en base64. Una solicitud que no lo sea recibe un `Upgrade.Reply`: `426` con `Sec-WebSocket-Version: 13` para otra versión, `400` para el resto. El lector del bloque de cabeceras solo deja pasar un `GET` con un solo `Upgrade: websocket`, así que cualquier otro `Upgrade` (`h2c`, un `POST`) es un `501`. Una ruta que no llama a `accept_websocket` ignora las cabeceras y responde como de costumbre.
- Un handshake de WebSocket llega a cualquier aplicación; una ruta que no actualiza lo responde como cualquier otra solicitud.
- `session` es un `HTTP.WebSocketSession`, `Fn[HTTP.WebSocket, Result[Void]]`. El servidor escribe la respuesta `101` y la ejecuta en la tarea de la conexión. Cuando devuelve, el servidor envía un frame de cierre (código 1000, o 1011 y una advertencia para un `error`) salvo que la sesión ya haya enviado uno, espera el frame de cierre del peer y cierra la conexión.
- Una actualización necesita antes el cuerpo entero. Un `Accept` mientras el cuerpo aún no se ha leído recibe un `500` y un cierre, con `http: invalid response: ...` en stderr.
- `HTTP.WebSocket` tiene `incoming` y `outgoing`, ambos `Channel[HTTP.Message]`, `incoming` de 8 mensajes y `outgoing` de `outgoing_queue` (valor predeterminado: 8), y `protocol`, el subprotocolo que se acordó (`""` si no hay ninguno). Una sesión que no lee hace que el servidor deje de leer el socket, y una que envía más deprisa de lo que lee el peer espera en `send`. Una sesión debe seguir tomando mensajes de `incoming` (o terminar): mientras no lo haga, el servidor no lee el socket, así que los pings y el cierre del peer quedan sin respuesta. `incoming` se cierra tras el mensaje `Close`, y `outgoing` se cierra cuando la conexión termina, así que un envío entonces es un `error`.
- `HTTP.Message` es `Text(String)`, `Binary(Bytes)`, `Ping(Bytes)`, `Pong(Bytes)`, `Close(Int, String)`, el código y el motivo, y `Prepared(Bytes)`, que solo envía una sesión. Un `Text` o `Binary` recibido es un mensaje completo: los fragmentos se unen, y un mensaje de texto se comprueba como UTF-8. El servidor responde cada ping recibido con un pong y no lo pasa a la sesión (el pong sale detrás de lo que la sesión ya puso en cola en `outgoing`, hasta `outgoing_queue` mensajes, y una sesión que cerró su propio `outgoing` puede no recibir pongs); un `Pong` sí se pasa. Un `Ping` o `Pong` lleva como máximo 125 bytes (lo que sobra se corta).
- Un `Close` es el último mensaje que recibe la sesión, sea cual sea la causa: el frame de cierre del peer con su código y motivo, un frame que rompió las reglas (el código de la respuesta: 1002, 1007 o 1009), o la pérdida de la conexión (código 1006, porque no llegó ningún frame de cierre). Cuando el peer deja de leer, la sesión se entera de su cierre solo cuando termina la escritura en curso (la lectura del peer, o `request_timeout_ms` de `HTTP.ServerOptions`). Enviar `Close(code, reason)` inicia el handshake de cierre; un código que no se puede enviar (menor de 1000, de 1004 a 1006, de 1015 a 2999, mayor de 4999) se envía como 1011, y un motivo se corta a 123 bytes.
- El servidor comprueba cada frame del peer: debe venir enmascarado, sin bit reservado, con un opcode conocido, un frame de control completo y de como máximo 125 bytes, fragmentos en orden, texto en UTF-8 y un código de cierre que un peer puede enviar. Un frame roto recibe un frame de cierre (1002 error de protocolo, 1007 datos no válidos, 1009 demasiado grande) y la conexión termina. El servidor nunca enmascara sus frames y no acepta extensiones, así que nada se comprime.
- `HTTP.WebSocketOptions` tiene `max_message_bytes` (valor predeterminado 1 MiB, de 1 a 256 MiB: un mensaje que lo supera, en un frame o unido de fragmentos, se cierra con 1009, y un frame que lo anuncia se rechaza antes de leer su payload), `idle_ms` (valor predeterminado 0, sin límite salvo un año, porque una lectura que se agota cierra el socket: el tiempo máximo que el servidor espera a que el peer envíe algo, tras lo cual la conexión se descarta y la sesión recibe `Close` con 1006), `ping_ms` (valor predeterminado 0, ninguno: el servidor envía un ping tras esos milisegundos sin nada que escribir, así que con `ping_ms` menor que `idle_ms` los pongs mantienen vivo a un peer), `close_ms` (valor predeterminado 5000: cuánto espera el servidor la respuesta del peer a su frame de cierre), `protocols` (los subprotocolos que habla, por orden de preferencia: se acuerda el primero que el cliente ofreció en `Sec-WebSocket-Protocol`) y `outgoing_queue` (valor predeterminado 8, de 1 a 1048576: cuántos mensajes guarda `outgoing` antes de que un `send` espere, o falle tras su tiempo de espera). El servidor escribe de una vez, en orden, los mensajes que hay en cola en `outgoing` en ese momento, y deja de leer la cola para ese envío al llegar a 64 KiB (un mensaje más grande va entero), así que un `outgoing_queue` mayor permite que un difusor que envía directamente a los canales `outgoing` de muchos sockets entregue con menos escrituras, a cambio de la memoria de los mensajes en cola.
- `HTTP.prepare(message)` enmarca una vez un mensaje `Text` o `Binary` y lo devuelve como `Prepared`; cualquier otro mensaje vuelve tal cual. Un difusor envía el único mensaje `Prepared` por el canal `outgoing` de cada suscriptor, y cada servidor escribe sus bytes tal cual, así que el mensaje no se enmarca para cada socket. El peer recibe el mismo frame que para el propio mensaje. El escritor comprueba solo la cabecera del frame, así que el payload se da por válido como lo hizo `prepare` (un payload de texto no se vuelve a comprobar como UTF-8). Un mensaje `Prepared` cuyos bytes no son un frame que hizo `prepare` cierra la conexión con 1011, con una advertencia en stderr. Un `case` sobre un `HTTP.Message` recibido nunca ve `Prepared`, pero aun así necesita una rama para él o `_`.
- `request_timeout_ms` de `HTTP.ServerOptions` acota el handshake y cada escritura de un frame. Un WebSocket ocupa un lugar en `max_connections` mientras esté abierto. `idle_timeout_ms` no se aplica tras la actualización.
- El servidor no comprueba `Origin`. Un navegador lo envía con cada handshake, y una aplicación que sirve sus propias páginas debe compararlo con `HTTP.header_values(request.headers, "origin")` antes de aceptar, ya que una página de otro sitio puede abrir un WebSocket hacia ella con las cookies del visitante.
- Límite conocido: la máscara de un frame se quita en un bucle sobre los bytes, a unos 7 MB/s, así que un mensaje de unos pocos MiB cuesta una fracción de segundo de la tarea de su conexión. Mantén `max_message_bytes` en lo que necesita la aplicación.

Un servidor de eco que mezcla una ruta normal y una ruta WebSocket:

```agentica {mode="check"}
import HTTP from "std/http"

def relay(ws: HTTP.WebSocket, message: HTTP.Message) -> Result[Bool]
  case message
    HTTP.Message.Text(text) ->
      try ws.outgoing.send(HTTP.Message.Text("echo: #{text}"), 5000)
      ok(true)
    HTTP.Message.Binary(data) ->
      try ws.outgoing.send(HTTP.Message.Binary(data), 5000)
      ok(true)
    HTTP.Message.Close(_, _) -> ok(false)
    _ -> ok(true)
  end
end

def echo(ws: HTTP.WebSocket) -> Result[Void]
  while true
    case ws.incoming.recv(60000)
      ok(message) -> return ok() if not try relay(ws, message)

      error(_) -> return ok()
    end
  end

  ok()
end

def home(request: HTTP.Request) -> Result[HTTP.Response]
  ok(HTTP.Response(status: 200, headers: [], body: "home".bytes))
end

def route(request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  return ok(HTTP.Answer.Upgrade(try HTTP.accept_websocket(request, &echo))) if request.path == "/echo"

  HTTP.app(&home).call(request, body)
end

def main() -> Void
  server = HTTP.serve("127.0.0.1", 8080, &route).unwrap!
  _ = HTTP.wait(server)
end
```

### HTTP.wait, HTTP.close_server y HTTP.shutdown {#httpwait-httpclose_server-and-httpshutdown}

```signature
HTTP.wait(server: HTTP.Server) -> Result[Void]
HTTP.close_server(server: HTTP.Server) -> Void
HTTP.shutdown(server: HTTP.Server, timeout_ms: Int = 30000) -> Void
```

- `close_server` deja de aceptar, cierra cada conexión y cancela las aplicaciones en ejecución y sus tareas. Volver a llamarlo no hace nada.
- `shutdown` es la parada ordenada. Deja de aceptar de inmediato, así que una conexión nueva se rechaza, y cierra las conexiones que esperan una solicitud. Las solicitudes en curso siguen, y sus respuestas dicen `Connection: close`. Un handshake de WebSocket recibe un `503`. Un flujo o una conexión actualizada que ya está en marcha sigue hasta el plazo, y también el cierre tras una respuesta mientras el cliente mantiene abierto su lado. Cuando todos han terminado, o tras `timeout_ms` (30 s si no se indica), cierra lo que queda como lo hace `close_server`, cancelando las aplicaciones que siguen en ejecución, y devuelve. Llamarlo en un servidor cerrado no hace nada; una llamada hecha mientras otra lo está drenando espera a esa. No lo llames desde una aplicación: esperaría la propia solicitud de esa aplicación hasta el plazo. Una aplicación que debe parar el servidor envía un valor por un canal que recibe la tarea que llamó a `serve`, y esa tarea llama a `shutdown`. Un servidor que debe terminar limpiamente al parar un contenedor se suscribe a `Term` e `Int` ([`System.subscribe`](/library/io-and-system/system/#systemsubscribe)) y lo llama, como abajo.
- `wait` devuelve `ok()` cuando el servidor está cerrado y sus aplicaciones y sus tareas han terminado. Un programa que solo sirve espera en él. Cuando `main` devuelve, el servidor se detiene.
- Un servidor pertenece a la tarea que llamó a `HTTP.serve` y se cierra (liberando su puerto) cuando esa tarea termina, así que llama a `serve` en la tarea que lo conserva, como `main`. Cada conexión pertenece a la tarea que la atiende.

```agentica {mode="check"}
import HTTP from "std/http"

def handle(request: HTTP.Request) -> Result[HTTP.Response]
  ok(HTTP.Response(status: 200, headers: [], body: "you asked for #{request.path}".bytes))
end

def main() -> Void
  options = HTTP.ServerOptions(request_timeout_ms: 10000, max_connections: 64, max_body_bytes: 65536)
  server = HTTP.serve("0.0.0.0", 8080, HTTP.app(&handle), options).unwrap!
  puts("listening on #{HTTP.local_port(server)}")
  IO.flush()
  HTTP.wait(server).unwrap!
end
```

```agentica {mode="check"}
import HTTP from "std/http"

def handle(request: HTTP.Request) -> Result[HTTP.Response]
  ok(HTTP.Response(status: 200, headers: [], body: "hello".bytes))
end

def main() -> Void
  server = HTTP.serve("0.0.0.0", 8080, HTTP.app(&handle)).unwrap!
  signals = System.subscribe([System.Signal.Term, System.Signal.Int]).unwrap!
  while not Result.ok?(signals.recv(60000))
  end

  HTTP.shutdown(server, 10000)
end
```
