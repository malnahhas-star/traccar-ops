#!/usr/bin/env python3
"""
Uffizio Phase-1 EVENTS consumer — reads the `alertnotification` Kafka topic
(protobuf) through the SSH tunnel and inserts each alert into `tc_events`.

Field map (decoded from AlertNotificationProtobuf$Notification):
  f2  notificationType (1=ALERT,2=REMINDER,4=ELOCK,...)
  f4  specificationId  -> event type name via uffizio_alarm_spec
  f5  specificationCategoryId
  f7  latitude  (fixed64 double)
  f8  longitude (fixed64 double)
  f12 location (address string)
  f16 vehicleId -> imei (uffizio_vehicle_map) -> tc_devices.id
  f20 time (ms epoch) -> eventtime
  f22 meta (repeated {1:key,2:value})
"""
import sys, json, time, logging, os, struct
sys.path.insert(0, "/home/ubuntu/pylib")
from datetime import datetime, timezone
from kafka import KafkaConsumer
import psycopg2, psycopg2.extras

log = logging.getLogger("uffizio-ev")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                    handlers=[logging.StreamHandler(sys.stdout)])
KAFKA  = os.environ.get("UFFIZIO_KAFKA", "bango:9092")
DB_DSN = "host=127.0.0.1 port=5432 dbname=traccar user=traccar password=" + os.environ.get("TRACCAR_PW", "")
NOTIF = {0:"unknown",1:"alert",2:"reminder",3:"crmTicket",4:"elock",5:"employeeLeave",6:"vehicleExpiry"}

def rv(b, i):
    s = r = 0
    while i < len(b):
        x = b[i]; i += 1; r |= (x & 0x7f) << s
        if not x & 0x80: break
        s += 7
    return r, i

def parse(b):
    i = 0; out = {}; meta = []
    while i < len(b):
        tag, i = rv(b, i); fn = tag >> 3; wt = tag & 7
        if wt == 0:
            v, i = rv(b, i); out.setdefault(fn, v)
        elif wt == 2:
            ln, i = rv(b, i); val = b[i:i+ln]; i += ln
            if fn == 22: meta.append(val)
            else: out.setdefault(fn, val)
        elif wt == 1:
            out.setdefault(fn, struct.unpack("<d", b[i:i+8])[0]); i += 8
        elif wt == 5: i += 4
        else: break
    out["_meta"] = meta
    return out

def meta_dict(meta):
    d = {}
    for sub in meta:
        f = {}; i = 0
        while i < len(sub):
            tag, i = rv(sub, i); fn = tag >> 3; wt = tag & 7
            if wt == 2:
                ln, i = rv(sub, i); f[fn] = sub[i:i+ln]; i += ln
            elif wt == 0: v, i = rv(sub, i); f[fn] = v
            else: break
        k = f.get(1); v = f.get(2)
        if isinstance(k, bytes): k = k.decode(errors="replace")
        if isinstance(v, bytes): v = v.decode(errors="replace")
        if k: d[k] = v
    return d

