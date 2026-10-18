#!/usr/bin/env python3
"""
Eggs data generator for the Phoenix server.

Reads the Phoenix workspace (YAML zone data + module overlays + NM scripts) and
writes addons/eggs/data/<zone_id>.lua in the format the addon loads at runtime.

Replaces the old in-game /eggs import, which parsed SQL dumps and `entity.phList`
Lua. Those no longer exist on Phoenix beta: mob data moved to
data/zones/<zone>/mobs.yaml, and PH/NM lottery info moved into its `slots:`.

Sources
  data/zones/<dir>/mobs.yaml            templates / spawns / slots
  modules/**/zones/<dir>/mobs.yaml      overlays, deep-merged in modules/init.txt
                                        order (dicts recurse, lists replace)
  scripts/zones/<Zone>/mobs/<NM>.lua    timed-spawn windows (setRespawnTime)
  sql/zone_settings.sql                 zone id <-> name
  modules/*/sql/**/mob_droplist_*.sql   blanket item removals / swaps

Usage
  python tools/generate.py [--repo C:\\Phoenix-Workspace] [--out ../data]
                           [--zone 107] [--quiet]
"""
import argparse
import glob
import os
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required:  python -m pip install pyyaml")

try:
    _Loader = yaml.CSafeLoader
except AttributeError:  # pragma: no cover
    _Loader = yaml.SafeLoader

DEFAULT_REPO = os.environ.get("EGGS_REPO", r"C:\Phoenix-Workspace")

# Drop-chance words -> per-mille (mirrors the SET vars in sql/mob_droplist.sql).
CHANCE_WORDS = {
    "always": 1000, "very_common": 240, "common": 150, "uncommon": 100,
    "rare": 50, "very_rare": 10, "super_rare": 5, "ultra_rare": 1,
}

# Lottery cooldowns this short are treated as "no cooldown" (true lottery).
TIMED_LOTTERY_MIN_COOLDOWN = 300

# A script that calls setRespawnTime with only seconds (popped / instanced /
# battlefield mobs: Tenzen, the Primes, Dynamis Lord, ship mobs, ...) is not an
# NM respawn window. Real open-world NM windows start at 4 minutes or more
# (Eyy Mon the Ironbreaker is 4-6 min).
MIN_TIMED_WINDOW = 240

# Scripts to ignore per zone. "Bloodsucker_NM" displays as plain "Bloodsucker",
# the same as the regular mobs, so it is handled by MANUAL_ENTRIES (by mob id).
ZONE_SKIP_SCRIPTS = {
    167: {"Bloodsucker_NM"},
}

# modules/era/lua/globals/old_nm_respawn_timers.lua (active on Phoenix) puts the
# pre-November-2013 NM timers back by overriding the NM scripts at runtime, so the
# script's own setRespawnTime values are NOT what the server uses. Mirrored here
# (zone folder, script name) -> (min, max) seconds. Disable with --no-era-timers.
ERA_TIMED_NMS = {
    ("Sauromugue_Champaign", "Roc"):               (75600, 86400),    # 21-24h
    ("Ordelles_Caves", "Morbolger"):               (75600, 86400),
    ("Gusgen_Mines", "Juggler_Hecatomb"):          (75600, 86400),
    ("FeiYin", "Capricious_Cassie"):               (75600, 86400),
    ("Rolanberry_Fields", "Simurgh"):              (75600, 86400),
    ("Temple_of_Uggalepih", "Manipulator"):        (7200, 7200),      # 2h
    ("Bostaunieux_Oubliette", "Bloodsucker_NM"):   (259200, 259200),  # 72h
    ("Maze_of_Shakhrami", "Argus"):                (64800, 108000),   # 18-30h, shared pair
    ("Maze_of_Shakhrami", "Leech_King"):           (64800, 108000),
    ("Qufim_Island", "Dosetsu_Tree"):              (75600, 86400),    # thunder weather only
}
ERA_WOTG_TIMED_NMS = {   # only present when WotG content is enabled
    ("Qufim_Island", "Atkorkamuy"):                (7200, 7200),
}
# Lottery cooldown overrides from the same module: (zone folder, NM script) -> secs
ERA_LOTTERY_COOLDOWNS = {
    ("Konschtat_Highlands", "Rampaging_Ram"):      3600,
    ("La_Theine_Plateau", "Lumbering_Lambert"):    3600,
}
WOTG_ENABLED = True
USE_ERA_TIMERS = True

