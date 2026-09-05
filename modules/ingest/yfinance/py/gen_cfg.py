#!/usr/bin/env python3
"""
modules/ingest/yfinance/py/gen_cfg.py

Generates the flat cfg_proc/modules/yfinance/<name>/*.json files
core/initFromCfg.q reads, from one compact manifest below, instead of
five modules' worth of hand-typed, hand-synced JSON. Source of truth for
those 14 files - see cfg_proc/modules/README.md; don't hand-edit them.

Why a generator and not a runtime "extends" mechanism: core/initFromCfg.q
and the JSON files it reads don't change AT ALL - this only changes how
those files get written. Every port cross-reference a human currently has
to keep in sync by hand (rdb.json's tpaddr matching tp.json's port,
idb.json's rdbaddr/rdbaddr2 matching rdb.json's port1/port2, gw.json's
rdbaddr/hdbaddr, housekeeping.json's idbaddr) is instead DERIVED, once,
from the two numbers MODULES below actually needs to pin: a module's own
tp_port (or, for a daily-only module with no tp/rdb, its hdb_port) and
rdb2_port (the standby rdb / "secondary bank" base).

Offsets below were reverse-engineered from the 19 real files already
checked into cfg_proc/modules/yfinance/*/ and verified byte-identical
against every one of them (see verify() at the bottom):
  rdb1        = tp_port + 1
  hdb         = tp_port + 3      (+2 is reserved - would be a cep, if any
                                   yfinance module ever gets one)
  idb         = rdb2_port + 1
  housekeeping= rdb2_port + 2
  gw          = rdb2_port + 3
tp_port/rdb2_port themselves stay explicit, hand-assigned constants in
MODULES - they're referenced elsewhere (README's port table, qcon's
registry) so a generator run must never silently renumber them.

Usage (run from this file's own directory):
  python gen_cfg.py --out ../../../../cfg_proc/modules      # (over)write for real
  python gen_cfg.py --verify ../../../../cfg_proc/modules   # diff-only, no writes
"""
import argparse
import json
import sys
from pathlib import Path

UTILITIES = [
    "utils/timer.q", "utils/handlers.q", "utils/conn.q",
    "utils/ipc.q", "utils/servers.q", "utils/perm.q",
]
SCHEMA = "../schemas/schema_yfinance.q"

# ---- the one thing a human edits: what each module IS, not how its ----
# ---- JSON files spell each other's ports out --------------------------
MODULES = {
    "eq_m1_yfinance": dict(
        roles=["tp", "rdb", "hdb", "idb", "gw", "housekeeping"],
        tp_port=5060, rdb2_port=5116,
        hdbroot="C:/data/db1/eq",
        hkscript="../modules/ingest/yfinance/q/eod_housekeeping.q",
        eodTriggerTime="08:30:00.000",
    ),
    "futures_m1_yfinance": dict(
        roles=["tp", "rdb", "hdb"],
        tp_port=5084, rdb2_port=5137,
        hdbroot="C:/data/db1/futures",  # own root (migrated 2026-09-05) -
    ),                                  # see schema_yfinance.q's header
    "rateIndices_m1_yfinance": dict(
        roles=["tp", "rdb", "hdb"],
        tp_port=5080, rdb2_port=5136,
        hdbroot="C:/data/db1/rates",  # own root, shared w/ rateIndices_d1 -
    ),                                # see schema_yfinance.q's header
    "fx_m1_yfinance": dict(
        roles=["tp", "rdb", "hdb"],
        tp_port=5140, rdb2_port=5138,
        hdbroot="C:/data/db1/efx",  # shares the read-only vendor FX archive's
    ),                              # root (2026-09-05) - see schema_yfinance.q
    "futures_d1_yfinance": dict(
        roles=["hdb"], hdb_port=5089,
        hdbroot="C:/data/db1/futures",
    ),
    "rateIndices_d1_yfinance": dict(
        roles=["hdb"], hdb_port=5088,
        hdbroot="C:/data/db1/rates",  # own root (renamed from ratesD1,
    ),                                # 2026-09-05 - now shares w/ rateIndices_m1)
    "fx_d1_yfinance": dict(
        roles=["hdb"], hdb_port=5092,
        hdbroot="C:/data/db1/efx",
    ),
}


def addr(port):
    return f":localhost:{port}"


def derive_ports(cfg):
    """Every port this module needs, computed from its pinned tp_port/
    rdb2_port (or, for a daily-only module, its own pinned hdb_port)."""
    roles = cfg["roles"]
    d = {}
    if "tp" in roles:
        d["tp_port"] = cfg["tp_port"]
        d["rdb1_port"] = cfg["tp_port"] + 1
        if "hdb" in roles:
            d["hdb_port"] = cfg["tp_port"] + 3
    else:
        d["hdb_port"] = cfg["hdb_port"]
    if "rdb" in roles:
        d["rdb2_port"] = cfg["rdb2_port"]
        if "idb" in roles:
            d["idb_port"] = cfg["rdb2_port"] + 1
        if "housekeeping" in roles:
            d["hk_port"] = cfg["rdb2_port"] + 2
        if "gw" in roles:
            d["gw_port"] = cfg["rdb2_port"] + 3
    return d


