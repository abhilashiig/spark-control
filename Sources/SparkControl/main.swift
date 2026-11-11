import Foundation

// When ssh runs us as its password helper (SSH_ASKPASS), hand over the one line of
// password it gave us on stdin and exit. The password only ever lives in that pipe.
if ProcessInfo.processInfo.environment["SPARK_CONTROL_ASKPASS"] == "1" {
    var line = Data()
    while let byte = try? FileHandle.standardInput.read(upToCount: 1), let b = byte.first, b != 10 {
        line.append(b)
    }
    FileHandle.standardOutput.write(line + Data([10]))
    exit(line.isEmpty ? 1 : 0)
}

SparkControlApp.main()
