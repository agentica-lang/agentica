import Source from "../syntax/source"

export struct Diagnostic
  code: String
  message: String
  span: Source.Span
  help: Help
end

export enum Help
  NoHelp
  Hint(String)
end

export enum Outcome[T]
  Done(T)
  Failed(Diagnostic)
end

export def fail(code: String, message: String, span: Source.Span, help: Help) -> Diagnostic
  return Diagnostic(code: code, message: message, span: span, help: help)
end
