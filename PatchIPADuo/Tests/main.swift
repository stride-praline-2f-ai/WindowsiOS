import Foundation

do {
    let input = URL(fileURLWithPath: CommandLine.arguments[1])
    let mode = CommandLine.arguments[2]
    let inspection = try IPAPatcher.run(input, display: mode, enablePhone: true, inspect: true)
    guard inspection.output == nil, inspection.report.contains("18.0") else { exit(2) }
    let result = try IPAPatcher.run(input, display: mode, enablePhone: true, inspect: false)
    print(result.output!.path)
} catch {
    FileHandle.standardError.write(Data(error.localizedDescription.utf8))
    exit(1)
}
