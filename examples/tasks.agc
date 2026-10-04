struct Todo
  title: String
  done: Bool
end

def main() -> Void
  tasks: List[Todo] = [
    Todo(title: "Probar Agentica", done: false),
    Todo(title: "Revisar gramática", done: true)
  ]

  for task in tasks
    if not task.done
      puts(task.title)
    end
  end
end
