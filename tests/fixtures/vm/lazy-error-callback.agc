# A runtime error in a callback stops the pipeline and the run, at the callback.
def main() -> Void
  xs = [10, 20]
  indexes = Lazy.produce(0) do |i| i + 1 end
  puts(indexes.map do |i| xs[i] end.to_a)
end
