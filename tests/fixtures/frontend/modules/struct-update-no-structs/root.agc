def main() -> Void
  _x = Process.Output(stdout: "a", stderr: "b", truncated: false).with(stdout: "c").with(stderr: "d")
end

