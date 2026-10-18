# Credit

NahtV0Mixer được triển khai riêng bằng Swift/SwiftUI và AppKit, với phần xử lý âm thanh C nhỏ chạy qua Core Audio. Các nguồn dưới đây giúp định hình kiến trúc, cách kiểm thử và trải nghiệm sử dụng; không có mã nguồn, thư viện nhị phân hoặc hình ảnh nào được chuyển từ các dự án bên ngoài này vào ứng dụng.

| Nguồn tham khảo | Nội dung học hỏi |
| --- | --- |
| Apple — [Core Audio Taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps), [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra) và [NSPopover](https://developer.apple.com/documentation/appkit/nspopover) | API công khai để xử lý âm thanh của tiến trình, quyền truy cập âm thanh hệ thống, giao diện menu bar và popover co theo nội dung với vật liệu macOS. |
| [MacMixer](https://github.com/burghr/MacMixer) | Cấu trúc process tap, aggregate device riêng và thứ tự dừng, giải phóng đường âm thanh. |
| [AudioCap](https://github.com/insidegui/AudioCap) | Vòng đời tap, định dạng âm thanh và tình huống thiếu quyền. NahtV0Mixer không sử dụng private TCC API. |
| [FineTune](https://github.com/ronitsingh10/FineTune) | Gom tiến trình phụ về một ứng dụng, tách trạng thái mong muốn khỏi trạng thái thiết bị và cách trình bày mixer. |
| [per-app-audio](https://github.com/mavericksxx/per-app-audio) | Một chủ sở hữu cho mỗi đường âm thanh, thay đổi gain mượt và phục hồi khi đường âm thanh lỗi. |
| [EarTrumpet](https://github.com/File-New-Project/EarTrumpet) | Trải nghiệm mixer trên Windows: mỗi ứng dụng một hàng, chỉnh âm lượng và tắt tiếng nhanh. |
| [Background Music](https://github.com/kyleneideck/BackgroundMusic) | Bối cảnh kiến trúc mixer trên macOS, yêu cầu xử lý thời gian thực và những tình huống cần kiểm thử khi thiết bị thay đổi. |

Mỗi nguồn giữ giấy phép và quyền tác giả riêng. FineTune và Background Music được tham khảo về nguyên lý; NahtV0Mixer không tích hợp mã GPL từ các dự án này. [Giấy phép EarTrumpet](https://github.com/File-New-Project/EarTrumpet/blob/master/LICENSE) có điều khoản bổ sung, không được coi là MIT chuẩn.

Quy trình build, ký ứng dụng, kiểm tra gói và cài đặt được tiếp nối từ hai ứng dụng cùng tác giả: [NahtKey](https://github.com/VN-Levie/NahtKey) và [NahtPaint](https://github.com/VN-Levie/NahtPaint). Bộ icon chữ N–loa với hai vòng sóng được tạo bằng ImageGen theo hướng nhận diện cùng nhóm NahtSoft, do chủ dự án lựa chọn và yêu cầu chỉnh sửa. Nguồn và ý tưởng prompt nằm trong [Resources/Brand](Resources/Brand/README.md); script Swift chỉ đóng gói kích thước icon.

Khi một nguồn mới ảnh hưởng trực tiếp đến thiết kế hoặc xử lý lỗi, cập nhật bảng này cùng thay đổi liên quan. Việc ghi credit không thay thế quyền sử dụng hoặc điều kiện giấy phép.
