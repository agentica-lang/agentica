# toml-test, TOML 1.0.0 files

These are the files that the `toml-lang/toml-test` suite lists for TOML 1.0.0
(`files-toml-1.0.0`): `valid/` has each input with its expected value as
tagged JSON, and `invalid/` has inputs that a parser must reject.

- Source: https://github.com/toml-lang/toml-test, commit
  `ff49d109861c1ad25af53f687f2aef19ab650600`.
- License: MIT (see `LICENSE`, copied from the repository), which allows
  copying with the license notice.
- `tests/test_std_toml.py` is the only reader. The files are test inputs and
  stay byte for byte as upstream has them (some hold control characters, CRLF
  and invalid UTF-8 on purpose).
