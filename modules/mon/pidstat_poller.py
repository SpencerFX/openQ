#!/usr/bin/env python3
"""
modules/mon/pidstat_poller.py

Feed handler for mon's `pidstats` table (schemas/schema_mon.q). Polls Linux's
`pidstat` for per-process CPU and memory stats and streams a merged row per
(host,pid) into mon_tp over qpython - the same "open a handle, call `upd`
over qpython" pattern any non-q feed handler in this repo uses. Works around
one genuine `qpython`/`numpy` incompatibility (numpy 2.0 removed the ndarray
method qpython 2.0.0's array-list write path calls, so every column here
except sym/host/procType - which need to be real q symbols, and whose
per-symbol qpython write path doesn't call the removed method - is sent as
a plain Python list instead of a numpy array).

Based on a production pidstat-to-kdb+ shipper (two separate tables, pidcpu/
pidmem, pushed via a tailed log file + Prometheus gauges) - trimmed down to
the mechanically relevant piece: run `pidstat`, parse its output, ship rows
to a tickerplant. This version merges CPU+memory into the one `pidstats`
table mon already has room for alongside `logs`, and calls `pidstat`
directly per poll instead of tailing a continuously-running pidstat's log
file, since mon doesn't need sub-second sampling.

The `pidstat -u -v -l -h -H 1 1 | awk ...` / `-r ...` pipelines below are
reused as-is from that shipper's collection script - they're what turns
pidstat's raw human-readable-timestamp, multi-header-line output into one
tab-separated line per process with a parseable timestamp, which is what
the parsing functions here (parse_cpu_line/parse_mem_line) expect. Real
sample lines from that shipper's own test suite were used to verify the
parsing here (see the field-by-field mapping in each parse function) -
`pidstat` itself isn't available on the Windows machine this was written
on, so the *shipping* side (qpython publish -> a real mon_tp/mon_rdb) was
verified with parsed-looking synthetic rows, and the *parsing* side against
those known-real sample lines, rather than both together end-to-end.

Only `-procType`/`-port` are recoverable from a monitored process's command
line (`-name` too, folded into `sym`) - only for a direct `init.q
-procType ... -name ... -port ...` invocation. An `initFromCfg.q -config
<path>` invocation doesn't put those on the command line at all (they come
from the JSON), so those fields are left null for it - `command` (the raw
command line) always has the full invocation either way.

Usage:
  python3 pidstat_poller.py --host localhost --port 5020 --interval 5
Env var equivalents (CLI flags win if both given): PIDSTAT_HOST,
PIDSTAT_PORT, PIDSTAT_INTERVAL, PIDSTAT_BIN.
"""
import argparse
import datetime
import logging
import os
import socket
import subprocess
import sys
import time

import numpy

# --- numpy 2.0 compatibility shim for qpython 2.0.0 - see module docstring ---
if not hasattr(numpy, "bool"):
    numpy.bool = numpy.bool_
if not hasattr(numpy, "string_"):
    numpy.string_ = numpy.bytes_

from qpython import qconnection
from qpython.qcollection import qlist
from qpython.qtype import QSYMBOL_LIST

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
log = logging.getLogger("pidstat_poller")

DATETIME_FORMAT = "%Y-%m-%d %H:%M:%S"

# Reused verbatim from the reference shipper's collection script - see the
# module docstring. command_col is 1-indexed into awk's $1.. fields; -h
# reports one line per process, so NR>3 skips the kernel/blank/header lines
# pidstat always prints once at the top, not per process.
CPU_PIPELINE = (
    "pidstat -u -v -l -h -H 1 1 | "
    "awk -v command_col=12 'NR>3 {printf(\"%s\\t\",strftime(\"%Y-%m-%d %H:%M:%S\", $1)); "
    "for(i=2;i<command_col;i++){printf(\"%s\\t\",$i)}; "
    "for(i=command_col;i<NF;i++){printf(\"%s \", $i)} print $NF}'"
)
MEM_PIPELINE = (
    "pidstat -r -v -l -h -H 1 1 | "
    "awk -v command_col=11 'NR>3 {printf(\"%s\\t\",strftime(\"%Y-%m-%d %H:%M:%S\", $1)); "
    "for(i=2;i<command_col;i++){printf(\"%s\\t\",$i)}; "
    "for(i=command_col;i<NF;i++){printf(\"%s \", $i)} print $NF}'"
)

