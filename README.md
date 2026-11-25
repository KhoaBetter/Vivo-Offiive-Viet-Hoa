# Bộ công cụ vivo Office / vivo PC Suite — Bản Việt Hóa (v7.0.6)

Dự án giúp **Việt hóa giao diện vivo Office / vivo PC Suite (phiên bản nội địa Trung Quốc)** bằng cách giải nén, vá trực tiếp mã nguồn bên trong gói `app.asar` và đóng gói lại chuẩn xác kèm mã kiểm tra toàn vẹn (SHA-256), đồng thời giữ nguyên toàn bộ tính năng và khả năng kết nối thiết bị nội địa.

---

## Tại sao các cách Việt hóa thông thường không hoạt động?

Trên các bản vivo PC Suite phát hành cho thị trường Trung Quốc (`IS_EXPORT = false`):
- **Không thể đổi tên file ngôn ngữ:** Các gói ngôn ngữ được đóng gói bằng Webpack (`locales-vi_VN.js` và `locales-zh_CN.js`) với Chunk ID và Module ID khác nhau, đổi tên hoặc chép đè trực tiếp sẽ làm lỗi nạp giao diện.
- **Bị ép ngôn ngữ cứng trong mã nguồn:** Tiến trình chính (`main.js`), cửa sổ chính (`renderer.js`) và các cửa sổ phụ (`child-window.js`, `module-share-preview.js`) liên tục ghi đè `currentLanguage = "zh_CN"` và `vLang = "vzh_rCN"` khi khởi động.
- **Nhiều thành phần bỏ qua từ điển dịch:** Các module như thanh công cụ ghi chú, cửa sổ kết nối, trình soạn thảo... kiểm tra cờ `IS_EXPORT`; nếu là bản nội địa sẽ hiển thị thẳng chữ Trung Quốc hardcode thay vì đọc từ điển `$t(...)`.
- **Không nên bật thẳng `IS_EXPORT = true` trong `build-config.json`:** Việc đổi cờ này sẽ khiến ứng dụng chuyển sang cụm máy chủ quốc tế (`vivoglobal.com`), ẩn một số tính năng nội địa và **chặn không cho kết nối các máy vivo/iQOO chạy OriginOS ROM nội địa** (`ro.vivo.product.overseas != "yes"`).

---

## Điểm nổi bật của bản Việt hóa này

- **Kích hoạt gói Tiếng Việt chính chủ có sẵn** của vivo (`vi_VN`, `framework.json`, TinyMCE `vi_VN`) trên toàn bộ cửa sổ chính, cửa sổ phụ, menu khay hệ thống (tray) và webview.
- **Đồng bộ `vLang = "vvi"`** giúp module điều khiển từ xa (`vivoControl`) tự động chuyển sang giao diện Tiếng Việt.
- **Mở khóa các nhánh UI bị chặn bởi `IS_EXPORT`** để hiển thị bản dịch chuẩn thay vì rơi về chữ Trung.
- **Việt hóa bổ sung các chuỗi chữ Trung bị viết cứng (hardcode)** ở menu Cài đặt, thanh điều hướng (*Ghi chú, Lịch, Album, Ghi âm, Dịch vụ đám mây, Trợ lý AI...*) và tiêu đề cửa sổ.
- **Giữ nguyên 100% tương thích bản nội địa:** Vẫn đăng nhập tài khoản vivo CN, đồng bộ dữ liệu, kết nối máy chạy OriginOS nội địa và dùng đầy đủ các tính năng độc quyền bình thường.
- **An toàn tuyệt đối:** Tự động giữ bản sao lưu `app.asar.bak` để khôi phục về nguyên gốc bất cứ lúc nào.

---

## Hướng dẫn sử dụng

1. Tắt hoàn toàn **vivo Office / PC Suite** (kiểm tra trong Task Manager đảm bảo không còn `pcsuite.exe` hoặc `vivocontrol.exe` chạy ngầm).
2. Tải script patch (hoặc file `app.asar` đã đóng gói sẵn trong mục **Releases** rồi giải nén ra).
3. Mở **PowerShell** và chạy script patch (hoặc chép file `app.asar` vào thư mục `<Thư mục cài đặt>\pcsuite\resources\`).
4. Mở lại **vivo PC Suite** và sử dụng giao diện Tiếng Việt.

---

## Khôi phục về bản gốc

Nếu muốn quay lại giao diện tiếng Trung nguyên bản:
1. Tắt hoàn toàn vivo PC Suite.
2. Xóa file `app.asar` hiện tại trong thư mục `resources\`.
3. Đổi tên file `app.asar.bak` thành `app.asar`.

---

## Lưu ý

- Đã kiểm thử hoạt động ổn định trên **vivo PC Suite v7.0.6 (Windows 64-bit)**.
- Khi ứng dụng tự động cập nhật lên phiên bản mới, file `app.asar` có thể bị ghi đè — chỉ cần chạy lại bản patch là được.
