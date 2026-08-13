#!/usr/bin/env python3
"""
Uffizio Phase-1 consumer — reads the Uffizio Kafka `gps` topic (decoded
protobuf, through the SSH tunnel on localhost:9092) and inserts each position
into our Traccar `tc_positions` with the TRUE protocol (from uffizio_device_map).

Runs on the DB VM. Deps in /home/ubuntu/pylib (kafka-python, psycopg2).
Durable consumer group → resumes from last committed offset after a restart.
"""
import sys, os, json, time, logging
sys.path.insert(0, "/home/ubuntu/pylib")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from datetime import datetime, timezone
from kafka import KafkaConsumer
import psycopg2, psycopg2.extras
from uffizio_io import io_attrs_from_pairs   # shared IO decode (protocol-aware)

log = logging.getLogger("uffizio")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                    handlers=[logging.StreamHandler(sys.stdout)])

KAFKA   = os.environ.get("UFFIZIO_KAFKA", "bango:9092")
DB_DSN  = os.environ.get("UFFIZIO_DB",
            "host=127.0.0.1 port=5432 dbname=traccar user=traccar password=" + os.environ.get("TRACCAR_PW", ""))
BATCH   = 500
FLUSH_S = 5.0

def rv(b, i):
    s = r = 0
    while i < len(b):
        x = b[i]; i += 1; r |= (x & 0x7f) << s
        if not x & 0x80: break
        s += 7
    return r, i

def parse(b):
    """Return {field_no: value}. Repeated field 8 collected as list of submsgs."""
    i = 0; out = {}; io = []
    while i < len(b):
        tag, i = rv(b, i); fn = tag >> 3; wt = tag & 7
        if wt == 0:
            v, i = rv(b, i)
            if fn == 8: io.append(v)
            else: out.setdefault(fn, v)
        elif wt == 2:
            ln, i = rv(b, i); val = b[i:i+ln]; i += ln
            if fn == 8: io.append(val)
            else: out.setdefault(fn, val)
        elif wt == 5: i += 4
        elif wt == 1: i += 8
        else: break
    out["_io"] = io
    return out

def io_pairs(io_list):
    """Decode repeated IO submessages {1:id, 2:value} into raw (id, value) pairs.
    Naming is applied later (in DB.insert), once the device's protocol is known."""
    pairs = []
    for sub in io_list:
        if not isinstance(sub, bytes):
            continue
        f = {}; i = 0
        while i < len(sub):
            tag, i = rv(sub, i); fn = tag >> 3; wt = tag & 7
            if wt == 0: v, i = rv(sub, i); f[fn] = v
            elif wt == 2:
                ln, i = rv(sub, i); f[fn] = sub[i:i+ln]; i += ln
            else: break
        iid = f.get(1)
        if iid is None:
            continue
        pairs.append((iid, f.get(2)))
    return pairs

def to_position(msg):
    f = parse(msg)
    imei = f.get(1)
    if isinstance(imei, bytes): imei = imei.decode(errors="replace")
    if not imei or f.get(2) is None or f.get(3) is None:
        return None
    lat = f[2] / 1e7; lng = f[3] / 1e7
    if not (-90 <= lat <= 90 and -180 <= lng <= 180):
        return None
    ts_ms = f.get(9)
    fixtime = datetime.fromtimestamp(ts_ms/1000, tz=timezone.utc) if ts_ms else datetime.now(timezone.utc)
    return {
        "imei": imei,
        "fixtime": fixtime.replace(tzinfo=None),
        "lat": lat, "lng": lng,
        "altitude": 0,   # field 4 is speed, not altitude
        "course": f.get(6) or 0,   # field 6 is heading 0-360 (field 5 is odometer)
        "speed_knots": (f.get(4) or 0) / 1.852,   # Uffizio km/h (protobuf field 4) -> knots
        "satellites": f.get(7),
        "odometer": f.get(5),   # protobuf field 5 = odometer meters (matches Uffizio)
        "io_pairs": io_pairs(f.get("_io", [])),   # named in DB.insert (needs protocol)
    }