# schema_mon.q's `pidstats` column order after `timestamp` (which mon_tp
# auto-stamps, same as any other openQ schema table).
COLUMNS = (
    "sym", "pidstatTime", "host", "pid", "uid", "procType", "port",
    "userPct", "sysPct", "guestPct", "waitPct", "cpuPct", "cpuId",
    "minflt", "majflt", "vsz", "rss", "memPct", "threads", "fdnr", "command",
)


def parse_cpu_line(line):
    """One line of CPU_PIPELINE's output:
    time\tUID\tPID\t%usr\t%system\t%guest\t%wait\t%CPU\tCPU\tthreads\tfd-nr\tCommand
    Field order/types verified against a reference shipper's own test
    fixture: "2023-07-18 03:24:37\\t999\\t2299\\t1.87\\t0.03\\t0.02\\t3.74\\t
    1.87\\t1\\t1\\t-1\\tq init.q -procType tp -name eq_tp0 ..."
    """
    parts = line.split("\t")
    if len(parts) < 12:
        return None
    return {
        "pidstatTime": parts[0],
        "uid": int(parts[1]),
        "pid": int(parts[2]),
        "userPct": float(parts[3]),
        "sysPct": float(parts[4]),
        "guestPct": float(parts[5]),
        "waitPct": float(parts[6]),
        "cpuPct": float(parts[7]),
        "cpuId": int(parts[8]),
        "threads": int(parts[9]),
        "fdnr": int(parts[10]),
        "command": parts[11],
    }


def parse_mem_line(line):
    """One line of MEM_PIPELINE's output:
    time\tUID\tPID\tminflt/s\tmajflt/s\tVSZ\tRSS\t%MEM\tthreads\tfd-nr\tCommand
    Field order/types verified against a reference shipper's own test
    fixture: "2023-07-18 03:24:30\\t999\\t10642\\t328.97\\t0.26\\t154884\\t
    80352\\t0.06\\t1\\t-1\\tq init.q -procType gw -name eq_gw0 ..."
    """
    parts = line.split("\t")
    if len(parts) < 11:
        return None
    return {
        "pidstatTime": parts[0],
        "uid": int(parts[1]),
        "pid": int(parts[2]),
        "minflt": float(parts[3]),
        "majflt": float(parts[4]),
        "vsz": int(parts[5]),
        "rss": int(parts[6]),
        "memPct": float(parts[7]),
        "threads": int(parts[8]),
        "fdnr": int(parts[9]),
        "command": parts[10],
    }


def parse_openq_identity(command):
    """Recovers -procType/-name/-port from a direct `init.q` invocation's
    command line. Returns ("", "", None) for anything else (including an
    `initFromCfg.q -config <path>` invocation - see module docstring)."""
    proc_type, name, port = "", "", None
    parts = command.split(" ")
    i = 0
    while i < len(parts) - 1:
        if parts[i] == "-procType":
            i += 1
            proc_type = parts[i]
        elif parts[i] == "-name":
            i += 1
            name = parts[i]
        elif parts[i] == "-port":
            i += 1
            try:
                port = int(parts[i])
            except ValueError:
                pass
        i += 1
    return proc_type, name, port


def run_pipeline(pipeline, parse_fn):
    try:
        result = subprocess.run(pipeline, shell=True, capture_output=True, text=True, timeout=10)
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        log.warning("pidstat pipeline failed: %s", e)
        return {}
    if result.returncode != 0:
        log.warning("pidstat pipeline exited %d: %s", result.returncode, result.stderr.strip())
        return {}

    by_pid = {}
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        record = parse_fn(line)
        if record is not None:
            by_pid[record["pid"]] = record
    return by_pid


