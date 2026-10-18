# Phát triển NahtV0Mixer

Ứng dụng dùng SwiftPM, SwiftUI/AppKit và Core Audio Process Taps công khai. Không cần driver âm thanh riêng hoặc dependency bên ngoài. Mục tiêu tối thiểu là macOS 14.4.

## Build và ký mã

```sh
swift test
./scripts/build-app.sh --native
./scripts/build-app.sh --universal
```

Build mặc định nằm ở `build/NahtV0Mixer.app`. Chỉ chạy một lệnh build tại một thời điểm. Hai biến môi trường được hỗ trợ:

- `NAHTV0MIXER_APP_OUTPUT`: đường dẫn `.app` đầu ra khác.
- `NAHTV0MIXER_SIGN_IDENTITY`: identity của `codesign`; mặc định `-` (ad-hoc).

Build đóng gói artwork đã duyệt qua `scripts/make-icon.swift` và Icon Composer, loại debug map chứa đường dẫn cục bộ rồi ký app. Script từ chối thay thế bundle đang chạy và không khởi chạy ứng dụng. Ad-hoc signing không tương đương Developer ID hoặc notarization; macOS có thể yêu cầu cấp quyền lại sau khi binary thay đổi. Không tự xoá quarantine, sửa TCC hoặc dùng private API để né hộp thoại quyền.

## Kiểm thử

Giữ các lớp bằng chứng tách biệt:

1. `swift test`: logic gom ứng dụng, trạng thái, gain/DSP và vòng đời route với dữ liệu xác định.
2. Build release: Swift/C, metadata bundle, minimum macOS, architectures và chữ ký.
3. Fixture âm thanh cục bộ: tạo nguồn tín hiệu biết trước, kiểm tra âm lượng và dữ liệu đầu ra khi người dùng đã cho phép chạy mixer.
4. Thử trên thiết bị thật: âm thanh nghe được, không phát đôi/mất tiếng, đổi thiết bị, app thoát, sleep/wake và khôi phục sau lỗi.

Bắt đầu bằng loa tích hợp ở chế độ stereo. Chỉ báo tương thích Bluetooth, HDMI, thiết bị đa kênh, máy Intel hoặc độ trễ khi đã kiểm tra trực tiếp. Unit test không chứng minh quyền âm thanh đã được cấp hay audio đang phát ra loa.

Mở app chỉ đọc danh sách thiết bị/ứng dụng. Bật mixer là hành động riêng; thay đổi per-app đầu tiên có thể khiến macOS yêu cầu quyền ghi âm thanh hệ thống. Trạng thái quyền chưa xác định phải được xử lý như chưa biết, không tự suy ra đã được cấp. Nếu bị từ chối, người dùng kiểm tra **System Settings → Privacy & Security → Screen & System Audio Recording** (tên mục có thể khác theo phiên bản macOS).

## Đóng gói và cài cục bộ

```sh
./scripts/package-release.sh
# Hoặc bắt buộc đúng kiểu gói:
./scripts/package-release.sh --universal

# Chỉ khi muốn cài và đã thoát ứng dụng:
./scripts/install-local.sh
```

Gói ZIP và manifest SHA-256 nằm trong `dist/`. Script đối chiếu version/build với `Resources/Info.plist`, xác minh bundle ID, executable, kiến trúc, minimum macOS, đường dẫn cục bộ và chữ ký. Sau đóng gói, nó giải nén vào thư mục tạm và kiểm tra lại app. Bản universal chứa cả arm64 và x86_64; điều đó không chứng minh đã chạy thử trên Intel.

Cài đặt dùng `/Applications/NahtV0Mixer.app` và từ chối khi bản nguồn hoặc đích đang chạy. Script không thoát app, không mở app và không đổi cài đặt đăng nhập. Bật khởi động cùng macOS, nếu được hỗ trợ trong UI, luôn là lựa chọn chủ động của người dùng.

## GitHub và tài liệu

Repository giữ **private** cho đến khi có yêu cầu khác. Push source không đồng nghĩa với phát hành. Khi được yêu cầu release, cập nhật version/build cùng nhau, kiểm thử và tạo gói đã kiểm tra trước khi tải lên; kiểm tra lại bản tải về cùng checksum sau khi phát hành.

Các bản ghi kiểm thử phải nêu rõ môi trường và phạm vi, không lưu âm thanh hay nội dung riêng của người dùng. README/release notes chỉ chứa thông tin cần cho sử dụng; ghi nguồn học hỏi trong `CREDITS.md` cùng commit liên quan. Không chép code từ các nguồn tham khảo.

## Kiểm tra đã thực hiện (2026-10-18)

- Discovery `--diagnose` đọc thiết bị và ứng dụng từ HAL, không tạo tap. Kiểm tra trên macOS 27.0.1, Apple Silicon, loa MacBook Pro 48 kHz.
- Fixture `build/NahtV0Mixer.app/Contents/MacOS/NahtV0Mixer --audio-check` chỉ chạy khi được yêu cầu rõ ràng. Nó tạo WAV tiếng sine nhỏ, chạy tiến trình `afplay` riêng, định vị đúng PID đó, kiểm tra gain/mute rồi giải phóng route và kết thúc tiến trình mẫu. Không thay đổi âm lượng tổng hoặc đầu ra mặc định.
- Kết quả fixture: input/unity peak `0.0198103`; gain 25% output peak `0.00495864`; mute peak `0`; `91136` frame đã xử lý. Đầu ra mặc định không đổi. Đây là phép đo buffer trong callback thực của HAL, không phải bản thu loopback vật lý hoặc phép đo độ trễ.
- Loa máy báo duy nhất một stream tap bắt đầu ở kênh HAL 7 dù callback chỉ có một buffer stereo. Chỉ trường hợp đã xác minh không có hardware input, một tap/stream và format khớp hoàn toàn mới được chuẩn hóa về kênh callback 1. Duplex vẫn kiểm tra nghiêm ngặt.
- UI mở ở trạng thái mixer tắt, đọc đúng thiết bị/âm lượng hiện tại. Mute/volume từng ứng dụng, Bluetooth, HDMI, conferencing và Intel hardware vẫn cần các ca tương thích riêng; không suy ra hỗ trợ mọi thiết bị từ fixture loa máy.
