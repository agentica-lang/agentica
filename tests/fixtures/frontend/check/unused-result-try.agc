def save() -> Result[Void]
  return ok()
end

def run() -> Result[Void]
  save()
  return ok()
end

def main() -> Void
  puts(run().ok?)
end
