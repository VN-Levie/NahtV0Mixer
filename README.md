# NahtV0Mixer

Điều chỉnh âm lượng từng ứng dụng ngay trên menu bar macOS, kèm widget trên desktop.

**Bản thử nghiệm 0.2.0.** [Tải bản mới nhất](https://github.com/VN-Levie/NahtV0Mixer/releases/latest).

## Cài đặt

- macOS **14.4 trở lên**. Gói Universal gồm Apple Silicon và Intel.
- Thoát NahtV0Mixer đang chạy, giải nén ZIP rồi kéo **NahtV0Mixer.app** vào **Applications**.
- Mở bản trong Applications. Khi cập nhật từ bản cũ, kiểm tra lại quyền âm thanh và **Khởi động cùng macOS** nếu cần.
- Bản có widget được ký **Apple Development**, chưa có Developer ID/notarization. Nếu macOS chặn, dùng **System Settings → Privacy & Security → Open Anyway** theo [hướng dẫn của Apple](https://support.apple.com/102445). Máy có chính sách quản lý có thể không cho phép chạy bản này.

## Sử dụng

1. Bấm biểu tượng NahtV0Mixer trên menu bar và phát âm thanh trong ứng dụng cần chỉnh.
2. Bật **Per-app mixer**, cấp quyền âm thanh hệ thống khi macOS yêu cầu, rồi chỉnh thanh âm lượng hoặc nút mute của ứng dụng.
3. Dùng **Reset** để trả ứng dụng về âm lượng mặc định. Tắt mixer để ngừng xử lý âm thanh từng app.

Âm lượng từng app và trạng thái bật/tắt mixer được nhớ qua lần mở sau. Lần cài đầu tiên, mixer mặc định tắt. Ứng dụng xử lý âm thanh tại máy, không lưu bản ghi hoặc tải âm thanh lên mạng.

Menu **Output** chọn thiết bị phát. Settings có ngôn ngữ Việt/Anh, giao diện sáng/tối/theo hệ thống và khởi động cùng macOS.

## Widget desktop

Mở NahtV0Mixer, bấm phải desktop → **Edit Widgets…** → chọn **NahtV0Mixer** cỡ vừa hoặc lớn.

- Bấm phần trăm để chuyển lần lượt **25% → 50% → 75% → 100%**.
- Bấm loa để mute/unmute; **Mixer On/Off** bật/tắt xử lý từng app.
- Giữ app chạy. Dùng **Refresh** khi thông tin hiển thị cũ; macOS quyết định thời điểm cập nhật widget.

## Giới hạn

Đây là bản thử nghiệm. Đã kiểm tra trên Apple Silicon; chưa xác nhận hoạt động trên máy Intel, Bluetooth, HDMI hoặc thiết bị hội thoại đa kênh. Điều chỉnh từng app cần đầu ra mono/stereo Float32 phù hợp. Một số tiến trình phụ có thể hiện thành mục riêng.

## Phát triển

Xem [hướng dẫn build, ký và kiểm thử](docs/development.md). Build SwiftPM thông thường không có widget; bản phát hành có widget dùng project Xcode.

## Ghi nhận và giấy phép

Các tài liệu và dự án tham khảo được ghi trong [CREDITS.md](CREDITS.md). Code và artwork không sao chép từ những dự án đó.

Biểu tượng loa chữ N được tạo riêng cho NahtSoft bằng ImageGen và được chủ dự án chọn. [Nguồn artwork](Resources/Brand/README.md).

[Giấy phép MIT](LICENSE).