# NMs whose mechanics the YAML / scripts cannot express. Only used when the
# automatic pass found nothing for that name.
MANUAL_ENTRIES = {
    3: {  # Manaclipper
        "Zoredonite": dict(NMType="timed_spawn", NMMobId=16789518, Chance=0,
                           WindowMin=43200),
    },
    167: {  # Bostaunieux Oubliette ("Bloodsucker NM" shares its display name)
        "Bloodsucker": dict(NMType="timed_spawn", NMMobId=17461478, Chance=0,
                            WindowMin=3600, EraKey=("Bostaunieux_Oubliette", "Bloodsucker_NM")),
    },
    30: {  # Riverne - Site #A01
        "Carmine Dobsonfly": dict(NMType="timed_spawn", NMMobId=16900230,
                                  Chance=100, WindowMin=75600, WindowMax=86400),
        "Heliodromos": dict(NMType="timed_spawn", NMMobId=16900110,
                            Chance=100, WindowMin=43200, WindowMax=54000),
    },
}


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
def zone_dir_name(name):
    """Phoenix data/zones/<dir> convention."""
    return re.sub(r"[^a-z0-9]+", "_", name.strip().lower()).strip("_")


def display(template_key, tmpl):
    name = (tmpl or {}).get("display_name") or template_key
    return str(name).replace("_", " ")


def lua_str(s):
    return "'" + str(s).replace("\\", "\\\\").replace("'", "\\'") + "'"


def title_item(slug):
    """'vial_of_fiend_blood' -> 'Vial Of Fiend Blood' (matches the old importer)."""
    s = str(slug).replace("_", " ")
    return re.sub(r"([A-Za-z])([A-Za-z0-9]*)",
                  lambda m: m.group(1).upper() + m.group(2).lower(), s)


def deep_merge(base, over):
    for k, v in over.items():
        if k in base and isinstance(base[k], dict) and isinstance(v, dict):
            deep_merge(base[k], v)
        else:
            base[k] = v
    return base


def load_yaml(path):
    with open(path, encoding="utf-8") as f:
        return yaml.load(f, Loader=_Loader) or {}


# --------------------------------------------------------------------------- #
# Workspace loaders
# --------------------------------------------------------------------------- #
def load_zone_settings(repo):
    """{zone_id: name} from sql/zone_settings.sql."""
    path = os.path.join(repo, "sql", "zone_settings.sql")
    out = {}
    rx = re.compile(r"INSERT INTO `zone_settings` VALUES \((\d+),\s*'[^']*',\s*\d+,\s*'([^']+)'")
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("--"):
                continue
            m = rx.search(line)
            if m and m.group(2) != "unknown":
                out[int(m.group(1))] = m.group(2)
    return out


def load_active_modules(repo):
    p = os.path.join(repo, "modules", "init.txt")
    out = []
    if os.path.isfile(p):
        with open(p, encoding="utf-8", errors="replace") as f:
            for ln in f:
                ln = ln.split("#", 1)[0].strip().rstrip("/")
                if ln:
                    out.append(ln)
    return out


def _overlay_files(repo, mod):
    """Yield (zone_dir, mobs.yaml path) for one active data module."""
    if not mod.startswith(("phoenix/data", "era/data")):
        return
    for base in (os.path.join(repo, "modules", mod, "zones"),
                 os.path.join(repo, "modules", mod)):
        if not os.path.isdir(base):
            continue
        for entry in sorted(os.listdir(base)):
            path = os.path.join(base, entry, "mobs.yaml")
            if os.path.isfile(path):
                yield entry, path


def load_overlays(repo, active):
    """{zone_dir: merged overlay doc} for every active module with a mobs.yaml."""
    out = {}
    for mod in active:
        for entry, path in _overlay_files(repo, mod):
            try:
                doc = load_yaml(path)
            except Exception as e:  # pragma: no cover
                print(f"WARN overlay {path}: {e}")
                continue
            deep_merge(out.setdefault(entry, {}), doc)
    return out


def load_item_enum(repo):
    """{item_id: lowercase_slug} from scripts/enum/item.lua."""
    path = os.path.join(repo, "scripts", "enum", "item.lua")
    out = {}
    if not os.path.isfile(path):
        return out
    rx = re.compile(r"^\s*([A-Z0-9_]+)\s*=\s*(\d+)\s*,")
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = rx.match(line)
            if m:
                out.setdefault(int(m.group(2)), m.group(1).lower())
    return out


_SQL_SET = re.compile(r"SET\s+@(\w+)\s*=\s*(\d+)", re.I)
_SQL_DEL = re.compile(r"DELETE\s+FROM\s+`?mob_droplist`?\s+WHERE\s+([^;]+);", re.I | re.S)
_SQL_UPD = re.compile(
    r"UPDATE\s+`?mob_droplist`?\s+SET\s+itemId\s*=\s*(\d+)\s+WHERE\s+([^;]+);", re.I | re.S)


def _droplist_sql_texts(repo, active):
    """Yield the text of each active droplist removal/adjust SQL file."""
    for mod in active:
        if not (mod.startswith("era/sql/") or mod.startswith("phoenix/sql")):
            continue
        for fn in ("mob_droplist_removal.sql", "mob_droplist_adjust.sql"):
            path = os.path.join(repo, "modules", mod, fn)
            if os.path.isfile(path):
                with open(path, encoding="utf-8", errors="replace") as f:
                    yield f.read()


