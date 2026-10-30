import Foundation

// Exercises the real power assertions without enabling the physical input lock.
var ac = NativePowerSource.current().acPower
let awake = KeepAwakeController(powerSource: { PowerSourceState(acPower: ac) })
var locked = false
print("READY \(ProcessInfo.processInfo.processIdentifier) LEASE=\(KeepAwakeController.leaseDuration) AC=\(ac)")
fflush(stdout)
while let command = readLine() {
    switch command {
    case "lock": locked = true
    case "unlock": locked = false
    case "battery": ac = false
    case "ac": ac = true
    case "renew": break
    case "status":
        print("ACTIVE=\(awake.active)"); fflush(stdout)
        continue
    case "quit": awake.stop(); exit(0)
    default: exit(2)
    }
    if let error = awake.update(locked: locked, enabled: true) {
        print("ERROR \(error)")
    } else {
        print("ACTIVE=\(awake.active)")
    }
    fflush(stdout)
}
awake.stop()
