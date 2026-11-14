import W from "std/http"
import T from "std/toml"

def download() -> W.Download = W.Download(status: 200, headers: [], bytes_written: 1)

def number() -> T.Value = T.Value.Int(2)