def _sql_number(tok, vars_):
    tok = tok.strip().lstrip("@")
    return int(tok) if re.fullmatch(r"-?\d+", tok) else vars_.get(tok.upper())


def _blanket_removals(txt, vars_, item_enum):
    """Slugs deleted from every droplist (no dropId / itemRate qualifier)."""
    for m in _SQL_DEL.finditer(txt):
        cond = m.group(1)
        iid = re.search(r"itemId\s*=\s*(@?[-\w]+)", cond, re.I)
        scoped = re.search(r"dropId\s*=|itemRate\s*=", cond, re.I)
        if not iid or scoped:
            continue
        slug = item_enum.get(_sql_number(iid.group(1), vars_))
        if slug:
            yield slug


def _item_swaps(txt, vars_, item_enum):
    """(old_slug, new_slug) pairs from `UPDATE mob_droplist SET itemId`."""
    for m in _SQL_UPD.finditer(txt):
        old = re.search(r"itemId\s*=\s*(@?[-\w]+)", m.group(2), re.I)
        if not old:
            continue
        old_slug = item_enum.get(_sql_number(old.group(1), vars_))
        new_slug = item_enum.get(int(m.group(1)))
        if old_slug and new_slug:
            yield old_slug, new_slug


def load_droplist_mods(repo, active, item_enum):
    """Blanket removals ({slug}) and swaps ({old_slug: new_slug}) from active
    era/phoenix SQL modules. dropId-scoped deletes cannot be mapped onto YAML
    mobs and are ignored (same limitation as the Libra generator)."""
    remove, replace = set(), {}
    for txt in _droplist_sql_texts(repo, active):
        vars_ = {m.group(1).upper(): int(m.group(2)) for m in _SQL_SET.finditer(txt)}
        remove.update(_blanket_removals(txt, vars_, item_enum))
        replace.update(_item_swaps(txt, vars_, item_enum))
    return remove, replace


# --------------------------------------------------------------------------- #
# Timed-spawn window parsing (ported from the old Lua importer)
# --------------------------------------------------------------------------- #
_RAND = r"math\.random(?:Int)?"


def parse_timed_spawn(content):
    """Return (win_min, win_max, interval, count) or None."""
    # King Arthro style: respawnTime = base + math.random(0,n) * mult via getID()-offset
    m = re.search(r"respawnTime\s*=\s*(\d+)\s*\+\s*" + _RAND + r"\s*\(\s*\d+\s*,\s*(\d+)\s*\)\s*\*\s*(\d+)",
                  content)
    if m and re.search(r"getID\s*\(\s*\)\s*-\s*offset", content):
        bases = sorted(int(b) for b in re.findall(r"respawnTime\s*=\s*(\d+)\s*\+", content))
        real = bases[-1] if bases else int(m.group(1))
        mm = re.search(str(real) + r"\s*\+\s*" + _RAND + r"\s*\(\s*\d+\s*,\s*(\d+)\s*\)\s*\*\s*(\d+)", content)
        if mm:
            n, mult = int(mm.group(1)), int(mm.group(2))
            return real, real + n * mult, mult, n + 1
        return real, real, 0, 1
    # setRespawnTime(math.random(a, b) * m)
    m = re.search(r"setRespawnTime\s*\(\s*" + _RAND + r"\s*\(\s*(\d+)\s*,\s*(\d+)\s*\)\s*\*\s*(\d+)", content)
    if m:
        a, b, mult = int(m.group(1)), int(m.group(2)), int(m.group(3))
        return a * mult, b * mult, mult, b - a + 1
    # setRespawnTime(base + math.random(a, b))  e.g. Centurio XII-I: 75600 + 600..900.
    # Files often set a short "after a restart" timer in onMobInitialize and the real
    # post-death timer in onMobDespawn, so prefer the occurrence with the largest base.
    best = None
    for m in re.finditer(r"setRespawnTime\s*\(\s*(\d+)\s*\+\s*" + _RAND
                         + r"\s*\(\s*(\d+)\s*,\s*(\d+)\s*\)\s*\)", content):
        base, a, b = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if best is None or base > best[0]:
            best = (base, a, b)
    if best:
        return best[0] + best[1], best[0] + best[2], 0, 0
    # setRespawnTime(math.random(a, b))
    m = re.search(r"setRespawnTime\s*\(\s*" + _RAND + r"\s*\(\s*(\d+)\s*,\s*(\d+)\s*\)\s*\)", content)
    if m:
        return int(m.group(1)), int(m.group(2)), 0, 0
    # GetSystemTime() + math.random(a, b)
    m = re.search(r"GetSystemTime\s*\(\s*\)\s*\+\s*" + _RAND + r"\s*\(\s*(\d+)\s*,\s*(\d+)\s*\)", content)
    if m:
        return int(m.group(1)), int(m.group(2)), 0, 0
    # setRespawnTime(a * m)
    m = re.search(r"setRespawnTime\s*\(\s*(\d+)\s*\*\s*(\d+)\s*\)", content)
    if m:
        v = int(m.group(1)) * int(m.group(2))
        return v, v, 0, 1
    # setRespawnTime(n)
    m = re.search(r"setRespawnTime\s*\(\s*(\d+)\s*\)", content)
    if m:
        v = int(m.group(1))
        return v, v, 0, 1
    return None


