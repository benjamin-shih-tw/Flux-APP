# Flux

Flux 是一款 iOS 飲水追蹤 App，主要用於估算不透明水瓶中的剩餘水量。SwiftUI App 會建立可重複使用的瓶身模型，透過裝置姿態引導使用者拍攝，再將俯視照片傳送至本機 FastAPI／OpenCV 後端進行水量估算。

## 目前進度

### 水瓶建模

- 使用一張引導式側面照片，不再需要多角度掃描。
- Vision 前景分割（失敗時回退輪廓偵測）擷取瓶身輪廓，搭配 AR 高度量測（`ARHeightMeasurementView`）決定實際尺寸；支援手動輸入容量（100–5000 ml）並於辨識到瓶身標籤時自動建議，不再強制照片必須拍到印刷容量。
- 依量測高度與旋轉對稱外輪廓估算模型尺寸，儲存前由使用者確認容量與名稱。厚壁與瓶肩仍可能影響估值。

### 水量偵測

- 開啟第二頁即以 `AVCaptureSession`（全視角 4:3＋逐幀內參）與 `CMMotionManager` 水平引導開啟相機，預覽鎖定瓶內焦段（`0.46`）避免自動對焦鎖死在瓶口。將瓶口內緣對齊白色圓框、保持水平穩定約 0.45 秒後，自動以硬體馬達掃描 6 個焦段（`0.18–0.85`）。
- 後端逐張以像素邊緣精修瓶口並挑選單張最銳利未混疊影格（避免手持疊圖重影），再以 CIELAB 多通道梯度、±8% 視差偏移搜尋與 Huber-IRLS 次像素圓擬合找出排序後的水面候選圈，將疑似金屬瓶底排後。
- 拍攝後直接進入「確認水面位置」頁：以正向放大視角顯示清晰單張影像、鎖定綠框與模型建議橘框；確認無誤即可一鍵記錄，若抓錯層可在同頁點選其他候選圈，或直接點選／拖曳水面邊緣與滑桿微調後即時重算並確認保存。
- 大尺寸照片會先縮小偵測，再將結果換算回原始影像座標；預設嚴格自動模式（未帶 `return_candidates`）保留原有拒測行為。
- 使用校正後的瓶身剖面積分，估算剩餘水量與飲用量。
- API 回傳信心分數、估算方式、偵測半徑、水深、候選圈清單、選中焦段與除錯疊圖。
- 後端保留聲學估算程式，但目前 App 的正式掃描流程不會錄音或上傳音訊。

### 飲水追蹤

- 使用 SwiftData 保存水瓶、設定與飲水紀錄。
- Dashboard 顯示可重複使用的 3D 水瓶與目前剩餘水量。
- 支援快速新增、自訂水量、Siri 捷徑與隨 iPhone App 安裝的 Apple Watch App（環形進度、Digital Crown 自訂水量、復原上一筆、觸覺回饋、離線排隊與跨日重置）。
- 顯示七日趨勢、月份熱圖、連續達標、一致性與成就摘要；可匯出 CSV。
- 支援白天智慧提醒：記水後延後提醒，達標後停止當天提醒；可設定 1–4 小時間隔。
- iPhone Widget 顯示今日飲水進度；Apple Health 支援雙向整合（寫入今日與後續飲水、刪除紀錄同步刪除健康樣本、讀取當日活動熱量調整動態目標、可選匯入其他 App 寫入 Apple Health 的飲水紀錄並自動去重）。通知、Widget、Watch 與 HealthKit 的實際行為仍需實機與權限驗證。
- 首次啟動提供新手教學，設定頁可重播並測試後台 `/health` 連線。

## 發佈狀態

- iOS 模擬器建置、iOS 單元測試與後端測試已在本機通過；這不代表實機水量精度已驗證。
- 相機水量掃描目前需要同區域網路中的 Mac 後端，尚未提供公開 HTTPS 服務。
- Apple Watch target 已嵌入 iOS App 安裝包；配對傳輸與安裝仍需實機驗證。
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
5. 新增水瓶、拍攝包含容量標示的側面輪廓、儲存水瓶，再進行俯視水量掃描。

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
