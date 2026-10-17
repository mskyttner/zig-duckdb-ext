"""Writes the Arrow IPC files that test/sql/zig_ext_cookbook.test reads with COPY ... FROM (zig_cookbook_arrow_ipc).

PyArrow is the independent writer here; the recipe's own writer is checked the other way round (DuckDB's oracle for the
values, PyArrow reading the recipe's output: see docs/cookbook.md). Run: python3 tools/gen_arrow_fixtures.py
"""
import datetime as dt
import os

import pyarrow as pa
import pyarrow.ipc as ipc

OUT = os.path.join(os.path.dirname(__file__), "..", "test", "data", "arrow")
os.makedirs(OUT, exist_ok=True)


def write(name, table, file_format=False, compression=None, max_chunksize=None):
    opts = ipc.IpcWriteOptions(compression=compression)
    writer = (ipc.new_file if file_format else ipc.new_stream)(os.path.join(OUT, name), table.schema, options=opts)
    for batch in table.to_batches(max_chunksize=max_chunksize):
        writer.write_batch(batch)
    writer.close()


types = pa.table({
    "b": pa.array([True, False, None, True, False], pa.bool_()),
    "i8": pa.array([-128, 0, None, 127, 5], pa.int8()),
    "i16": pa.array([-32768, 0, None, 32767, 5], pa.int16()),
    "i32": pa.array([-2**31, 0, None, 2**31 - 1, 5], pa.int32()),
    "i64": pa.array([-2**63, 0, None, 2**63 - 1, 5], pa.int64()),
    "u8": pa.array([0, 1, None, 255, 5], pa.uint8()),
    "u16": pa.array([0, 1, None, 65535, 5], pa.uint16()),
    "u32": pa.array([0, 1, None, 2**32 - 1, 5], pa.uint32()),
    "u64": pa.array([0, 1, None, 2**64 - 1, 5], pa.uint64()),
    "f32": pa.array([0.5, -1.25, None, 1e30, 3.0], pa.float32()),
    "f64": pa.array([0.1, -2.5, None, 1e300, 3.0], pa.float64()),
    "d": pa.array([dt.date(1970, 1, 1), dt.date(1969, 12, 31), None, dt.date(2024, 2, 29), dt.date(9999, 12, 31)], pa.date32()),
    "ts": pa.array([dt.datetime(1970, 1, 1), dt.datetime(1969, 12, 31, 23, 59, 59, 999999), None,
                    dt.datetime(2024, 2, 29, 12, 30, 45, 123456), dt.datetime(2000, 1, 1)], pa.timestamp("us")),
    "s": pa.array(["", "héllo wörld", None, "a string that is longer than twelve bytes", "tab\there"], pa.string()),
})
write("types.arrows", types)
write("types.arrow", types, file_format=True)

# Many rows, so that a record batch is bigger than a DuckDB vector (2048) and several batches follow each other.
n = 5000
big = pa.table({
    "id": pa.array(range(n), pa.int64()),
    "s": pa.array([None if i % 7 == 0 else f"row-{i}" for i in range(n)], pa.string()),
    "x": pa.array([None if i % 5 == 0 else i * 0.5 for i in range(n)], pa.float64()),
})
write("big_one_batch.arrows", big)
write("big_batches.arrows", big, max_chunksize=1000)
write("big_lz4.arrows", big, compression="lz4_frame", max_chunksize=1500)
# No Zstd fixture: the library's decoder (gld-arrow-zig 0.2.0) fails ("Compression") on most frames PyArrow writes,
# for example any 200 to 1500 integers; it reads LZ4 and its own Zstd frames. See docs/cookbook.md.

# Files the recipe must reject, each with its own reason.
write("no_rows.arrows", pa.table({"id": pa.array([], pa.int64()), "s": pa.array([], pa.string())}))
write("dictionary.arrows", pa.table({"s": pa.array(["a", "b", "a"]).dictionary_encode()}))
write("timezone.arrows", pa.table({"ts": pa.array([dt.datetime(2020, 1, 1)], pa.timestamp("us", tz="UTC"))}))
write("millis.arrows", pa.table({"ts": pa.array([dt.datetime(2020, 1, 1)], pa.timestamp("ms"))}))
write("large_string.arrows", pa.table({"s": pa.array(["a"], pa.large_string())}))
write("list.arrows", pa.table({"l": pa.array([[1, 2]], pa.list_(pa.int64()))}))
write("date64.arrows", pa.table({"d": pa.array([dt.date(2020, 1, 1)], pa.date64())}))
write("int32.arrows", pa.table({"id": pa.array([1, 2], pa.int32())}))
write("uint64.arrows", pa.table({"id": pa.array([1, 2], pa.uint64())}))
# A string column whose bytes are not UTF-8: Arrow does not check, DuckDB's VARCHAR must not hold it.
bad = pa.Array.from_buffers(pa.string(), 2, [None, pa.py_buffer(b"\x00\x00\x00\x00\x01\x00\x00\x00\x03\x00\x00\x00"), pa.py_buffer(b"a\xff\xfe")])
write("bad_utf8.arrows", pa.table({"s": bad}))
with open(os.path.join(OUT, "garbage.arrows"), "wb") as f:
    f.write(b"this is not an arrow file at all, just text\n" * 4)