# --------------------------------------------------------------------------- #
# Loot
# --------------------------------------------------------------------------- #
def chance_value(c):
    if isinstance(c, (int, float)):
        return int(c)
    return CHANCE_WORDS.get(str(c), 0)


def loot_row(item, rate, typ, gid, group_rate):
    return dict(Name=title_item(item), Rate=rate, Type=typ, GroupId=gid, GroupRate=group_rate)


def _as_list(value):
    """steal is a slug or a list; despoil is a {slug: 0} dict."""
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return list(value.keys())
    return list(value or [])


def _drop_rows(d, fix, gid):
    """Loot rows for one `drops:` entry. Returns (rows, next_group_id)."""
    rate = chance_value(d.get("chance"))
    if "item" in d:
        item = fix(d["item"])
        return ([loot_row(item, rate, 0, 0, 1000)] if item is not None else []), gid

    opts = d.get("one_of")
    if opts is None:
        return [], gid
    if isinstance(opts, dict):
        pairs = [(k, int(v) * 10) for k, v in opts.items()]
    else:
        per = 1000 // max(len(opts), 1)
        pairs = [(k, per) for k in opts]
    pairs = [(fix(k), r) for k, r in pairs]
    pairs = [(k, r) for k, r in pairs if k is not None]
    if not pairs:
        return [], gid
    gid += 1
    return [loot_row(k, r, 1, gid, rate) for k, r in pairs], gid


def build_loot(tmpl, remove, replace):
    """Old Eggs loot rows: {Name, Rate, Type, GroupId, GroupRate}.
    Type 0 normal, 1 group, 2 steal, 4 despoil."""
    loot = (tmpl or {}).get("loot") or {}

    def fix(slug):
        slug = replace.get(str(slug).lower(), slug)
        return None if str(slug).lower() in remove else slug

    rows, gid = [], 0
    for d in loot.get("drops") or []:
        new_rows, gid = _drop_rows(d, fix, gid)
        rows.extend(new_rows)
    for typ, key in ((2, "steal"), (4, "despoil")):
        for slug in _as_list(loot.get(key)):
            item = fix(slug)
            if item is not None:
                rows.append(loot_row(item, 0, typ, 0, 1000))
    return rows


def loot_lua(rows):
    if not rows:
        return "nil"
    parts = [
        "{Name=%s,Rate=%d,Type=%d,GroupId=%d,GroupRate=%d}"
        % (lua_str(r["Name"]), r["Rate"], r["Type"], r["GroupId"], r["GroupRate"])
        for r in rows
    ]
    return "{" + ",".join(parts) + "}"


# --------------------------------------------------------------------------- #
# Per-zone build
# --------------------------------------------------------------------------- #
class Zone:
    def __init__(self, zid, zname, zdir, doc):
        self.zid, self.zname, self.zdir = zid, zname, zdir
        self.templates = doc.get("templates") or {}
        self.spawns = doc.get("spawns") or {}
        self.slots = doc.get("slots") or []

    # spawn id -> template key
    def tkey(self, mid):
        sp = self.spawns.get(mid) or {}
        return sp.get("template")

    def tmpl(self, key):
        return self.templates.get(key) or {}

    def name_of(self, mid):
        k = self.tkey(mid)
        if k is None:
            return "Mob #%d" % mid
        return display(k, self.tmpl(k))

    def respawn_of(self, key):
        spawn = ((self.tmpl(key).get("attributes") or {}).get("spawn")) or {}
        r = spawn.get("respawn")
        return int(r) if isinstance(r, (int, float)) and r > 0 else 0

    def script_base(self, mid):
        """Lua file basename for a spawn (script: override, else template key)."""
        sp = self.spawns.get(mid) or {}
        return sp.get("script") or sp.get("template")


# --------------------------------------------------------------------------- #
# Legacy Lua lottery (entity.phList + xi.mob.phOnDespawn)
#
# The YAML `slots:` only cover simple lottery NMs. Chained / multi-PH NMs
# (La Theine, RuAun Despot, King Arthro, ...) still live in Lua.
# --------------------------------------------------------------------------- #
def match_braces(text, start):
    """Text of the {...} block whose opening brace is at/after `start`."""
    i = text.find("{", start)
    if i < 0:
        return ""
    depth = 0
    for j in range(i, len(text)):
        c = text[j]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
    return ""


