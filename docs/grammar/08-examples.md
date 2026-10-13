## 8. Examples to review the design

### Function and control flow

```ruby
def classify(age: Int) -> String
  if age >= 18
    return "adult"
  elsif age >= 13
    return "teen"
  else
    return "child"
  end
end

def main() -> Void
  puts(classify(25))
end
```

### Programs that must be rejected

```ruby
age: Int = "25"        # Incompatible types.
if 1                   # The condition must be Bool.
  puts("hello")
end
values = []            # Missing expected type for the empty list.
puts "hello"           # The call requires parentheses.
```

These statements are shown as function body fragments. At the top level they would also be invalid because they are not declarations.

## 9. Guide for whoever implements the prototype

Implement the rules of sections 4–6 first. Keep the grammar, the AST, the checker, the VM, and the builtin functions independent. Do not generate host code without preserving the rules of Agentica: for example, `if 1` must be rejected even if the host accepts truthiness.

If a rule turns out to be too costly, change this specification and the examples explicitly before creating a silent exception. The goal is that any agent can consult a short document and predict the behavior of a program.

The first evaluation of the language should measure correct programs, attempts needed, and how useful the errors are. Run time can be measured later; the first question is whether the syntax and the rules help agents produce and repair code.
