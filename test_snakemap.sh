#!/bin/bash
duckdb -unsigned -list -c "
      LOAD 'zig-out/lib/zig_ext.duckdb_extension';
      SELECT tp_snakemap(
          [34.0, 21.0, 13.0, 8.0, 5.0, 3.0, 2.0, 1.0],
          ['34','21','13','8','5','3','2','1'],
          ['Large','Large','Large','Medium','Medium','Small','Small','Small'],
          width := 62, height := 25, no_color := true
      );"

