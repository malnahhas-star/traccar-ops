# Traccar GroundSpeed handler (T01 + T02)

Shadows stock Traccar 6.13.3 `org.traccar.handler.DistanceHandler` to also emit
`attributes.groundSpeed` (km/h) = GPS displacement / time between consecutive fixes.
Reason: device-reported speed is garbage for Uffizio-origin Teltonika devices
(corr 0.14 vs GPS ground; 26% of positions >200 km/h). See memory teltonika-speed-decode-bug.

Both the device speed (position.speed, knots) and groundSpeed are stored per position,
so FleetBack can switch per vehicle via telematics.vehicles.speed_source.

## Build (needs JDK 17 + traccar jar/lib on classpath)
    javac -cp "tracker-server.jar:lib/*" -d out DistanceHandler.java

## Deploy (per node: T01 145.241.108.6 / T02 84.8.100.212, ubuntu, ssh -o IdentitiesOnly=yes)
    scp DistanceHandler.class <node>:/tmp/
    sudo mkdir -p /opt/traccar/override/org/traccar/handler
    sudo cp /tmp/DistanceHandler.class /opt/traccar/override/org/traccar/handler/
    # systemd drop-in puts override/ first on classpath (stock unit uses `-jar`, which ignores override)
    /etc/systemd/system/traccar.service.d/override.conf:
      [Service]
      ExecStart=
      ExecStart=/opt/traccar/jre/bin/java -Xms4g -Xmx16g -cp override:tracker-server.jar:lib/* org.traccar.Main conf/traccar.xml
    sudo systemctl daemon-reload && sudo systemctl restart traccar

## Rollback (revert to stock)
    sudo rm /etc/systemd/system/traccar.service.d/override.conf
    sudo rm -rf /opt/traccar/override/org
    sudo systemctl daemon-reload && sudo systemctl restart traccar

## Verify
    positions in last 2m: attributes ? 'groundSpeed'; median ~30 km/h; >200km/h share ~0.2% (device: ~26%)
