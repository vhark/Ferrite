import Foundation
import FerriteCore

let powerSource = SystemPowerSource()
let controller = SleepOverrideController(
    runner: PmsetCommandRunner(),
    powerSource: powerSource,
    ownership: FileSleepOverrideOwnershipStore())
let daemon = KeepAwakeHelperDaemon(
    controller: controller,
    powerSource: powerSource,
    validator: HelperMessageValidator())
daemon.start()
RunLoop.main.run()
