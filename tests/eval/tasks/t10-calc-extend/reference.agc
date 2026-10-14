enum Token
  Num(Int)
  Ident(String)
  Plus
  Minus
  Star
  Slash
  Percent
  Caret
  LParen
  RParen
  Equals
end

struct Parsed
  value: Int
  pos: Int
end

struct Outcome
  env: Map[String, Int]
  text: String
end

def is_digit(c: String) -> Bool
  code = String.code(c)
  return code >= 48 && code <= 57
end

def is_letter(c: String) -> Bool
  code = String.code(c)
  return (code >= 97 && code <= 122) || code == 95
end

def tokenize(text: String) -> Result[List[Token]]
  tokens: List[Token] = []
  i = 0
  n = text.length
  while i < n
    c = text.at(i)
    if c == " "
      i += 1
    elsif c == "+"
      tokens = tokens.push(Token.Plus)
      i += 1
    elsif c == "-"
      tokens = tokens.push(Token.Minus)
      i += 1
    elsif c == "*"
      tokens = tokens.push(Token.Star)
      i += 1
    elsif c == "/"
      tokens = tokens.push(Token.Slash)
      i += 1
    elsif c == "%"
      tokens = tokens.push(Token.Percent)
      i += 1
    elsif c == "^"
      tokens = tokens.push(Token.Caret)
      i += 1
    elsif c == "("
      tokens = tokens.push(Token.LParen)
      i += 1
    elsif c == ")"
      tokens = tokens.push(Token.RParen)
      i += 1
    elsif c == "="
      tokens = tokens.push(Token.Equals)
      i += 1
    elsif is_digit(c)
      j = i
      while j < n && is_digit(text.at(j))
        j += 1
      end
      tokens = tokens.push(Token.Num(text.slice(i, j - i).to_i!))
      i = j
    elsif is_letter(c)
      j = i
      while j < n && is_letter(text.at(j))
        j += 1
      end
      tokens = tokens.push(Token.Ident(text.slice(i, j - i)))
      i = j
    else
      return error("bad character '#{c}'")
    end
  end
  return ok(tokens)
end

def parse_atom(env: Map[String, Int], tokens: List[Token], pos: Int) -> Result[Parsed]
  if pos >= tokens.size
    return error("unexpected end of input")
  end
  case tokens[pos]
    Token.Num(n) ->
      return ok(Parsed(value: n, pos: pos + 1))
    Token.Ident(name) ->
      if !env.has_key?(name)
        return error("unknown variable #{name}")
      end
      return ok(Parsed(value: env[name], pos: pos + 1))
    Token.LParen ->
      inner = try parse_expr(env, tokens, pos + 1)
      if inner.pos >= tokens.size
        return error("expected )")
      end
      case tokens[inner.pos]
        Token.RParen -> return ok(Parsed(value: inner.value, pos: inner.pos + 1))
        _ -> return error("expected )")
      end
    _ ->
      return error("unexpected token")
  end
end

def power(base: Int, exponent: Int) -> Int
  result = 1
  count = 0
  while count < exponent
    result = result * base
    count += 1
  end
  return result
end

def parse_unary(env: Map[String, Int], tokens: List[Token], pos: Int) -> Result[Parsed]
  if pos >= tokens.size
    return error("unexpected end of input")
  end
  case tokens[pos]
    Token.Minus ->
      inner = try parse_unary(env, tokens, pos + 1)
      return ok(Parsed(value: 0 - inner.value, pos: inner.pos))
    _ ->
      return parse_power(env, tokens, pos)
  end
end

def parse_power(env: Map[String, Int], tokens: List[Token], pos: Int) -> Result[Parsed]
  base = try parse_atom(env, tokens, pos)
  if base.pos >= tokens.size
    return ok(base)
  end
  case tokens[base.pos]
    Token.Caret ->
      exponent = try parse_unary(env, tokens, base.pos + 1)
      if exponent.value < 0
        return error("negative exponent")
      end
      return ok(Parsed(value: power(base.value, exponent.value), pos: exponent.pos))
    _ ->
      return ok(base)
  end
end

def parse_term(env: Map[String, Int], tokens: List[Token], pos: Int) -> Result[Parsed]
  left = try parse_unary(env, tokens, pos)
  value = left.value
  p = left.pos
  while p < tokens.size
    case tokens[p]
      Token.Star ->
        right = try parse_unary(env, tokens, p + 1)
        value = value * right.value
        p = right.pos
      Token.Slash ->
        right = try parse_unary(env, tokens, p + 1)
        if right.value == 0
          return error("division by zero")
        end
        value = value / right.value
        p = right.pos
      Token.Percent ->
        right = try parse_unary(env, tokens, p + 1)
        if right.value == 0
          return error("division by zero")
        end
        value = value % right.value
        p = right.pos
      _ ->
        return ok(Parsed(value: value, pos: p))
    end
  end
  return ok(Parsed(value: value, pos: p))
end

def parse_expr(env: Map[String, Int], tokens: List[Token], pos: Int) -> Result[Parsed]
  left = try parse_term(env, tokens, pos)
  value = left.value
  p = left.pos
  while p < tokens.size
    case tokens[p]
      Token.Plus ->
        right = try parse_term(env, tokens, p + 1)
        value = value + right.value
        p = right.pos
      Token.Minus ->
        right = try parse_term(env, tokens, p + 1)
        value = value - right.value
        p = right.pos
      _ ->
        return ok(Parsed(value: value, pos: p))
    end
  end
  return ok(Parsed(value: value, pos: p))
end

def finish(env: Map[String, Int], tokens: List[Token], start: Int) -> Result[Parsed]
  parsed = try parse_expr(env, tokens, start)
  if parsed.pos < tokens.size
    return error("unexpected token")
  end
  return ok(parsed)
end

def is_assignment(tokens: List[Token]) -> Bool
  if tokens.size < 2
    return false
  end
  case tokens[0]
    Token.Ident(_) ->
      case tokens[1]
        Token.Equals -> return true
        _ -> return false
      end
    _ ->
      return false
  end
end

def evaluate(env: Map[String, Int], line: String) -> Result[Outcome]
  tokens = try tokenize(line)
  if is_assignment(tokens)
    parsed = try finish(env, tokens, 2)
    name = ""
    case tokens[0]
      Token.Ident(id) -> name = id
      _ -> name = ""
    end
    return ok(Outcome(env: env.put(name, parsed.value), text: "#{name} = #{parsed.value}"))
  end
  parsed = try finish(env, tokens, 0)
  return ok(Outcome(env: env, text: "#{parsed.value}"))
end

def main() -> Void
  env: Map[String, Int] = {}
  while !IO.eof?()
    line = IO.gets!().strip
    if line == ""
      next
    end
    result = evaluate(env, line)
    if result.ok?
      outcome = result.unwrap!
      puts(outcome.text)
      env = outcome.env
    else
      puts("error: #{result.message}")
    end
  end
end