def poll_once(min_command_length=0):
    """Runs both pidstat pipelines and merges them per PID into rows ready
    for build_columns. A PID present in only one of the two (a process that
    started/exited between the two pidstat calls) still gets a row, with
    the other side's numeric fields left at 0."""
    cpu_by_pid = run_pipeline(CPU_PIPELINE, parse_cpu_line)
    mem_by_pid = run_pipeline(MEM_PIPELINE, parse_mem_line)

    rows = []
    for pid in set(cpu_by_pid) | set(mem_by_pid):
        cpu = cpu_by_pid.get(pid, {})
        mem = mem_by_pid.get(pid, {})
        command = cpu.get("command") or mem.get("command") or ""
        if len(command) < min_command_length:
            continue
        proc_type, name, port = parse_openq_identity(command)
        rows.append({
            "sym": name,
            "pidstatTime": cpu.get("pidstatTime") or mem.get("pidstatTime"),
            "pid": pid,
            "uid": cpu.get("uid", mem.get("uid", 0)),
            "procType": proc_type,
            "port": port,
            "userPct": cpu.get("userPct", 0.0),
            "sysPct": cpu.get("sysPct", 0.0),
            "guestPct": cpu.get("guestPct", 0.0),
            "waitPct": cpu.get("waitPct", 0.0),
            "cpuPct": cpu.get("cpuPct", 0.0),
            "cpuId": cpu.get("cpuId", -1),
            "minflt": mem.get("minflt", 0.0),
            "majflt": mem.get("majflt", 0.0),
            "vsz": mem.get("vsz", 0),
            "rss": mem.get("rss", 0),
            "memPct": mem.get("memPct", 0.0),
            "threads": cpu.get("threads", mem.get("threads", 0)),
            "fdnr": cpu.get("fdnr", mem.get("fdnr", -1)),
            "command": command,
        })
    return rows


def build_columns(rows, host):
    syms = qlist(numpy.array([r["sym"] for r in rows], dtype=numpy.string_), qtype=QSYMBOL_LIST)
    hosts = qlist(numpy.array([host] * len(rows), dtype=numpy.string_), qtype=QSYMBOL_LIST)
    proc_types = qlist(numpy.array([r["procType"] for r in rows], dtype=numpy.string_), qtype=QSYMBOL_LIST)
    pidstat_times = [
        numpy.datetime64(datetime.datetime.strptime(r["pidstatTime"], DATETIME_FORMAT), "ns")
        for r in rows
    ]
    return [
        syms,
        pidstat_times,
        hosts,
        [r["pid"] for r in rows],
        [r["uid"] for r in rows],
        proc_types,
        [r["port"] if r["port"] is not None else 0 for r in rows],
        [r["userPct"] for r in rows],
        [r["sysPct"] for r in rows],
        [r["guestPct"] for r in rows],
        [r["waitPct"] for r in rows],
        [r["cpuPct"] for r in rows],
        [r["cpuId"] for r in rows],
        [r["minflt"] for r in rows],
        [r["majflt"] for r in rows],
        [r["vsz"] for r in rows],
        [r["rss"] for r in rows],
        [r["memPct"] for r in rows],
        [r["threads"] for r in rows],
        [r["fdnr"] for r in rows],
        [r["command"] for r in rows],
    ]


def connect(host, port, retries=3, retry_delay=5):
    for attempt in range(1, retries + 1):
        log.info("Connecting to KDB+ at %s:%d (attempt %d/%d)", host, port, attempt, retries)
        try:
            q = qconnection.QConnection(host=host, port=port, timeout=5)
            q.open()
            if q.is_connected():
                log.info("Successfully connected to KDB+: %s", q.protocol_version)
                return q
        except Exception as e:
            log.warning("Connection attempt %d failed: %s", attempt, e)
        if attempt < retries:
            time.sleep(retry_delay)
    raise ConnectionError(f"Could not connect to KDB+ at {host}:{port} after {retries} attempts")


def stream(q, host, interval, min_command_length):
    log.info("Starting pidstat polling at %ds intervals", interval)
    iteration = 0
    while True:
        iteration += 1
        rows = poll_once(min_command_length)
        if rows:
            data = build_columns(rows, host)
            q.sendAsync("upd", numpy.string_("pidstats"), data)
            log.info("Streamed %d process record(s) to KDB+ table 'pidstats'", len(rows))
        else:
            log.warning("No pidstat records this iteration - nothing streamed")
        log.info("Completed iteration %d", iteration)
        time.sleep(interval)


def main():
    parser = argparse.ArgumentParser(description="Stream pidstat CPU/memory snapshots into an openQ mon tickerplant")
    parser.add_argument("--host", default=os.environ.get("PIDSTAT_HOST", "localhost"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("PIDSTAT_PORT", "5020")))
    parser.add_argument("--interval", type=int, default=int(os.environ.get("PIDSTAT_INTERVAL", "5")))
    parser.add_argument("--min-command-length", type=int, default=0)
    args = parser.parse_args()

    this_host = socket.gethostname()
    q = connect(args.host, args.port)
    try:
        stream(q, this_host, args.interval, args.min_command_length)
    except KeyboardInterrupt:
        log.info("Received keyboard interrupt. Shutting down...")
    finally:
        q.close()
        log.info("Closed KDB+ connection")


if __name__ == "__main__":
    sys.exit(main())
