# Vedette RunningBoardd Probe

A standalone, **log-only** RootHide probe for iOS 15 research. It injects only into `runningboardd`, discovers candidate RunningBoard Objective-C instance methods at runtime, and hooks only methods whose live Objective-C type encoding proves they are `void method(id process)`.

It does not inject UIKit apps, SpringBoard, or ordinary daemons. It does not scan PIDs, schedule timers, alter process state, change CPU policy, call `kill`, or invoke any `proc_*cpu*` APIs.

## Device logs (iOS 15 RootHide)

The iOS `log` utility is not macOS unified-log streaming, so this Probe also
writes an append-only text file outside the randomized RootHide jailbreak root:

```sh
# Follow events live
 tail -f /var/mobile/Media/VDTProbe.log
# Print the captured events after a test
cat /var/mobile/Media/VDTProbe.log
# Clear only the prior probe log before a fresh test round
: > /var/mobile/Media/VDTProbe.log
```

The startup discovery lines report whether each candidate class/selector actually exists on the target runtime and whether its ABI made it safe for this probe to hook. Trigger lines are normalized as:

```text
[VDTProbe] class=… selector=… pid=… bundleID=… executable=… processName=… timestamp=…
```

`(null)` is emitted for unavailable metadata. Repeated events are intentionally retained; no PID deduplication is performed in this probe.
