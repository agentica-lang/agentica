"""The expected output of an ATS operation list, from a Python dict (tests/test_vm_ats.py).

Reads the operations as JSON on stdin, one [name, key, value] each, and prints what the Agentica program of the same
list prints. A dict keeps first-insertion order, and a key deleted and put again goes to the end, as ATS does. With
--bytes the keys are Bytes, written in the operations as hex; a Bytes key prints as `<Bytes n hex>` in a map.
"""
import json
import sys

BYTES = sys.argv[1:] == ["--bytes"]


def key_text(key):
    if not BYTES:
        return '"%s"' % key
    data = bytes.fromhex(key)
    return "<Bytes %d %s>" % (len(data), data.hex()) if data else "<Bytes 0>"


def text(table):
    return "{" + ", ".join("%s: %d" % (key_text(key), value) for key, value in table.items()) + "}"


def main():
    table = {}
    for name, key, value in json.load(sys.stdin):
        if name == "put":
            table[key] = value
        elif name == "put_new":
            fresh = key not in table
            if fresh:
                table[key] = value
            print("put_new %s %s" % (key, "true" if fresh else "false"))
        elif name == "delete":
            table.pop(key, None)
        elif name == "add":
            table[key] = table.get(key, 0) + value
            print("add %s %d" % (key, table[key]))
        elif name == "get":
            print("get %s %s" % (key, table[key] if key in table else "missing"))
        elif name == "has_key":
            print("has_key %s %s" % (key, "true" if key in table else "false"))
        elif name == "size":
            print("size %d" % len(table))
        elif name == "keys":
            print("keys " + ",".join(table))
        elif name == "to_map":
            print("to_map " + text(table))
        else:
            raise SystemExit("unknown operation " + name)


main()
