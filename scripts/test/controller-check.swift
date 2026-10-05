import Foundation
import Combine
struct DeviceIDs { var vendor: UInt16 = 0x1af4; var product: UInt16 = 0x0010 }
final class InputDevice { var ids = DeviceIDs(); var name = "steamac game controller"; func send(_ e: [(UInt16,UInt16,Int32)]) {} }
final class LauncherSettings {
 @Published var controllerID = ""
 @Published var swapABXY = false
 @Published var stickDeadzone = 10
}
func log(_ s: String) { print(s) }
import Foundation
import GameController
let controller = GCController.withExtendedGamepad()
let pad = controller.extendedGamepad!
pad.buttonX.setValue(1)
var state = GamepadBridge.read(pad, swapABXY: false, deadzone: 0)
precondition(state.buttons[BTN.WEST] == true)
precondition(state.buttons[BTN.NORTH] == false)
pad.buttonX.setValue(0)
pad.buttonY.setValue(1)
state = GamepadBridge.read(pad, swapABXY: false, deadzone: 0)
precondition(state.buttons[BTN.NORTH] == true)
precondition(state.buttons[BTN.WEST] == false)
let unknown = GamepadBridge.identity(of: controller)
precondition(unknown.vendor == 0x1af4 && unknown.product == 0x0010)
let absent = GamepadBridge.identity(of: nil)
precondition(absent.name == "steamac game controller")
let (x, y) = GamepadBridge.deadzoned(0.05, 0.05, 0.1)
precondition(x == 0 && y == 0)
print("PASS controller button orientation, generic identity, and deadzone")
