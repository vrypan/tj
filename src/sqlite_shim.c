#include "sqlite_shim.h"

int tj_sqlite_bind_text(sqlite3_stmt *statement, int index,
                        const char *value, int length) {
    return sqlite3_bind_text(statement, index, value, length, SQLITE_TRANSIENT);
}
