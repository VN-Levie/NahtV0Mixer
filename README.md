# NahtV0Mixer

Mixer âm lượng cho macOS, viết bằng Swift và SwiftUI. Chỉnh âm lượng từng ứng dụng ngay trên menu bar, theo cách quen thuộc của Volume Mixer trên Windows.

**Đang phát triển — phiên bản 0.1.0.** Chưa có bản phát hành công khai.

## Sử dụng

Yêu cầu **macOS 14.4 trở lên**. Mở app, nhấn icon trên menu bar để xem ứng dụng đang phát âm thanh và chọn thiết bị đầu ra.

- Bật mixer khi muốn điều chỉnh âm lượng riêng từng ứng dụng.
- Cấp quyền **ghi âm thanh hệ thống** nếu macOS yêu cầu. App cần quyền này để xử lý âm thanh cục bộ, không lưu bản ghi hoặc gửi âm thanh lên mạng.
- Kéo thanh âm lượng hoặc bật/tắt tiếng của từng ứng dụng. Tắt mixer để trả âm thanh về đường phát bình thường.
- Mức âm lượng được nhớ theo ứng dụng; mỗi lần mở app bắt đầu ở trạng thái tắt mixer. Bật lại khi muốn áp dụng các mức đã lưu.
- Chọn tiếng Việt/English, giao diện sáng/tối và khởi động cùng macOS trong Cài đặt. Mở app nhiều lần vẫn dùng chung một icon menu bar.
- Thoát app trước khi cập nhật hoặc thay bản cài đặt.

Một số thiết bị đầu ra không hỗ trợ chỉnh âm lượng tổng bằng phần mềm. Bản đầu xử lý mono/stereo Float32 trên đầu ra hệ thống; không định tuyến riêng mỗi ứng dụng sang một thiết bị khác. Bluetooth, HDMI và đổi thiết bị trong lúc phát cần được kiểm thử riêng. Nguồn âm thanh từ một số tiến trình phụ có thể hiện thành hàng riêng.

## Biên dịch

Cần Xcode Command Line Tools với Swift 6 trở lên.

```sh
swift test
./scripts/build-app.sh
open build/NahtV0Mixer.app
```

Dùng `./scripts/build-app.sh --universal` để tạo app cho cả Apple Silicon và Intel. `./scripts/package-release.sh` tạo ZIP kèm checksum; `./scripts/install-local.sh` cài vào Applications sau khi đã thoát app. Chi tiết kiểm thử và ký mã nằm trong [hướng dẫn phát triển](docs/development.md).

## Credit và giấy phép

Cảm ơn các dự án và tài liệu trong [CREDITS.md](CREDITS.md). NahtV0Mixer triển khai riêng, tham khảo nguyên lý và trải nghiệm sử dụng, không chép mã nguồn hoặc hình ảnh từ các dự án đó.

[MIT License](LICENSE).
