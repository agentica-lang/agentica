## 3. A core program

```ruby
struct User
  name: String
  age: Int
end

def is_adult(user: User) -> Bool
  return user.age >= 18
end

def main() -> Void
  users = [
    User(name: "Ana", age: 25),
    User(name: "Luis", age: 16)
  ]

  for user in users
    if is_adult(user)
      puts(user.name)
    end
  end
end
```

Blocks end with `end`. Indentation helps reading but does not determine structure. Calls use parentheses, even when they take no arguments; only builtin methods, and module functions without arguments (builtin or reached through an import alias), may drop them (`s.length`, `IO.gets!`, `Util.reset`). Structs are built with named fields; ordinary functions take positional arguments.

The executable starts by calling `main()`. The core has no executable statements at the top level, only declarations. This avoids having two different entry models.

