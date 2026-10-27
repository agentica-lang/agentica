"""The expected output of an ATS operation list, from a Python dict (tests/test_vm_ats.py).

Reads the operations as JSON on stdin, one [name, key, value] each, and prints what the Agentica program of the same
list prints. A dict keeps first-insertion order, and a key deleted and put again goes to the end, as ATS does.
"""
import json
import sys


def text(table):
    return "{" + ", ".join('"%s": %d' % (key, value) for key, value in table.items()) + "}"


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
