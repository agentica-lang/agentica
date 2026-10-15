enum State
  Ready
  Done
end

def main() -> Void
  case State.Ready() do
    State.Missing ->
      puts("missing")
    _ ->
      puts("other")
  end
end