class DB:
    def __init__(self):
        self.c = psycopg2.connect(DB_DSN); self.c.autocommit = False
        self.veh = {}    # vehicle_id -> imei
        self.spec = {}   # spec_id -> name (raw customer name)
        self.norm = {}   # spec_id -> (traccar_type, alarm_subtype)
        self.dev = {}    # imei -> deviceid
        self._load()
    def _load(self):
        with self.c.cursor() as cur:
            cur.execute("SELECT vehicle_id, imei FROM telematics.uffizio_vehicle_map")
            self.veh = {v: i for v, i in cur.fetchall()}
            cur.execute("SELECT spec_id, name FROM telematics.uffizio_alarm_spec")
            self.spec = {s: n for s, n in cur.fetchall()}
            cur.execute("SELECT spec_id, traccar_type, alarm_subtype FROM telematics.uffizio_alarm_norm")
            self.norm = {s: (t, a) for s, t, a in cur.fetchall()}
            cur.execute("SELECT uniqueid, id FROM tc_devices")
            self.dev = {u: d for u, d in cur.fetchall()}
        self.c.commit()
        log.info("maps: %d vehicles, %d specs, %d norm, %d devices",
                 len(self.veh), len(self.spec), len(self.norm), len(self.dev))
    def device_id(self, imei, cur):
        d = self.dev.get(imei)
        if d: return d
        cur.execute("INSERT INTO tc_devices(name,uniqueid) VALUES(%s,%s) "
                    "ON CONFLICT (uniqueid) DO UPDATE SET uniqueid=EXCLUDED.uniqueid RETURNING id", (imei, imei))
        d = cur.fetchone()[0]; self.dev[imei] = d; return d
    def insert(self, evs):
        if not evs: return 0
        with self.c.cursor() as cur:
            vals = []
            for e in evs:
                imei = self.veh.get(e["vehicle_id"])
                if not imei:
                    continue
                did = self.device_id(imei, cur)
                vals.append((e["type"], e["eventtime"], did, e["attrs"]))
            if vals:
                psycopg2.extras.execute_values(cur,
                    "INSERT INTO tc_events(type, eventtime, deviceid, attributes) VALUES %s", vals)
        self.c.commit()
        return len(vals)

def to_event(b, db):
    f = parse(b)
    vid = f.get(16)
    if vid is None: return None
    ts = f.get(20)
    et = datetime.fromtimestamp(ts/1000, tz=timezone.utc).replace(tzinfo=None) if ts else datetime.utcnow()
    spec_id = f.get(4)
    raw_name = db.spec.get(spec_id)
    norm = db.norm.get(spec_id)                    # (traccar_type, alarm_subtype)
    if norm:
        typ, subtype = norm
    else:                                          # spec not in norm map -> NOTIF fallback
        typ, subtype = (NOTIF.get(f.get(2)) or "alarm"), None
    loc = f.get(12)
    if isinstance(loc, bytes): loc = loc.decode(errors="replace")
    attrs = {"source": "uffizio", "specificationId": spec_id, "uffizioSpec": raw_name,
             "notificationType": NOTIF.get(f.get(2)), "location": loc}
    if subtype:                                    # Traccar alarm subtype (sos/hardBraking/...)
        attrs["alarm"] = subtype
    lat, lng = f.get(7), f.get(8)
    if isinstance(lat, float) and isinstance(lng, float):
        attrs["latitude"] = round(lat, 6); attrs["longitude"] = round(lng, 6)
    attrs.update({("meta_" + k): v for k, v in meta_dict(f.get("_meta", [])).items()})
    return {"vehicle_id": vid, "eventtime": et, "type": (typ or "alarm")[:128], "attrs": json.dumps(attrs, ensure_ascii=False)}

def main():
    db = DB()
    consumer = KafkaConsumer("alertnotification", bootstrap_servers=[KAFKA],
        group_id="uffizio-events-bridge", enable_auto_commit=False,
        auto_offset_reset="latest", api_version=(2, 6, 1),
        max_poll_records=200, consumer_timeout_ms=5000)
    log.info("consuming alertnotification -> tc_events")
    batch = []; ins = skip = 0; last = time.time()
    while True:
        try:
            for m in consumer:
                e = to_event(m.value, db)
                if e: batch.append(e)
                else: skip += 1
                if len(batch) >= 200:
                    ins += db.insert(batch); batch = []; consumer.commit()
            if batch:
                ins += db.insert(batch); batch = []; consumer.commit()
            if time.time() - last >= 60:
                log.info("events inserted=%d skipped=%d", ins, skip); last = time.time(); db._load()
        except Exception as ex:
            log.error("loop error: %s", ex); time.sleep(5)
            try: db = DB()
            except Exception: pass

if __name__ == "__main__":
    main()
