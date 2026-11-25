#!/usr/bin/env python3
"""Unprivileged layout, atomic link replacement and synthetic SQLite version probe."""
import os
from pathlib import Path
import sqlite3
import tempfile


def switch(prefix, version):
    pending = prefix / ".current.next"
    pending.symlink_to(Path("versions") / version)
    os.replace(pending, prefix / "current")


def open_compatible(database, maximum_schema):
    with sqlite3.connect(f"{database.as_uri()}?mode=ro", uri=True) as conn:
        version, = conn.execute("PRAGMA user_version").fetchone()
        if version < 1 or version > maximum_schema:
            raise ValueError(f"unsupported schema {version}")
        assert conn.execute("PRAGMA integrity_check").fetchone() == ("ok",)
        return version


with tempfile.TemporaryDirectory(prefix="wm006a-layout-") as directory:
    base = Path(directory)
    prefix = base / "var-opt" / "wm006a"
    state = base / "var-lib" / "wm006a-signer"
    state.mkdir(parents=True, mode=0o700)
    for version in ("v1", "v2"):
        (prefix / "versions" / version / "bin").mkdir(parents=True)

    database = state / "synthetic.sqlite"
    with sqlite3.connect(database) as conn:
        conn.execute("CREATE TABLE fixture (id INTEGER PRIMARY KEY)")
        conn.execute("PRAGMA user_version = 1")
    switch(prefix, "v1")
    assert (prefix / "current").resolve().name == "v1"
    assert open_compatible(database, 1) == 1

    snapshot = state / "before-upgrade.sqlite"
    with sqlite3.connect(database) as conn, sqlite3.connect(snapshot) as backup:
        conn.backup(backup)
        conn.execute("PRAGMA user_version = 2")
    switch(prefix, "v2")
    assert (prefix / "current").resolve().name == "v2"
    assert open_compatible(database, 2) == 2

    switch(prefix, "v1")
    assert (prefix / "current").resolve().name == "v1"
    try:
        open_compatible(database, 1)
    except ValueError as error:
        print(f"Old reader refused newer active schema: {error}")
    else:
        raise AssertionError("downgrade accepted newer schema")
    assert open_compatible(database, 2) == 2
    assert open_compatible(snapshot, 1) == 1
    switch(prefix, "v2")
    assert (prefix / "current").resolve().name == "v2"
    print("Unprivileged link switch, guarded downgrade, and readable offline snapshot: PASS")
