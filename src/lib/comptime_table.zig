///! Comptime table function framework for DuckDB.
///!
///! Automates registration boilerplate for table functions. The user provides
///! bind, init, and exec callbacks containing the custom logic; the framework
///! handles function handle lifecycle and parameter type registration.
///!
///! Usage:
///!   const MyTF = comptime_table.Function(struct {
///!       pub const name: [:0]const u8 = "my_table_fn";
///!       pub const param_types = [_]DuckDBType{ .VARCHAR, .VARCHAR };
///!       pub const bind = myBind;
///!       pub const init = myInit;
///!       pub const exec = myExec;
///!   });
///!   try MyTF.register(connection);
const db = @import("duckdb.zig");

/// Define a DuckDB table function from a comptime configuration struct.
///
/// The Cfg type must declare:
///   - `name: [:0]const u8` — SQL function name
///   - `param_types: [N]db.c.DUCKDB_TYPE` — parameter DuckDB types
///   - `bind: TableFunctionBind` — bind callback
///   - `init: TableFunctionInit` — init callback
///   - `exec: TableFunctionCallback` — exec callback
pub fn Function(comptime Cfg: type) type {
    return struct {
        /// Register this table function with DuckDB.
        pub fn register(connection: db.Connection) !void {
            const function = db.createTableFunction();
            defer db.destroyTableFunction(@constCast(&function));

            db.tableFunctionSetName(function, Cfg.name);

            inline for (Cfg.param_types) |pt| {
                var lt = db.createLogicalType(pt);
                defer db.destroyLogicalType(&lt);
                db.tableFunctionAddParameter(function, lt);
            }

            db.tableFunctionSetBind(function, Cfg.bind);
            db.tableFunctionSetInit(function, Cfg.init);
            db.tableFunctionSetFunction(function, Cfg.exec);

            if (db.registerTableFunction(connection, function) == db.DuckDBError) {
                return error.FailedToRegisterFunction;
            }
        }
    };
}
