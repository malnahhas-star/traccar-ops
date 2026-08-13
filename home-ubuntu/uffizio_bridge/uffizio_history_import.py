#!/usr/bin/env python3
"""
Uffizio 6-month history import — streams one UTC day of gps_device_data from
Uffizio's MySQL (via SSH relay DB VM->F01->Uffizio, mysql runs on the Uffizio
box which reaches the remote MySQL) and bulk-loads it into tc_positions with the
true protocol. Streaming: no staging on Uffizio; resumable per day.

Usage:  uffizio_history_import.py START_YYYY-MM-DD END_YYYY-MM-DD   (END exclusive)
Reads the whole [START,END) window in ONE mysql scan — older data lives in
MONTHLY partitions whose PK leads with imei_no, so a per-day range still
full-scans the month; scanning a whole month once is ~30x cheaper.
Marks source='uffizio_hist'. Not auto-idempotent — driver deletes on retry.
"""
import sys, os, io, json, subprocess, logging
sys.path.insert(0, "/home/ubuntu/pylib")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from datetime import datetime, timezone, timedelta
import psycopg2
from uffizio_io import io_attrs_from_string   # shared IO decode (protocol-aware)

log = logging.getLogger("uff-hist")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                    handlers=[logging.StreamHandler(sys.stderr)])   # stderr streams live to the driver log

DB_DSN = "host=127.0.0.1 port=5432 dbname=traccar user=traccar password=" + os.environ.get("TRACCAR_PW", "")
MYSQL_H, MYSQL_U, MYSQL_P, MYSQL_DB = "80.225.74.41", "com_live", os.environ.get("UFFIZIO_MYSQL_PW",""), "gps"

def epoch_ms(d):
    return int(datetime.strptime(d, "%Y-%m-%d").replace(tzinfo=timezone.utc).timestamp()*1000)

class Importer:
    def __init__(self):
        self.c = psycopg2.connect(DB_DSN); self.c.autocommit = False
        with self.c.cursor() as cur:
            cur.execute("SELECT imei, protocol FROM telematics.uffizio_device_map WHERE target='traccar'")
            self.proto = {i: p for i, p in cur.fetchall()}
            cur.execute("SELECT uniqueid, id FROM tc_devices")
            self.dev = {u: d for u, d in cur.fetchall()}
        self.c.commit()
        log.info("maps: %d protos, %d devices", len(self.proto), len(self.dev))
    def device_id(self, imei, cur):
        d = self.dev.get(imei)
        if d: return d
        cur.execute("INSERT INTO tc_devices(name,uniqueid) VALUES(%s,%s) "
                    "ON CONFLICT (uniqueid) DO UPDATE SET uniqueid=EXCLUDED.uniqueid RETURNING id",(imei,imei))
        d = cur.fetchone()[0]; self.dev[imei] = d; return d
    def import_range(self, start, end):
        lo, hi = epoch_ms(start), epoch_ms(end)
        # stream from Uffizio MySQL over the SSH relay
        sql = ("SELECT imei_no,data_received_time,latitude,longitude,speed,angle,altitude,"
               "satellites,odom,movement,data_validity,iovalue FROM gps_device_data "
               "WHERE data_received_time>=%d AND data_received_time<%d "
               "AND (latitude<>0 OR longitude<>0)" % (lo, hi))
        remote = ("mysql -h %s -u %s -p'%s' %s -N --quick -e \"%s\""
                  % (MYSQL_H, MYSQL_U, MYSQL_P, MYSQL_DB, sql))
        ssh = ["ssh","-i","/home/ubuntu/.keys/bango.key","-o","StrictHostKeyChecking=no","-o","BatchMode=yes",
               "-o","ProxyCommand=ssh -i /home/ubuntu/.keys/f01.key -o StrictHostKeyChecking=no -o BatchMode=yes -W %h:%p ubuntu@20.0.4.234",
               "ubuntu@158.101.239.53", remote]
        def num(x):
            try: return float(x)
            except: return 0.0
        def inum(x):                          # integer-ish field -> clean "0" on NULL/blank/garbage
            try: return str(int(float(x)))
            except: return "0"
        p = subprocess.Popen(ssh, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=1<<20)
        buf = io.StringIO(); n = 0; cur = self.c.cursor()
        for raw in p.stdout:
            f = raw.decode("utf-8","replace").rstrip("\n").split("\t")
            if len(f) < 12: continue
            imei = f[0].strip()
            try:
                ts = int(f[1]); lat = int(f[2])/1e7; lng = int(f[3])/1e7
            except ValueError: continue
            if not (-90 <= lat <= 90 and -180 <= lng <= 180): continue
            proto = self.proto.get(imei, "teltonika")
            did = self.device_id(imei, cur)
            ft = datetime.utcfromtimestamp(ts/1000).strftime("%Y-%m-%d %H:%M:%S")
            attrs = io_attrs_from_string(proto, f[11])
            attrs["satellites"] = f[7]; attrs["odometer_raw"] = f[8]
            attrs["movement"] = f[9]; attrs["source"] = "uffizio_hist"
            valid = "t" if f[10] == "valid" else "f"
            row = "\t".join([str(did), proto, ft, ft, ft, valid,
                             repr(lat), repr(lng), inum(f[6]),
                             repr(num(f[4])/1.852), inum(f[5]),
                             json.dumps(attrs, ensure_ascii=False).replace("\\","\\\\").replace("\t"," ")]) + "\n"
            buf.write(row); n += 1
            if n % 100000 == 0:
                buf.seek(0)
                cur.copy_expert("COPY tc_positions(deviceid,protocol,servertime,devicetime,fixtime,valid,"
                                "latitude,longitude,altitude,speed,course,attributes) FROM STDIN", buf)
                self.c.commit()                       # commit each batch: durable + no big rollback
                buf = io.StringIO()
                if n % 1000000 == 0:
                    log.info("  %s..%s: %d rows loaded...", start, end, n)
        err = p.stderr.read().decode("utf-8", "replace")
        p.wait()
        # CRITICAL: a broken/truncated source stream (mysql/ssh error mid-result) must
        # NOT be treated as success — otherwise the month is silently truncated. ssh
        # propagates the remote exit code; mysql exits non-zero on a lost connection.
        if p.returncode != 0:
            self.c.rollback()   # drop the uncommitted tail; committed batches cleaned on retry
            raise RuntimeError("source stream FAILED for %s..%s at %d rows (rc=%d): %s"
                               % (start, end, n, p.returncode, err.strip()[:300]))
        if buf.tell():
            buf.seek(0)
            cur.copy_expert("COPY tc_positions(deviceid,protocol,servertime,devicetime,fixtime,valid,"
                            "latitude,longitude,altitude,speed,course,attributes) FROM STDIN", buf)
        self.c.commit()
        return n

if __name__ == "__main__":
    imp = Importer()
    cnt = imp.import_range(sys.argv[1], sys.argv[2])
    print("RANGE %s..%s inserted=%d" % (sys.argv[1], sys.argv[2], cnt))