def resolve_zone_ids(z, ids_path):
    """{CONST: [ids...]} from IDs.lua's `mob = {...}`.
    GetFirstID/GetTableOfIDs are resolved against the YAML spawns by template
    key / script / display name; numeric literals are taken as-is."""
    if not os.path.isfile(ids_path):
        return {}
    with open(ids_path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    m = re.search(r"\bmob\s*=\s*\{", text)
    if not m:
        return {}
    block = match_braces(text, m.start())

    by_name = {}
    for mid, sp in z.spawns.items():
        sp = sp or {}
        tk = sp.get("template")
        for n in {tk, sp.get("script"), z.tmpl(tk).get("display_name")}:
            if n:
                by_name.setdefault(str(n), set()).add(int(mid))
    lower = {}
    for k, v in by_name.items():
        lower.setdefault(k.lower(), set()).update(v)

    out = {}
    for mm in re.finditer(r"([A-Z0-9_]+)\s*=\s*(GetFirstID|GetTableOfIDs)\(\s*'([^']+)'\s*\)", block):
        key, fn, name = mm.group(1), mm.group(2), mm.group(3)
        ids = sorted(by_name.get(name) or lower.get(name.lower()) or [])
        if ids:
            out[key] = ids[:1] if fn == "GetFirstID" else ids
    for mm in re.finditer(r"([A-Z0-9_]+)\s*=\s*(\d+)\s*,", block):
        out.setdefault(mm.group(1), [int(mm.group(2))])
    return out


_PH_EXPR = re.compile(r"ID\.mob\.([A-Z0-9_]+)(?:\[(\d+)\])?\s*(?:([+-])\s*(\d+))?")


def eval_ph_expr(expr, ids):
    """'ID.mob.KEY[2] - 3' -> mob id, or None if it cannot be resolved."""
    m = _PH_EXPR.search(expr)
    if not m:
        return None
    key, idx, op, n = m.groups()
    lst = ids.get(key)
    if not lst:
        return None
    if idx:
        if int(idx) > len(lst):
            return None
        base = lst[int(idx) - 1]
    else:
        base = lst[0]
    off = int(n) if n else 0
    return base + (-off if op == "-" else off)


_PH_DESPAWN = re.compile(
    r"xi\.mob\.phOnDespawn\s*\(\s*mob\s*,\s*ID\.mob\.([A-Z0-9_]+)(?:\[\d+\])?\s*,\s*(\d+)\s*,\s*"
    r"(?:(\d+)|" + _RAND + r"\s*\(\s*\d+\s*,\s*(\d+)\s*\))")


def read_script(lua_dir, base):
    """Text of scripts/zones/<Zone>/mobs/<base>.lua, or None."""
    if not base:
        return None
    path = os.path.join(lua_dir, base + ".lua")
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def read_all_scripts(lua_dir):
    """{basename: text} for every mob script in a zone."""
    out = {}
    for fn in sorted(os.listdir(lua_dir)):
        if fn.endswith(".lua"):
            out[fn[:-4]] = read_script(lua_dir, fn[:-4])
    return out


def ph_entry(z, pid, chance, cooldown):
    pid = int(pid)
    return dict(Id=pid, Name=z.name_of(pid), Index=pid % 1024,
                Chance=chance, NMCooldown=cooldown,
                RespawnTime=z.respawn_of(z.tkey(pid)) or 300)


def lottery_nm(z, name, nm_id, chance, cooldown, phs):
    nm_id = int(nm_id)
    return dict(
        Name=name, ZoneId=z.zid,
        NMType="timed_lottery" if cooldown >= TIMED_LOTTERY_MIN_COOLDOWN else "true_lottery",
        NMMobId=nm_id, NMIndex=nm_id % 1024,
        Chance=chance, Cooldown=cooldown,
        WindowMin=0, WindowMax=0, WindowInterval=0, WindowCount=0,
        PHs=phs, _tkey=z.tkey(nm_id), _script=z.script_base(nm_id),
    )


def timed_nm(z, name, nm_id, ts, tkey, script):
    return dict(
        Name=name, ZoneId=z.zid, NMType="timed_spawn",
        NMMobId=nm_id, NMIndex=nm_id % 1024,
        Chance=100, Cooldown=0,
        # A single fixed timer (min == max) has no close time; 0 means "no known
        # close", so the tracker keeps showing it as open.
        WindowMin=ts[0], WindowMax=0 if ts[1] == ts[0] else ts[1],
        WindowInterval=ts[2], WindowCount=ts[3],
        PHs=[], _tkey=tkey, _script=script,
    )


def merge_phs(nm, phs):
    seen = {p["Id"] for p in nm["PHs"]}
    nm["PHs"].extend(p for p in phs if p["Id"] not in seen)


def era_window(zname, script):
    """(min, max) from the era old-NM-timer module, or None."""
    if not USE_ERA_TIMERS:
        return None
    key = (zname, script)
    if key in ERA_TIMED_NMS:
        return ERA_TIMED_NMS[key]
    if WOTG_ENABLED and key in ERA_WOTG_TIMED_NMS:
        return ERA_WOTG_TIMED_NMS[key]
    return None


def script_window(z, lua_dir, base):
    """Timed window for a script. The era module's value beats the script's own."""
    era = era_window(z.zname, base)
    if era:
        return era[0], era[1], 0, 0
    content = read_script(lua_dir, base)
    return parse_timed_spawn(content) if content else None


def ph_despawn_conf(contents):
    """{NM const: (chance, cooldown)} from every PH script's phOnDespawn."""
    conf = {}
    for text in contents.values():
        for m in _PH_DESPAWN.finditer(text):
            cooldown = int(m.group(3) or m.group(4) or 0)   # random(min,max): the max
            conf.setdefault(m.group(1), (int(m.group(2)), cooldown))
    return conf


def parse_ph_line(line, ids):
    """(nm_const, nm_id, ph_id) from one `entity.phList` line, or None."""
    m = re.match(r"\s*\[(.+)\]\s*=\s*(ID\.mob\.[A-Z0-9_]+(?:\[\d+\])?)", line)
    if not m:
        return None
    key_expr = m.group(1)
    if "ID.mob." in key_expr:
        ph_id = eval_ph_expr(key_expr, ids)
    else:
        ph_id = int(key_expr) if key_expr.strip().isdigit() else None
    target = _PH_EXPR.search(m.group(2))
    nm_id = eval_ph_expr(m.group(2), ids)
    if ph_id is None or nm_id is None or not target:
        return None
    return target.group(1), nm_id, ph_id


def ph_groups(contents, ids):
    """{(nm_const, nm_id): {placeholder ids}} from every entity.phList."""
    groups = {}
    for text in contents.values():
        at = text.find("entity.phList")
        if at < 0:
            continue
        for line in match_braces(text, at).splitlines():
            parsed = parse_ph_line(line, ids)
            if parsed:
                const, nm_id, ph_id = parsed
                groups.setdefault((const, nm_id), set()).add(ph_id)
    return groups


def legacy_lottery(z, lua_dir, nms):
    """Add lottery NMs defined by Lua (phList + phOnDespawn). YAML wins on overlap."""
    if not os.path.isdir(lua_dir):
        return
    ids = resolve_zone_ids(z, os.path.join(os.path.dirname(lua_dir), "IDs.lua"))
    if not ids:
        return
    contents = read_all_scripts(lua_dir)
    conf = ph_despawn_conf(contents)

    added = set()   # names created here, so several ids of one NM merge
    for (const, nm_id), ph_ids in sorted(ph_groups(contents, ids).items(), key=lambda kv: kv[0][1]):
        name = z.name_of(nm_id)
        if name in nms and name not in added:
            continue   # the YAML slot data is authoritative
        chance, cooldown = conf.get(const, (100, 0))
        phs = [ph_entry(z, pid, chance, cooldown) for pid in sorted(ph_ids) if pid != nm_id]
        if not phs:
            continue
        if name in added:
            merge_phs(nms[name], phs)
            continue
        added.add(name)
        nms[name] = lottery_nm(z, name, nm_id, chance, cooldown, phs)


# --------------------------------------------------------------------------- #
# NM assembly
# --------------------------------------------------------------------------- #
def slot_lottery_nms(z, nms):
    """Lottery NMs from the YAML `slots:` (members with a `chance` are NMs)."""
    for slot in z.slots:
        members = (slot or {}).get("members") or {}
        nm_ids = [mid for mid, v in members.items() if isinstance(v, dict) and "chance" in v]
        for nm_id in nm_ids:
            conf = members[nm_id]
            chance = int(conf.get("chance") or 0)
            cooldown = int(conf.get("cooldown") or 0)
            name = z.name_of(nm_id)
            phs = [ph_entry(z, mid, chance, cooldown)
                   for mid in members if mid != nm_id and mid not in nm_ids]
            existing = nms.get(name)
            if existing is None:
                nms[name] = lottery_nm(z, name, nm_id, chance, cooldown, phs)
                continue
            merge_phs(existing, phs)
            if int(nm_id) < existing["NMMobId"]:
                existing["NMMobId"], existing["NMIndex"] = int(nm_id), int(nm_id) % 1024


def apply_era_lottery_cooldowns(z, nms):
    """old_nm_respawn_timers.lua restores the 60 minute cooldown on a few lotteries."""
    if not USE_ERA_TIMERS:
        return
    for nm in nms.values():
        cooldown = ERA_LOTTERY_COOLDOWNS.get((z.zname, nm.get("_script")))
        if not cooldown:
            continue
        nm["Cooldown"] = cooldown
        nm["NMType"] = "timed_lottery"
        for ph in nm["PHs"]:
            ph["NMCooldown"] = cooldown


def reclassify_timed_lottery(z, lua_dir, nms):
    """Lottery NMs that also run their own timed respawn (King Arthro) are timed."""
    for nm in nms.values():
        ts = script_window(z, lua_dir, nm["_script"])
        if ts and ts[0] >= MIN_TIMED_WINDOW:
            nm.update(NMType="timed_spawn", WindowMin=ts[0], WindowMax=ts[1],
                      WindowInterval=ts[2], WindowCount=ts[3], Cooldown=0)


def timed_script_nms(z, lua_dir, nms, warn):
    """Timed-spawn NMs: a mob script that sets its own respawn window."""
    if not os.path.isdir(lua_dir):
        return
    by_script = {}
    for mid in z.spawns:
        by_script.setdefault(z.script_base(mid), []).append(int(mid))
    skip = ZONE_SKIP_SCRIPTS.get(z.zid, ())

    for fn in sorted(os.listdir(lua_dir)):
        base = fn[:-4]
        if not fn.endswith(".lua") or base in skip:
            continue
        ts = script_window(z, lua_dir, base)
        if not ts or ts[0] < MIN_TIMED_WINDOW:
            continue
        ids = sorted(by_script.get(base, []))
        tkey = z.tkey(ids[0]) if ids else base
        name = display(tkey, z.tmpl(tkey)) if tkey in z.templates else base.replace("_", " ")
        if name in nms:
            continue
        if not ids:
            warn(f"zone {z.zid} {z.zname}: timed NM {base} has no spawn id")
        nms[name] = timed_nm(z, name, ids[0] if ids else 0, ts, tkey, base)


def manual_nms(z, nms):
    """Hand-described NMs, only when nothing automatic claimed the name."""
    for name, m in (MANUAL_ENTRIES.get(z.zid) or {}).items():
        if name in nms:
            continue
        wmin, wmax = m.get("WindowMin", 0), m.get("WindowMax", 0)
        era = m.get("EraKey") and era_window(*m["EraKey"])
        if era:
            wmin, wmax = era[0], (0 if era[1] == era[0] else era[1])
        nms[name] = dict(
            Name=name, ZoneId=z.zid, NMType=m["NMType"],
            NMMobId=m["NMMobId"], NMIndex=m["NMMobId"] % 1024,
            Chance=m.get("Chance", 0), Cooldown=0,
            WindowMin=wmin, WindowMax=wmax,
            WindowInterval=0, WindowCount=0, PHs=[],
            _tkey=z.tkey(m["NMMobId"]) or name.replace(" ", "_"), _script=None,
        )


def build_nms(z, lua_dir, warn):
    """Return {nm_name: entry} for lottery + timed NMs in a zone."""
    nms = {}
    slot_lottery_nms(z, nms)
    legacy_lottery(z, lua_dir, nms)
    apply_era_lottery_cooldowns(z, nms)
    reclassify_timed_lottery(z, lua_dir, nms)
    timed_script_nms(z, lua_dir, nms, warn)
    manual_nms(z, nms)
    return nms


# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #
def zone_loot_only(z, nms, remove, replace):
    """{name: loot rows} for every non-NM template that has drops."""
    out = {}
    for key, tmpl in z.templates.items():
        name = display(key, tmpl)
        if name in nms or name in out:
            continue
        rows = build_loot(tmpl, remove, replace)
        if rows:
            out[name] = rows
    return out


def zone_respawns(z):
    """{spawn index: respawn seconds} for every spawn on a timer."""
    out = {}
    for mid in z.spawns:
        secs = z.respawn_of(z.tkey(mid))
        if secs > 0:
            out[int(mid) % 1024] = secs
    return out


def nm_line(z, name, nm, remove, replace):
    rows = build_loot(z.tmpl(nm["_tkey"]), remove, replace) if nm.get("_tkey") else []
    phs = ",".join(
        "{Id=%d,Name=%s,Index=%d,Chance=%d,NMCooldown=%d,RespawnTime=%d}"
        % (p["Id"], lua_str(p["Name"]), p["Index"], p["Chance"], p["NMCooldown"], p["RespawnTime"])
        for p in sorted(nm["PHs"], key=lambda p: p["Id"]))
    return ("  [%s]={Name=%s,ZoneId=%d,NMType=%s,NMMobId=%d,NMIndex=%d,Chance=%d,Cooldown=%d,"
            "WindowMin=%d,WindowMax=%d,WindowInterval=%d,WindowCount=%d,Loot=%s,PHs={%s}},"
            % (lua_str(name), lua_str(name), z.zid, lua_str(nm["NMType"]), nm["NMMobId"],
               nm["NMIndex"], nm["Chance"], nm["Cooldown"], nm["WindowMin"], nm["WindowMax"],
               nm["WindowInterval"], nm["WindowCount"], loot_lua(rows), phs))


def loot_only_line(z, name, rows):
    return ("  [%s]={Name=%s,ZoneId=%d,NMType='loot_only',NMMobId=0,NMIndex=0,Chance=0,Cooldown=0,"
            "WindowMin=0,WindowMax=0,Loot=%s,PHs={}},"
            % (lua_str(name), lua_str(name), z.zid, loot_lua(rows)))


def write_zone(out_dir, z, nms, remove, replace):
    """Write data/<zone>.lua. Returns the NM count, or 0 (and deletes any old
    file) when the zone has nothing to write."""
    path = os.path.join(out_dir, "%d.lua" % z.zid)
    loot_only = zone_loot_only(z, nms, remove, replace)
    resp = zone_respawns(z)

    if not (nms or loot_only or resp):
        if os.path.isfile(path):
            os.remove(path)
        return 0

    lines = ["-- Zone: %s (ID: %d)" % (z.zname.replace("_", " "), z.zid),
             "-- Generated by Eggs tools/generate.py. Do not edit manually.",
             "return {"]
    lines += [nm_line(z, name, nms[name], remove, replace) for name in sorted(nms)]
    lines += [loot_only_line(z, name, loot_only[name]) for name in sorted(loot_only)]
    if resp:
        lines.append("  ['__resp']={%s}," % ",".join("[%d]=%d" % kv for kv in sorted(resp.items())))
    lines.append("};")

    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    return len(nms)


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
def parse_args():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=DEFAULT_REPO, help="Phoenix workspace (default: %(default)s)")
    ap.add_argument("--out", default=os.path.normpath(os.path.join(here, "..", "data")))
    ap.add_argument("--zone", type=int, help="only regenerate this zone id")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--no-era-timers", action="store_true",
                    help="ignore modules/era old_nm_respawn_timers overrides "
                         "(use when RESTRICT_CONTENT is off / SOA is enabled)")
    ap.add_argument("--no-wotg", action="store_true", help="WotG content is disabled")
    return ap.parse_args()


