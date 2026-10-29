# Cookie (`std/cookie`)

`import Cookie from "std/cookie"`. Reads a `Cookie` header and writes a
`Set-Cookie` header, with the behaviour of Rack. Written in Agentica; nothing
halts.

```text
Cookie.parse(header: String) -> Map[String, String]
Cookie.set_header(cookie: Cookie.Cookie) -> Result[String]
Cookie.Cookie(name: String, value: String, path: String = "", domain: String = "",
              max_age: Int = Cookie.NO_MAX_AGE, expires: String = "",
              secure: Bool = false, http_only: Bool = false, same_site: String = "")
```

- `parse` splits on `;`, trims, and keeps the first value of a
  name. It does not decode or unquote.
- `set_header` writes `name=value; Domain; Path; Max-Age; Expires;
  Secure; HttpOnly; SameSite`. `Cookie.NO_MAX_AGE` (the smallest `Int`, the
  default) and an empty string leave the attribute out; any other `max_age` of
  0 or less writes `Max-Age=0` and deletes the cookie. `expires` is text you
  format (no date type).
- It never encodes, decodes or quotes (final, unlike Ruby and Rack): encode
  the value yourself and decode it after reading. An `error` names the field
  for a name that is not an RFC 7230 token, a value with a space, `"`, `,`,
  `;`, `\`, a control or a non-ASCII byte (the error gives the byte position,
  never the value), a `path`, `domain` or `expires` with a control or `;`, a
  `domain` with a space, a `path` or `expires` with a leading or trailing
  space, a `same_site` other than `Strict`, `Lax` or `None`, `None` without
  `secure`, `__Secure-` without `secure`, and `__Host-` without `secure`,
  path `/` and no domain.
