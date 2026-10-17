"""Reads the files that the COPY ... TO section of test/sql/zig_ext_cookbook.test wrote, with PyArrow.

The SQL tests read them back with the recipe's own reader; this is the independent reader, so a misreading shared
by the writer and the reader cannot hide. Run after `task sqllogictest:cookbook`. Needs pyarrow; skips without it.
"""
import datetime as dt
import sys

try:
    import pyarrow as pa
    import pyarrow.ipc as ipc
except ImportError:
    print("verify_arrow_output: pyarrow is not installed, skipped")
    sys.exit(0)


def read(name):
    with open(f"/tmp/zig_ext_cookbook_arrow_{name}.arrows", "rb") as f:
        return ipc.open_stream(f).read_all()


def check(cond, what):
    if not cond:
        print(f"FAILED: {what}")
        sys.exit(1)
    print(f"ok: {what}")


t = read("types")
check(t.schema.types == [pa.bool_(), pa.int8(), pa.int16(), pa.int32(), pa.int64(), pa.uint8(), pa.uint16(), pa.uint32(),
                         pa.uint64(), pa.float32(), pa.float64(), pa.date32(), pa.timestamp("us"), pa.string()], "types: schema")
rows = t.to_pylist()
check(len(rows) == 5, "types: 5 rows")
check(all(v is None for v in rows[2].values()), "types: the NULL row is NULL in every column")
check(rows[3]["u64"] == 2**64 - 1 and rows[0]["i64"] == -2**63, "types: the 64-bit extremes")
check(rows[1]["ts"] == dt.datetime(1969, 12, 31, 23, 59, 59, 999999) and rows[3]["d"] == dt.date(2024, 2, 29), "types: date and timestamp")
check(rows[1]["s"] == "héllo wörld" and rows[3]["s"] == "a string that is longer than twelve bytes" and rows[0]["s"] == "", "types: strings")
check(rows[0]["f64"] == 0.1 and rows[3]["f32"] == pa.array([1e30], pa.float32()).to_pylist()[0], "types: floats")

r = read("range")
check(r.num_rows == 100000 and r.column(0).to_pylist() == list(range(100000)), "range: 100000 rows in order")
# BATCH_SIZE 3000 becomes batches of a whole number of vectors (4096 rows).
check(len(r.to_batches()) >= 20, "range: many record batches")

s = read("strings")
expect = [None if i % 11 == 0 else "é" * (i % 40) for i in range(30000)]
check(s.column(0).to_pylist() == expect, "strings: 30000 values across batches")

for codec in ("none", "lz4", "zstd"):
    c = read(codec)
    check(c.num_rows == 60000 and c.column("s").to_pylist() == [f"row-{i % 100}" for i in range(60000)]
          and c.column("x").to_pylist() == [(i % 17) * 0.25 for i in range(60000)], f"codec {codec}: 60000 rows")

n = read("nothing")
check(n.num_rows == 0 and n.schema.names == ["id", "s"], "nothing: the schema and no rows")
