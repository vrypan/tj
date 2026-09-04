#ifndef TJ_SQLITE_SHIM_H
#define TJ_SQLITE_SHIM_H

#include "sqlite3.h"

int tj_sqlite_bind_text(sqlite3_stmt *statement, int index,
                        const char *value, int length);

#endif
