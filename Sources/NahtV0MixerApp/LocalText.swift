import Foundation

/// Original, small bilingual interface vocabulary. Unknown diagnostic messages are
/// left intact so failures from the audio subsystem remain useful.
enum LocalText {
    static func text(_ english: String, languageCode: String) -> String {
        languageCode == "vi" ? (vietnamese[english] ?? english) : english
    }

    private static let vietnamese: [String: String] = [
        "Mixer": "Bộ trộn âm lượng",
        "Sound": "Âm thanh",
        "Requires system audio access.": "Cần quyền truy cập âm thanh hệ thống.",
        "Settings": "Cài đặt",
        "Back": "Quay lại",
        "Refresh": "Làm mới",
        "Quit": "Thoát",
        "Output": "Đầu ra",
        "No output device": "Không có thiết bị đầu ra",
        "System volume": "Âm lượng tổng",
        "Volume unavailable on this device": "Thiết bị không hỗ trợ chỉnh âm lượng",
        "Mute unavailable on this device": "Thiết bị không hỗ trợ tắt tiếng",
        "Mute": "Tắt tiếng",
        "Unmute": "Bật tiếng",
        "Per-app mixer": "Âm lượng từng ứng dụng",
        "Enable to adjust each app. macOS may request system audio recording access.": "Bật để chỉnh từng ứng dụng. macOS có thể yêu cầu quyền ghi âm thanh hệ thống.",
        "Applications": "Ứng dụng",
        "No apps are playing audio": "Chưa có ứng dụng phát âm thanh",
        "Play audio in an app to see it here.": "Phát âm thanh trong ứng dụng để hiện tại đây.",
        "Mixer is off": "Bộ trộn đang tắt",
        "Playing": "Đang phát",
        "Idle": "Đang chờ",
        "Adjusting": "Đang điều chỉnh",
        "Controlled": "Đang áp dụng",
        "Audio format changed. Reset this app or toggle the mixer to retry.": "Định dạng âm thanh đã đổi. Đặt lại ứng dụng hoặc tắt/bật bộ trộn để thử lại.",
        "No audio frames arrived. Check system audio access and toggle the mixer to retry.": "Chưa nhận được âm thanh. Kiểm tra quyền âm thanh hệ thống rồi tắt/bật bộ trộn để thử lại.",
        "This app is playing on another output device.": "Ứng dụng đang phát trên thiết bị đầu ra khác.",
        "Reset volume": "Đặt lại âm lượng",
        "Language": "Ngôn ngữ",
        "System": "Theo hệ thống",
        "English": "English",
        "Vietnamese": "Tiếng Việt",
        "Appearance": "Giao diện",
        "Light": "Sáng",
        "Dark": "Tối",
        "Launch at login": "Mở khi đăng nhập",
        "Waiting for approval in System Settings.": "Đang chờ cho phép trong Cài đặt hệ thống.",
        "Open Login Items": "Mở mục đăng nhập",
        "Launch at login is unavailable. Move the app to Applications first.": "Chưa thể mở khi đăng nhập. Hãy chuyển ứng dụng vào Applications.",
        "Close this panel to keep the mixer running.": "Đóng bảng này để bộ trộn tiếp tục chạy.",
        "Version": "Phiên bản",
        "Could not start NahtV0Mixer": "Không thể mở NahtV0Mixer",
        "Could not show the running mixer. Open it from its menu bar icon.": "Không thể hiện bộ trộn đang chạy. Hãy mở từ biểu tượng trên thanh menu.",
        "OK": "OK"
    ]
}
