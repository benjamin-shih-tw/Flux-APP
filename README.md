# Flux

Flux 是一款 iOS 飲水追蹤 App，主要用於估算不透明水瓶中的剩餘水量。SwiftUI App 會建立可重複使用的瓶身模型，透過裝置姿態引導使用者拍攝，再將俯視照片傳送至本機 FastAPI／OpenCV 後端進行水量估算。

## 目前進度

### 水瓶建模

- 使用一張引導式側面照片，不再需要多角度掃描。
- 使用 Vision 前景遮罩擷取瓶身，失敗時改用輪廓偵測。
- 已修正相機方向、浮點遮罩、影像座標與瓶身長寬比例問題。
- 使用 AR 偵測桌面或地面，再量測水瓶實際高度。
- 支援的 iPhone 會自動使用 LiDAR 場景深度與網格重建。
- 3D 水瓶預覽會保留照片中的真實高寬比例。
- 儲存前顯示幾何容量、可能誤差範圍與常見容量候選值。
- 可透過 Vision OCR 從照片辨識 `1500 ml`、`1.5 L` 等容量文字。
- 容量欄位沒有預設值，輸入容量也不會改變已量測的模型尺寸。

### 水量偵測

- 使用 IMU 檢查手機俯仰、翻滾與穩定度，引導使用者垂直俯拍。
- 後端從單張照片偵測瓶口與可見水面。
- 拍照後可由使用者調整瓶口與水面的圓框，再送出估算。
- 大尺寸照片會先縮小偵測，再將結果換算回原始影像座標。
- 使用校正後的瓶身剖面積分，估算剩餘水量與飲用量。
- API 回傳信心分數、估算方式、偵測半徑、水深與除錯疊圖。
- 後端保留聲學估算程式，但目前 App 的正式掃描流程不會錄音或上傳音訊。

### 飲水追蹤

- 使用 SwiftData 保存水瓶、設定與飲水紀錄。
- Dashboard 顯示可重複使用的 3D 水瓶與目前剩餘水量。
- 支援快速新增、自訂水量、Siri 捷徑與獨立 Apple Watch App 的飲水記錄傳送。
- 顯示七日趨勢、月份熱圖、連續達標、一致性與成就摘要；可匯出 CSV。
- 支援可設定間隔的本機提醒；健康資料與天氣整合仍需實機與權限驗證。
- 首次啟動提供新手教學，設定頁可重播並測試後台 `/health` 連線。

## 發佈狀態

- iOS 模擬器建置、iOS 單元測試與後端測試已在本機通過；這不代表實機水量精度已驗證。
- 相機水量掃描目前需要同區域網路中的 Mac 後端，尚未提供公開 HTTPS 服務。
- Apple Watch target 可獨立建置，但尚未嵌入 iOS App 的安裝包。
- 尚需正式 App Icon、繁體中文介面、簽署與 provisioning profile、隱私政策、商店素材，以及真實水量樣本的精度驗收。
- `Streak Freeze` 代幣與部分健康／天氣設定仍屬待完成的產品功能，不應當作已上線功能宣傳。

## 目前限制

- iPhone 與後端目前必須位於同一個區域網路。
- 單張側面照片假設水瓶大致為旋轉對稱形狀。
- 幾何容量仍是估算值；瓶壁厚度、保溫夾層、AR 端點誤差與瓶口預留空間都會影響實際標示容量，因此儲存前仍需由使用者確認。
- 直筒與反光不透明瓶的可見水面可能不足以穩定推算高度；信心分數不能視為實際毫升誤差保證。對異常結果應重拍或使用手動記錄。

## 專案結構

- `Flux/Flux/`：SwiftUI iOS App
- `Flux/FluxTests/`：iOS 建模與幾何測試
- `Flux/quick-oppenheimer/`：FastAPI／OpenCV 後端與測試

## 啟動後端

```bash
cd Flux/quick-oppenheimer
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

啟動後可開啟 `http://localhost:8000/health` 確認服務狀態。

## 執行 iOS App

1. 使用 Xcode 開啟 `Flux/Flux.xcodeproj`。
2. 選擇實體 iPhone；相機與 AR 水瓶量測無法在模擬器完整測試。
3. 執行 App 並進入 Settings。
4. 將後端網址設為 Mac 的區域網路位址，例如 `http://10.0.0.9:8000`。
5. 新增水瓶、拍攝側面輪廓、依序量測瓶底與瓶口、確認容量，再進行俯視水量掃描。

專案目前以 iOS 26.2 為部署目標，使用 Swift 5。

## API

- `GET /health`
- `POST /api/v2/estimate_water_volume`
- `POST /api/v1/calculate_water_volume`：舊版相容端點

完整請求與回應欄位請參考 [`Flux/quick-oppenheimer/README.md`](Flux/quick-oppenheimer/README.md)。

## 測試

後端測試：

```bash
cd Flux/quick-oppenheimer
python3 -m pytest -q
```

iOS 建模測試：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project Flux/Flux.xcodeproj \
  -scheme Flux \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:FluxTests
```