def load_zone_doc(repo, zid, zname, overlays, warn):
    """Merged mobs.yaml for a zone (core + overlays), or None with a warning."""
    zdir = zone_dir_name(zname)
    ypath = os.path.join(repo, "data", "zones", zdir, "mobs.yaml")
    if not os.path.isfile(ypath):
        warn("no mobs.yaml for zone %d %s (%s)" % (zid, zname, zdir))
        return None
    try:
        doc = load_yaml(ypath)
    except Exception as e:
        warn("zone %d %s: YAML error: %s" % (zid, zname, e))
        return None
    if zdir in overlays:
        deep_merge(doc, overlays[zdir])
    return doc


def remove_stale_files(out_dir, written):
    """Delete data files for zones that were not generated this run."""
    for path in glob.glob(os.path.join(out_dir, "*.lua")):
        zid = os.path.basename(path)[:-4]
        if zid.isdigit() and int(zid) not in written:
            os.remove(path)
            print("removed stale %s" % os.path.basename(path))


def print_zone_summary(z, nms):
    kinds = {}
    for nm in nms.values():
        kinds[nm["NMType"]] = kinds.get(nm["NMType"], 0) + 1
    print("  %3d %-32s %3d NMs  %s" % (z.zid, z.zname, len(nms), kinds))


