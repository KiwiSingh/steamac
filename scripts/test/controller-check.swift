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

// Decode the production bridge through Steam's observed PS5 SDL mapping.
// Linux joydev orders these advertised key/axis codes numerically.
let buttons = GamepadBridge.buttons(for: .playstation).sorted()
let axes = GamepadBridge.axisCodes.sorted()
func ps5State() -> GamepadBridge.PadState {
    GamepadBridge.read(pad, swapABXY: false, deadzone: 0, layout: .playstation)
}
for button in [pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY] { button.setValue(0) }
for (physical, index) in [(pad.buttonX, 0), (pad.buttonA, 1), (pad.buttonB, 2), (pad.buttonY, 3)] {
    physical.setValue(1)
    let s = ps5State()
    precondition(s.buttons[buttons[index]] == true)
    precondition(s.buttons.values.filter { $0 }.count == 1)
    physical.setValue(0)
}
pad.rightThumbstick.xAxis.setValue(1)
pad.rightThumbstick.yAxis.setValue(1)
var ps5 = ps5State()
precondition(ps5.axes[axes[2]] == 32767 && ps5.axes[axes[5]] == -32767)
precondition(ps5.axes[axes[3]] == 0 && ps5.axes[axes[4]] == 0)
pad.rightThumbstick.xAxis.setValue(0)
pad.rightThumbstick.yAxis.setValue(0)
pad.leftTrigger.setValue(1)
pad.rightTrigger.setValue(1)
ps5 = ps5State()
precondition(ps5.axes[axes[3]] == 255 && ps5.axes[axes[4]] == 255)
precondition(ps5.axes[axes[2]] == 0 && ps5.axes[axes[5]] == 0)
precondition(ps5.buttons[buttons[6]] == true && ps5.buttons[buttons[7]] == true)
pad.buttonOptions?.setValue(1)
pad.buttonMenu.setValue(1)
ps5 = ps5State()
precondition(ps5.buttons[buttons[8]] == true && ps5.buttons[buttons[9]] == true)
print("PASS PS5 SDL face buttons, trigger slots, stick/trigger isolation and menu indices")

pad.leftTrigger.setValue(0)
pad.rightTrigger.setValue(0)
pad.buttonOptions?.setValue(0)
pad.buttonMenu.setValue(0)
for (physical, index) in [(pad.leftThumbstickButton, 10), (pad.rightThumbstickButton, 11), (pad.buttonHome, 12)] {
    if let physical {
        physical.setValue(1)
        precondition(ps5State().buttons[buttons[index]] == true)
        physical.setValue(0)
    }
}
print("PASS PS5 stick-click and PS-button indices")
