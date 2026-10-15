import Source from "source"

export struct DocBlock
  text: String
  next: String
end

export enum Value
  NoValue
  Text(String)
  Whole(Int)
  Huge(String)
  Real(Float)
  Doc(DocBlock)
end

export struct Token
  kind: String
  lexeme: String
  value: Value
  span: Source.Span
end