def main():
    a = parse_args()
    global USE_ERA_TIMERS, WOTG_ENABLED
    USE_ERA_TIMERS = not a.no_era_timers
    WOTG_ENABLED = not a.no_wotg

    repo, out_dir = a.repo, a.out
    if not os.path.isdir(os.path.join(repo, "data", "zones")):
        sys.exit("Not a Phoenix workspace (missing data/zones): %s" % repo)
    os.makedirs(out_dir, exist_ok=True)

    warnings = []
    zones = load_zone_settings(repo)
    active = load_active_modules(repo)
    overlays = load_overlays(repo, active)
    remove, replace = load_droplist_mods(repo, active, load_item_enum(repo))
    print("repo=%s  zones=%d  active modules=%d  overlays=%d  blanket removals=%d  swaps=%d"
          % (repo, len(zones), len(active), len(overlays), len(remove), len(replace)))

    total_nms = 0
    written = set()
    for zid in sorted(zones):
        if a.zone is not None and zid != a.zone:
            continue
        zname = zones[zid]
        doc = load_zone_doc(repo, zid, zname, overlays, warnings.append)
        if doc is None:
            continue

        z = Zone(zid, zname, zone_dir_name(zname), doc)
        lua_dir = os.path.join(repo, "scripts", "zones", zname, "mobs")
        nms = build_nms(z, lua_dir, warnings.append)
        n = write_zone(out_dir, z, nms, remove, replace)
        if os.path.isfile(os.path.join(out_dir, "%d.lua" % zid)):
            written.add(zid)
            total_nms += n
        if n and not a.quiet:
            print_zone_summary(z, nms)

    if a.zone is None:
        remove_stale_files(out_dir, written)

    errors_path = os.path.normpath(os.path.join(out_dir, "..", "errors.txt"))
    with open(errors_path, "w", encoding="utf-8") as f:
        f.write("\n".join(warnings) + ("\n" if warnings else ""))
    print("wrote %d zone files, %d NMs, %d warnings (see errors.txt)"
          % (len(written), total_nms, len(warnings)))


if __name__ == "__main__":
    main()
