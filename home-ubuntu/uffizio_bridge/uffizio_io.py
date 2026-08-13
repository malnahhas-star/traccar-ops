"""
Shared Uffizio IO-value decoding for the positions consumer and the history
import (single source of truth so the two never drift).

Uffizio delivers IO as {id: value} pairs (Kafka repeated io{1:id,2:value}, or the
MySQL `iovalue` "id=val,id=val" string). The numeric id space is largely
protocol-native AVL ids mixed with Uffizio's own "getter" fields, and the SAME
high ids recur across protocols — so a name map is only safe when scoped to the
protocol it was verified for. Teltonika (~95% of the fleet) uses the documented
Teltonika FMB AVL ids; those are mapped to Traccar-standard attribute keys.

Design guarantees:
  * the raw `io<id>` is ALWAYS kept -> no data loss, and non-teltonika protocols
    (native ids not yet mapped) still carry every value verbatim.
  * ids only get a friendly alias when the protocol has a verified map entry.
  * Uffizio stores negative/computed getter ids as unsigned 64-bit; those are
    folded back to signed (io-1 instead of io18446744073709551615).

Non-teltonika native maps (ruptela/gl200/gt06/galileo/jt808) are intentionally
left raw until Uffizio's parameter/getter definition table can be read (the
source MySQL is saturated by the history import while it runs). Add them here.
"""

U64 = 1 << 64
S63 = 1 << 63

# Teltonika FMB AVL id -> (traccar_attribute_key, kind)
# kind: 'bool' | 'int' | 'volt' (mV->V, matches Traccar) | 'dop' (x10 -> value) | 'raw'
TELTONIKA = {
    239: ("ignition", "bool"),
    240: ("motion", "bool"),
    80:  ("dataMode", "int"),
    21:  ("rssi", "int"),           # GSM signal 1..5
    200: ("sleepMode", "int"),
    205: ("cid", "int"),            # GSM cell id
    206: ("lac", "int"),            # GSM area code
    241: ("operator", "int"),       # GSM operator code
    24:  ("gpsSpeed", "int"),       # km/h (top-level speed comes from the fix)
    16:  ("odometer", "int"),       # total odometer, meters (Traccar: meters)
    199: ("tripOdometer", "int"),
    66:  ("power", "volt"),         # external voltage mV -> V
    67:  ("battery", "volt"),       # battery voltage mV -> V
    68:  ("batteryCurrent", "int"),
    113: ("batteryLevel", "int"),   # %
    181: ("pdop", "dop"),           # x10
    182: ("hdop", "dop"),           # x10
    1:   ("din1", "bool"),
    2:   ("din2", "bool"),
    3:   ("din3", "bool"),
    179: ("dout1", "bool"),
    180: ("dout2", "bool"),
    9:   ("adc1", "int"),
    78:  ("driverUniqueId", "raw"), # iButton / 1-Wire
    72:  ("temp1", "int"),
    73:  ("temp2", "int"),
    74:  ("temp3", "int"),
    75:  ("temp4", "int"),
    # OBD/CAN block (present when an OBD dongle is fitted) -- standard Teltonika ids
    30:  ("dtcCount", "int"),
    31:  ("engineLoad", "int"),
    32:  ("coolantTemp", "int"),
    36:  ("rpm", "int"),
    37:  ("obdSpeed", "int"),
    41:  ("throttle", "int"),
    42:  ("engineHours", "int"),
    48:  ("fuel", "int"),           # fuel level %
}

# protocol -> {id: (key, kind)}. Add ruptela/gl200/gt06/galileo/jt808 once the
# Uffizio getter table is available (see module docstring).
PROTO_IO = {
    "teltonika": TELTONIKA,
}

def norm_id(iid):
    """Fold Uffizio's unsigned-64 encoding of negative/getter ids back to signed."""
    try:
        iid = int(iid)
    except (TypeError, ValueError):
        return None
    if iid >= S63:
        iid -= U64
    return iid

def _coerce(kind, val):
    s = str(val).strip()
    if kind == "bool":
        return s in ("1", "true", "True", "on", "ON")
    if kind == "volt":
        try: return round(int(float(s)) / 1000.0, 3)
        except ValueError: return s
    if kind == "dop":
        try: return round(float(s) / 10.0, 2)
        except ValueError: return s
    if kind == "int":
        try: return int(float(s))
        except ValueError: return s
    return val  # raw

def add_io(a, protocol, iid, val):
    """Add one IO pair to attributes dict `a`. Named (mapped) fields become their
    Traccar alias. Unmapped raw fields are kept as io<id> ONLY when they carry real
    device signal — Uffizio's internal 'getter' fields (negative/folded ids) and
    all-zero fields are dropped (they bloat rows ~5x and don't compress). This keeps
    genuine raw device telemetry while shedding Uffizio's proprietary derived noise.
    `val` may be str/bytes/int."""
    iid = norm_id(iid)
    if iid is None:
        return
    if isinstance(val, bytes):
        try: val = val.decode()
        except Exception: val = val.hex()
    m = PROTO_IO.get(protocol)
    if m and iid in m:
        key, kind = m[iid]
        a[key] = _coerce(kind, val)     # named alias captures it; no raw duplicate
        return
    if iid < 0:                          # Uffizio internal/computed getter -> drop
        return
    sval = "" if val is None else str(val).strip()
    if sval in ("", "0", "0.0", "0.00"):  # zero/blank raw field -> no signal, drop
        return
    a["io%d" % iid] = val

def io_attrs_from_pairs(protocol, pairs):
    """pairs: iterable of (id, value). Returns an attributes dict."""
    a = {}
    for iid, val in pairs:
        add_io(a, protocol, iid, val)
    return a

def io_attrs_from_string(protocol, iovalue):
    """Uffizio MySQL `iovalue` = 'id=val,id=val'. Returns an attributes dict."""
    a = {}
    if not iovalue:
        return a
    for kv in iovalue.split(","):
        if "=" not in kv:
            continue
        k, _, v = kv.partition("=")
        add_io(a, protocol, k.strip(), v.strip())
    return a
