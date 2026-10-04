struct Product
  name: String
  stock: Int
end

def filter_catalog(text: String) -> Result[String]
  root = try JSON.parse(text)
  minimum = try JSON.int(try JSON.get(root, "minimum"))
  if minimum < 0
    return error("invalid catalog")
  end
  products = try JSON.list(try JSON.get(root, "products"))
  output = ""
  for product in products
    name = try JSON.string(try JSON.get(product, "name"))
    stock = try JSON.int(try JSON.get(product, "stock"))
    if stock < 0
      return error("invalid catalog")
    end
    if stock >= minimum
      output = output + JSON.encode(Product(name: name, stock: stock)) + "\n"
    end
  end
  return ok(output)
end

def main() -> Void
  result = filter_catalog(IO.read())
  if Result.ok?(result)
    IO.print(Result.unwrap!(result))
  else
    puts(JSON.encode({"error": "invalid catalog"}))
  end
end