def build_tp(m, cfg, d):
    return {
        "procType": "tp", "name": f"{m}_tp", "port": d["tp_port"],
        "schema": SCHEMA, "utilities": UTILITIES, "libraries": ["tp.q"],
        "params": {"tplogdir": f"../examples/data/{m}/tplogs", "bmode": 1},
    }


def build_rdb(m, cfg, d):
    return {
        "procType": "rdb", "name": f"{m}_rdb",
        "schema": SCHEMA, "utilities": UTILITIES,
        "libraries": ["rdb.q", "utils/gateway.q", "query.q", "save.q"],
        "params": {
            "tpaddr": addr(d["tp_port"]), "hdbroot": cfg["hdbroot"],
            "port1": d["rdb1_port"], "port2": d["rdb2_port"], "instance": 1,
        },
    }


def build_hdb(m, cfg, d):
    return {
        "procType": "hdb", "name": f"{m}_hdb", "port": d["hdb_port"],
        "schema": SCHEMA, "utilities": UTILITIES,
        "libraries": ["hdb.q", "utils/gateway.q", "query.q"],
        "params": {"hdbroot": cfg["hdbroot"]},
    }


def build_idb(m, cfg, d):
    return {
        "procType": "idb", "name": f"{m}_idb", "port": d["idb_port"],
        "schema": SCHEMA, "utilities": UTILITIES,
        "libraries": ["save.q", "idb.q"],
        "params": {
            "rdbaddr": addr(d["rdb1_port"]), "rdbaddr2": addr(d["rdb2_port"]),
            "idbroot": f"../examples/data/{m}/idb_staging",
            "hdbroot": cfg["hdbroot"], "checkpointfreq": "0D00:15:00",
        },
    }


def build_gw(m, cfg, d):
    return {
        "procType": "gw", "name": f"{m}_gw", "port": d["gw_port"],
        "utilities": UTILITIES,
        "libraries": ["utils/gateway.q", "query.q", "gw.q"],
        "params": {"rdbaddr": addr(d["rdb1_port"]), "hdbaddr": addr(d["hdb_port"])},
    }


def build_housekeeping(m, cfg, d):
    return {
        "procType": "housekeeping", "name": f"{m}_housekeeping", "port": d["hk_port"],
        "utilities": UTILITIES, "libraries": ["housekeeping.q"],
        "params": {
            "hkscript": cfg["hkscript"], "hkfreq": "0D00:01:00",
            "idbaddr": addr(d["idb_port"]), "hdbroot": cfg["hdbroot"],
            "eodTriggerTime": cfg["eodTriggerTime"],
        },
    }


BUILDERS = {
    "tp": build_tp, "rdb": build_rdb, "hdb": build_hdb,
    "idb": build_idb, "gw": build_gw, "housekeeping": build_housekeeping,
}


def generate():
    """module -> {role -> (relpath, json-text)} for every role of every
    module in MODULES, formatted exactly the way the real files already
    are (2-space indent, trailing newline)."""
    out = {}
    for m, cfg in MODULES.items():
        d = derive_ports(cfg)
        out[m] = {}
        for role in cfg["roles"]:
            obj = BUILDERS[role](m, cfg, d)
            text = json.dumps(obj, indent=2) + "\n"
            out[m][role] = (f"yfinance/{m}/{role}.json", text)
    return out


def verify(cfgRoot: Path):
    """Diff-only: generate in memory, compare byte-for-byte against the
    real files already on disk under cfgRoot. Never writes anything."""
    ok = True
    for m, roles in generate().items():
        for role, (relpath, text) in roles.items():
            real = cfgRoot / relpath
            if not real.exists():
                print(f"MISSING on disk: {relpath}"); ok = False; continue
            onDisk = real.read_text()
            if onDisk != text:
                print(f"DIFFERS: {relpath}")
                ok = False
            else:
                print(f"match:   {relpath}")
    return ok


def write(cfgRoot: Path):
    for m, roles in generate().items():
        for role, (relpath, text) in roles.items():
            p = cfgRoot / relpath
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
            print(f"wrote {relpath}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--out", help="write generated JSON here (module subdirs created)")
    g.add_argument("--verify", help="diff-only against JSON already at this path")
    args = ap.parse_args()
    if args.verify:
        sys.exit(0 if verify(Path(args.verify)) else 1)
    else:
        write(Path(args.out))
