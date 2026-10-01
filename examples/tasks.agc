struct Task
  title: String
  done: Bool
end

def main() -> Nil
  tasks: List[Task] = [
    Task(title: "Probar Agentica", done: false),
    Task(title: "Revisar gramática", done: true)
  ]

  for task in tasks
    if not task.done
      puts(task.title)
    end
  end
end
