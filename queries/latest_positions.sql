-- Last N received positions. ALWAYS order/filter by fixtime on this hypertable —
-- ORDER BY id or servertime alone has no global index and decompresses everything.
SELECT id, deviceid, fixtime, servertime, latitude, longitude, speed
FROM tc_positions
WHERE fixtime > now() - interval '1 hour'
ORDER BY fixtime DESC
LIMIT 10;

-- Current (latest) position of every device without scanning tc_positions:
-- Traccar maintains tc_devices.positionid = the device's latest position id.
-- SELECT d.name, d.uniqueid, p.*
-- FROM tc_devices d
-- JOIN tc_positions p ON p.id = d.positionid;

-- Last 10 positions for one device (fast even in compressed history):
-- SELECT * FROM tc_positions
-- WHERE deviceid = :device_id
-- ORDER BY fixtime DESC LIMIT 10;