class DB:
    def __init__(self):
        self.c = psycopg2.connect(DB_DSN); self.c.autocommit = False
        self.dev = {}       # imei -> deviceid
        self.proto = {}     # imei -> protocol
        self._load_map()
    def _load_map(self):
        with self.c.cursor() as cur:
            cur.execute("SELECT imei, protocol, target FROM telematics.uffizio_device_map")
            for imei, proto, target in cur.fetchall():
                self.proto[imei] = proto if target == "traccar" else None
            cur.execute("SELECT uniqueid, id FROM tc_devices")
            for uid, did in cur.fetchall():
                self.dev[uid] = did
        self.c.commit()
        log.info("map loaded: %d protocol rows, %d known devices", len(self.proto), len(self.dev))
    def device_id(self, imei, cur):
        d = self.dev.get(imei)
        if d: return d
        cur.execute("INSERT INTO tc_devices(name, uniqueid) VALUES(%s,%s) "
                    "ON CONFLICT (uniqueid) DO UPDATE SET uniqueid=EXCLUDED.uniqueid RETURNING id",
                    (imei, imei))
        d = cur.fetchone()[0]; self.dev[imei] = d
        return d
    def insert(self, rows):
        if not rows: return 0
        with self.c.cursor() as cur:
            vals = []
            for r in rows:
                proto = self.proto.get(r["imei"], "teltonika")   # default for unmapped new devices
                if proto is None:      # target = media/retire -> skip
                    continue
                did = self.device_id(r["imei"], cur)
                attrs = io_attrs_from_pairs(proto, r["io_pairs"])   # protocol-aware naming + raw io<id>
                attrs["satellites"] = r["satellites"]
                attrs["source"] = "uffizio"
                if r.get("odometer") is not None:
                    attrs["odometer"] = r["odometer"]
                    attrs["totalDistance"] = r["odometer"]
                vals.append((did, proto, r["fixtime"], r["fixtime"], r["fixtime"],
                             True, r["lat"], r["lng"], r["altitude"], r["speed_knots"],
                             r["course"], json.dumps(attrs, ensure_ascii=False)))
            if not vals:
                self.c.commit(); return 0
            # insert positions, capturing the new ids so we can back-link devices
            returned = psycopg2.extras.execute_values(cur,
                "INSERT INTO tc_positions(deviceid,protocol,servertime,devicetime,fixtime,"
                "valid,latitude,longitude,altitude,speed,course,attributes) VALUES %s "
                "RETURNING id, deviceid, fixtime", vals, fetch=True)
            # newest position per device in this batch
            latest = {}
            for pid, did, ft in returned:
                if did not in latest or ft > latest[did][1]:
                    latest[did] = (pid, ft)
            # update tc_devices.positionid + lastupdate (only if newer) — like Traccar does
            dev_rows = [(pid, ft, did) for did, (pid, ft) in latest.items()]
            psycopg2.extras.execute_values(cur,
                "UPDATE tc_devices d SET positionid = v.pid, lastupdate = v.ft "
                "FROM (VALUES %s) AS v(pid, ft, did) "
                "WHERE d.id = v.did AND (d.lastupdate IS NULL OR d.lastupdate < v.ft)",
                dev_rows, template="(%s, %s::timestamp, %s)")
        self.c.commit()
        return len(vals)

def main():
    db = DB()
    consumer = KafkaConsumer("gps", bootstrap_servers=[KAFKA],
        group_id="uffizio-gps-bridge", enable_auto_commit=False,
        auto_offset_reset="latest", api_version=(2, 6, 1),
        max_poll_records=BATCH, consumer_timeout_ms=int(FLUSH_S*1000))
    log.info("consuming gps from %s -> tc_positions", KAFKA)
    batch = []; inserted = skipped = 0; last = time.time()
    while True:
        try:
            for m in consumer:
                p = to_position(m.value)
                if p: batch.append(p)
                else: skipped += 1
                if len(batch) >= BATCH:
                    inserted += db.insert(batch); batch = []
                    consumer.commit()
            # idle timeout -> flush
            if batch:
                inserted += db.insert(batch); batch = []; consumer.commit()
            if time.time() - last >= 60:
                log.info("inserted=%d skipped=%d devices=%d", inserted, skipped, len(db.dev))
                last = time.time()
                db._load_map()   # refresh protocol map + device cache periodically
        except Exception as e:
            log.error("loop error: %s", e); time.sleep(5)
            try: db = DB()
            except Exception as e2: log.error("db reconnect failed: %s", e2)

if __name__ == "__main__":
    main()
