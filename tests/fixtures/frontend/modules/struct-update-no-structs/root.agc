def main() -> Void
  _x = ProcessOutput(stdout: "a", stderr: "b", truncated: false).with(stdout: "c").with(stderr: "d")
end

