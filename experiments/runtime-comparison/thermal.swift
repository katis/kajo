// Prints the process's view of the machine's thermal state, as the shells'
// telemetry logs it (ProcessInfo.thermalState): nominal, fair, serious or
// critical. bench.sh compiles it once and runs it at each run's start.
import Foundation

switch ProcessInfo.processInfo.thermalState {
case .nominal: print("nominal")
case .fair: print("fair")
case .serious: print("serious")
case .critical: print("critical")
@unknown default: print("unknown")
}
