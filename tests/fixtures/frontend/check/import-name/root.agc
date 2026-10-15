import "models" as Models

def main() -> Void
  secret = Models.make()
  changed = secret.with(value: 2)
  puts(changed.value)
end
