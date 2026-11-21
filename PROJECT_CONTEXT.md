# Flux 專案背景

本工作區的重點專案為 [Flux-APP](https://github.com/benjamin-shih-tw/Flux-APP)。
建立日期：2026-10-07。閱讀基準：`b5bd2b8f2450833387a9acb5fb649e66f9e3ea4b`（Document current app progress and release gaps）。
原本工作區是空資料夾；本次已 clone 成獨立 Git 儲存庫。此文件記錄原始碼與文件閱讀結果，本次沒有執行建置、測試或實機水量驗證。

## 產品與主流程

Flux 是飲水追蹤 iOS App，包含水瓶建模、俯視照片水量估算、手動飲水記錄、統計、提醒、Siri 與 Watch 整合。

1. `BottleProfileScannerView` 拍攝一張側面照片。
2. `BottleProfileExtraction` 正規化相片方向，以 Vision 前景遮罩（失敗時輪廓偵測）擷取剖面、顏色與 OCR 容量文字。
3. `ARHeightMeasurementView`／`ARMeasurementSupport` 先取得桌面上的瓶底，再把瓶口投影到瓶底垂直軸；支援裝置啟用 sceneDepth／mesh。
4. `BottleVolumeCalculator.fitProfileToMeasuredHeight` 以獨立高度決定尺寸；使用者確認的容量不改變幾何尺寸。
5. `BottleProfile` 保存物理剖面、顯示輪廓、容量、顏色；`BottleMeshGenerator` 產生 SceneKit 模型。
6. `ARScannerView` 以 IMU 引導俯拍，正規化影像，再顯示 `CircleSelectionView` 供使用者選取瓶口與水面圓。
7. `WaterAPIManager` 上傳 JPEG、物理剖面、容量、IMU、相機焦距與手動圓座標。
8. 後端偵測／採用手動圓，求水面高度並積分剖面、依確認容量比例換算剩餘毫升；品質不足要求重拍。
9. 使用者確認結果後更新掃描基準，飲用差量寫入 `WaterRecord`。

目前正式掃描呼叫明確傳入 `audioData: nil`。`AcousticCaptureManager` 與後端回音／共振分析保留，但不能描述成正式 App 已啟用聲學量測。後端 README 的聲學流程描述與現行 App 有差異，以呼叫端為準。

## 模組入口

| 路徑 | 用途 |
| --- | --- |
| `Flux/Flux/FluxApp.swift` | 注入 managers、SwiftData container、新手教學 |
| `Flux/Flux/Views/MainTabView.swift` | Home、Scan、Streak、Settings |
| `Flux/Flux/Views/DashboardView.swift` | 每日目標、森林進度、3D 瓶、快速／自訂記錄 |
| `Flux/Flux/Views/AnalyticsView.swift` | 七日圖、月份熱圖、連續達標、近期紀錄、CSV；Freeze 尚未完成 |
| `Flux/Flux/Views/SettingsView.swift` | 後端連線測試、提醒、整合開關、目標、教學 |
| `Flux/Flux/Managers/WaterAPIManager.swift` | multipart API、回應解碼、錯誤與除錯圖 |
| `Flux/Flux/Managers/BottleAlignmentManager.swift` | CoreMotion 姿態／穩定度；captureReady 門檻 0.82 |
| `Flux/Flux/Managers/SiriIntents.swift` | 記錄與查詢飲水 App Intents |
| `Flux/Flux/Managers/WatchConnectivityManager.swift` | iOS／Watch 訊息與今日總量 |
| `Flux/Flux/Managers/HealthKitManager.swift` | 授權與活動熱量查詢 |
| `Flux/Flux/Managers/WeatherKitManager.swift` | 定位與體感溫度 |
| `Flux/Flux/Managers/DynamicGoalEngine.swift` | 基本目標加天氣／活動啟發式調整 |
| `Flux/Flux/Models/` | SwiftData 模型、輪廓擷取、容量計算與網格 |
| `Flux/FluxWatch/` | Watch UI 與 connectivity bridge |
| `Flux/quick-oppenheimer/main.py` | FastAPI、輸入限制、估算整合與回應 |
| `Flux/quick-oppenheimer/circle_detector.py` | 瓶口、極座標水面候選、反光／瓶底歧義拒絕、疊圖 |
| `Flux/quick-oppenheimer/estimators.py` | 透視高度求解、品質閘門、影像／聲學融合 |
| `Flux/quick-oppenheimer/volume_engine.py` | 剖面驗證、圓錐台積分、容量比例換算 |
| `Flux/quick-oppenheimer/acoustics.py` | 重複 chirp 回音與共振檢查 |
| `Flux/FluxTests/` | 幾何尺度、遮罩座標、AR 高度、OCR 等 9 個測試 |
| `Flux/FluxUITests/` | 啟動／效能範本，尚非完整使用流程驗證 |
| `Flux/quick-oppenheimer/tests/` | 合成影像／音訊、手動圓、解析度与歧義回歸測試 |
| `archive/legacy-swift/` | 舊版參考，未參與現行編譯 |

## API 與執行

- `GET /health`
- `POST /api/v2/estimate_water_volume`
- `POST /api/v1/calculate_water_volume`（相容）
- 成功、重拍與輸入錯誤以 JSON `status` 表示；勿只靠 HTTP 200 判斷成功。
- 自動偵測大圖先縮至最大邊 768，再還原原圖座標；手動圓使用原 JPEG 像素。
- 掃描焦距目前由相機 field of view 推算；WaterAPIManager 另保留舊預設值。
- 預設後端 hostname 仍為 `http://lihongyideMacBook-Air.local:8000`，此 Mac 是否可連線尚未驗證。

後端：於 `Flux/quick-oppenheimer/` 建立 venv、安裝 requirements，執行 `uvicorn main:app --host 0.0.0.0 --port 8000 --reload`。
後端測試：於同目錄執行 `python3 -m pytest -q`。
iOS：開啟 `Flux/Flux.xcodeproj`；Swift 5，iOS 26.2；Watch target 為 watchOS 26.2。具體 simulator destination 先查本機可用設備。

## 狀態與限制

- README 記載過往本機模擬器建置、iOS 單元與後端測試通過；本次未重新驗證。
- 影像量測需要同區域網路的 Mac 後端，未提供公開 HTTPS 服務。
- 單張側面建模假設旋轉對稱；多角度資料型別與網格仍保留供相容。
- 濃厚反光、不透明瓶內水面、瓶壁厚度、AR 端點與剖面誤差仍影響精度；confidence 不是毫升誤差保證。
- Watch target 尚未嵌入 iOS 安裝包。
- App Icon、完整繁體中文、簽署 provisioning、隱私政策、商店素材與真實水量驗收仍待完成。
- Streak Freeze 尚是 token 增加介面；部分健康／天氣開關與整合仍待完成與實機驗證。

後續工作先檢查目前版本與相關實作，再更新此快照；不要把本文件當成所有功能已測試的證明。
