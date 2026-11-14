import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "TLS.alpn",
    parameters: [Model.Named(name: "socket", type: Types.Type.Opaque("TCP.Socket"))],
    result: Types.Type.String,
    rule: Model.Rule.Plain,
    implementation: "TLS.alpn",
    effects: ["network"],
    description: "Return the protocol that ALPN selected in the TLS handshake, or \"\" for none.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "TLS.client_context",
    parameters: [Model.Named(name: "options", type: Types.Type.Struct("TLS.ClientOptions", []))],
    result: Types.Type.Result(Types.Type.Opaque("TLS.Context")),
    rule: Model.Rule.Plain,
    implementation: "TLS.client_context",
    effects: ["network"],
    description: (
      "Build a client TLS.Context once, for many connections: the PEM CA file (empty: system trust) and an " +
      "optional client certificate and key are read and checked now; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "TLS.connect",
    parameters: [
      Model.Named(name: "host", type: Types.Type.String),
      Model.Named(name: "port", type: Types.Type.Int),
      Model.Named(name: "context", type: Types.Type.Opaque("TLS.Context")),
      Model.Named(name: "timeout_ms", type: Types.Type.Int),
    ],
    result: Types.Type.Result(Types.Type.Opaque("TCP.Socket")),
    rule: Model.Rule.Plain,
    implementation: "TLS.connect",
    effects: ["network"],
    description: "Connect with a client TLS.Context; the certificate and the hostname are always verified.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "TLS.listen",
    parameters: [
      Model.Named(name: "host", type: Types.Type.String),
      Model.Named(name: "port", type: Types.Type.Int),
      Model.Named(name: "context", type: Types.Type.Opaque("TLS.Context")),
    ],
    result: Types.Type.Result(Types.Type.Opaque("TCP.Listener")),
    rule: Model.Rule.Plain,
    implementation: "TLS.listen",
    effects: ["network"],
    description: "Listen with a server TLS.Context, its certificate chain and key.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "TLS.server_context",
    parameters: [Model.Named(name: "options", type: Types.Type.Struct("TLS.ServerOptions", []))],
    result: Types.Type.Result(Types.Type.Opaque("TLS.Context")),
    rule: Model.Rule.Plain,
    implementation: "TLS.server_context",
    effects: ["network"],
    description: (
      "Build a server TLS.Context once, for many listeners: the PEM certificate chain and the key are read and " +
      "checked now; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "TLS.upgrade",
    parameters: [
      Model.Named(name: "socket", type: Types.Type.Opaque("TCP.Socket")),
      Model.Named(name: "context", type: Types.Type.Opaque("TLS.Context")),
      Model.Named(name: "host", type: Types.Type.String),
      Model.Named(name: "timeout_ms", type: Types.Type.Int),
    ],
    result: Types.Type.Result(Types.Type.Opaque("TCP.Socket")),
    rule: Model.Rule.Plain,
    implementation: "TLS.upgrade",
    effects: ["network"],
    description: (
      "Start TLS on an open TCP socket (STARTTLS), on the side the context's role names; a server context takes " +
      "the host \"\". The plain socket is closed once the arguments pass their checks."
    ),
    alternatives: [],
  ),
]
