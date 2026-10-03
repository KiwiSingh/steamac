import Carbon.HIToolbox

/// macOS virtual key codes (kVK_*, positional, US-ANSI names) -> Linux evdev KEY_*.
/// Positional mapping: the guest applies its own keyboard layout.
enum Keymap {
    /// ISO keyboards report the key left of "1" as kVK_ISO_Section and the extra key next to
    /// left shift as kVK_ANSI_Grave; PC/evdev has them as KEY_GRAVE and KEY_102ND.
    static let isISO: Bool = KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO

    static func linuxKey(_ keyCode: UInt16) -> UInt16? {
        switch Int(keyCode) {
        case kVK_ISO_Section: return isISO ? KEY.GRAVE : KEY._102ND
        case kVK_ANSI_Grave: return isISO ? KEY._102ND : KEY.GRAVE
        default: return table[keyCode]
        }
    }

    /// Every code the keyboard device can emit (advertised in EV_KEY bits).
    static var allCodes: [UInt16] { Array(Set(table.values).union([KEY.GRAVE, KEY._102ND])) }

    static let table: [UInt16: UInt16] = {
        let pairs: [(Int, UInt16)] = [
            (kVK_ANSI_A, KEY.A), (kVK_ANSI_B, KEY.B), (kVK_ANSI_C, KEY.C), (kVK_ANSI_D, KEY.D),
            (kVK_ANSI_E, KEY.E), (kVK_ANSI_F, KEY.F), (kVK_ANSI_G, KEY.G), (kVK_ANSI_H, KEY.H),
            (kVK_ANSI_I, KEY.I), (kVK_ANSI_J, KEY.J), (kVK_ANSI_K, KEY.K), (kVK_ANSI_L, KEY.L),
            (kVK_ANSI_M, KEY.M), (kVK_ANSI_N, KEY.N), (kVK_ANSI_O, KEY.O), (kVK_ANSI_P, KEY.P),
            (kVK_ANSI_Q, KEY.Q), (kVK_ANSI_R, KEY.R), (kVK_ANSI_S, KEY.S), (kVK_ANSI_T, KEY.T),
            (kVK_ANSI_U, KEY.U), (kVK_ANSI_V, KEY.V), (kVK_ANSI_W, KEY.W), (kVK_ANSI_X, KEY.X),
            (kVK_ANSI_Y, KEY.Y), (kVK_ANSI_Z, KEY.Z),
            (kVK_ANSI_1, KEY._1), (kVK_ANSI_2, KEY._2), (kVK_ANSI_3, KEY._3), (kVK_ANSI_4, KEY._4),
            (kVK_ANSI_5, KEY._5), (kVK_ANSI_6, KEY._6), (kVK_ANSI_7, KEY._7), (kVK_ANSI_8, KEY._8),
            (kVK_ANSI_9, KEY._9), (kVK_ANSI_0, KEY._0),
            (kVK_ANSI_Minus, KEY.MINUS), (kVK_ANSI_Equal, KEY.EQUAL),
            (kVK_ANSI_LeftBracket, KEY.LEFTBRACE), (kVK_ANSI_RightBracket, KEY.RIGHTBRACE),
            (kVK_ANSI_Backslash, KEY.BACKSLASH), (kVK_ANSI_Semicolon, KEY.SEMICOLON),
            (kVK_ANSI_Quote, KEY.APOSTROPHE), (kVK_ANSI_Comma, KEY.COMMA),
            (kVK_ANSI_Period, KEY.DOT), (kVK_ANSI_Slash, KEY.SLASH),
            (kVK_Return, KEY.ENTER), (kVK_Tab, KEY.TAB), (kVK_Space, KEY.SPACE),
            (kVK_Delete, KEY.BACKSPACE), (kVK_ForwardDelete, KEY.DELETE), (kVK_Escape, KEY.ESC),
            (kVK_Command, KEY.LEFTMETA), (kVK_RightCommand, KEY.RIGHTMETA),
            (kVK_Shift, KEY.LEFTSHIFT), (kVK_RightShift, KEY.RIGHTSHIFT),
            (kVK_Option, KEY.LEFTALT), (kVK_RightOption, KEY.RIGHTALT),
            (kVK_Control, KEY.LEFTCTRL), (kVK_RightControl, KEY.RIGHTCTRL),
            (kVK_CapsLock, KEY.CAPSLOCK),
            (kVK_LeftArrow, KEY.LEFT), (kVK_RightArrow, KEY.RIGHT),
            (kVK_UpArrow, KEY.UP), (kVK_DownArrow, KEY.DOWN),
            (kVK_Home, KEY.HOME), (kVK_End, KEY.END), (kVK_PageUp, KEY.PAGEUP), (kVK_PageDown, KEY.PAGEDOWN),
            (kVK_Help, KEY.INSERT),
            (kVK_F1, KEY.F1), (kVK_F2, KEY.F2), (kVK_F3, KEY.F3), (kVK_F4, KEY.F4),
            (kVK_F5, KEY.F5), (kVK_F6, KEY.F6), (kVK_F7, KEY.F7), (kVK_F8, KEY.F8),
            (kVK_F9, KEY.F9), (kVK_F10, KEY.F10), (kVK_F11, KEY.F11), (kVK_F12, KEY.F12),
            (kVK_F13, KEY.F13), (kVK_F14, KEY.F14), (kVK_F15, KEY.F15), (kVK_F16, KEY.F16),
            (kVK_F17, KEY.F17), (kVK_F18, KEY.F18), (kVK_F19, KEY.F19), (kVK_F20, KEY.F20),
            (kVK_ANSI_Keypad0, KEY.KP0), (kVK_ANSI_Keypad1, KEY.KP1), (kVK_ANSI_Keypad2, KEY.KP2),
            (kVK_ANSI_Keypad3, KEY.KP3), (kVK_ANSI_Keypad4, KEY.KP4), (kVK_ANSI_Keypad5, KEY.KP5),
            (kVK_ANSI_Keypad6, KEY.KP6), (kVK_ANSI_Keypad7, KEY.KP7), (kVK_ANSI_Keypad8, KEY.KP8),
            (kVK_ANSI_Keypad9, KEY.KP9), (kVK_ANSI_KeypadDecimal, KEY.KPDOT),
            (kVK_ANSI_KeypadMultiply, KEY.KPASTERISK), (kVK_ANSI_KeypadPlus, KEY.KPPLUS),
            (kVK_ANSI_KeypadMinus, KEY.KPMINUS), (kVK_ANSI_KeypadDivide, KEY.KPSLASH),
            (kVK_ANSI_KeypadEnter, KEY.KPENTER), (kVK_ANSI_KeypadEquals, KEY.KPEQUAL),
            (kVK_ANSI_KeypadClear, KEY.NUMLOCK),
            (kVK_VolumeUp, KEY.VOLUMEUP), (kVK_VolumeDown, KEY.VOLUMEDOWN), (kVK_Mute, KEY.MUTE),
            (kVK_JIS_Yen, KEY.YEN), (kVK_JIS_Underscore, KEY.RO), (kVK_JIS_KeypadComma, KEY.KPJPCOMMA),
            (kVK_JIS_Eisu, KEY.HANJA), (kVK_JIS_Kana, KEY.HANGEUL),
            (kVK_ContextualMenu, KEY.COMPOSE),
        ]
        var t: [UInt16: UInt16] = [:]
        for (mac, linux) in pairs { t[UInt16(mac)] = linux }
        return t
    }()

    /// Device-dependent modifier bits (IOLLEvent.h NX_DEVICE*KEYMASK) per modifier keycode.
    static func modifierMask(_ keyCode: UInt16) -> UInt? {
        switch Int(keyCode) {
        case kVK_Control: return 0x0001
        case kVK_Shift: return 0x0002
        case kVK_RightShift: return 0x0004
        case kVK_Command: return 0x0008
        case kVK_RightCommand: return 0x0010
        case kVK_Option: return 0x0020
        case kVK_RightOption: return 0x0040
        case kVK_RightControl: return 0x2000
        default: return nil
        }
    }
}
