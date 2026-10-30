import Darwin
import Foundation

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
if arguments.contains("--lid-service") { runLidService(files: LidServiceFiles(simulation: nil)) }
if let simulation = argument("--lid-service-simulate") {
    let lease = argument("--lease").flatMap(Double.init) ?? 0.6
    guard geteuid() != 0, (0.3...6).contains(lease) else { exit(2) }
    runLidService(files: LidServiceFiles(simulation: simulation), lease: lease)
}
if arguments.contains("--lid-watchdog") {
    guard let owner = argument("--owner").flatMap(Int32.init),
          let lease = argument("--lease").flatMap(Double.init), (0.3...6).contains(lease) else { exit(2) }
    let simulation = argument("--simulation")
    guard simulation != nil ? geteuid() != 0 : (geteuid() == 0 && lease == LidPaths.lease) else { exit(2) }
    runLidWatchdog(files: LidServiceFiles(simulation: simulation), owner: owner, lease: lease)
}
// A power helper never opens a GUI, installs itself, or accepts other commands.
exit(2)
