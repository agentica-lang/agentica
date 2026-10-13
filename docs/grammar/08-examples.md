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
