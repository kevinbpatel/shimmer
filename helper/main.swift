import Foundation
import os.log

// Proves the signed binary, with its hardened-process entitlements, can launch.
// Runs before the root check and touches no interface; the build calls it after signing.
if CommandLine.arguments.dropFirst().elementsEqual(["--check-launch"]) { exit(0) }

let log = OSLog(subsystem: "io.ugfugl.glimmer.helper", category: "main")
os_log("Glimmer helper starting (pid %d)", log: log, type: .info, getpid())

if getuid() != 0 {
    os_log("Helper must run as root", log: log, type: .error)
    exit(1)
}

// Who we are, read now while the file on disk is still the one launchd started;
// an install can replace it under a running helper. Without it, refuse every client.
let identity = HelperClientRequirement.launchIdentity()
if let identity {
    os_log("Helper clients: %{public}@", log: log, type: .info,
           identity.teamID.map { "team \($0)" } ?? "the enclosing ad hoc app")
} else {
    os_log("Could not read the helper's own signature; refusing all clients", log: log, type: .error)
}

let suppressor = AWDLSuppressor()
suppressor.start()

let listener = NSXPCListener(machServiceName: GlimmerHelperMachServiceName)
let service = HelperService(suppressor: suppressor) {
    identity.flatMap(HelperClientRequirement.requirement(for:))
}
listener.delegate = service
listener.resume()

os_log("Glimmer helper listening on %{public}@", log: log, type: .info, GlimmerHelperMachServiceName)

RunLoop.main.run()
