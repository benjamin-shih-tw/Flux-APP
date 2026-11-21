# Flux 重點專案

使用者於 2026-10-07 指定 Flux-APP 為此工作區的主要專案。後續在此工作區的開發、分析與修正以本儲存庫為預設背景；使用者的新指示優先。

- 儲存庫：https://github.com/benjamin-shih-tw/Flux-APP
- Mac 根目錄：`/Users/benjamin/Documents/CODE/Flux`
- 先閱讀 `PROJECT_PROGRESS.md`、`PROJECT_CONTEXT.md` 與 `README.md`，再確認目前程式與 Git 狀態；背景文件是版本快照。
- `PROJECT_PROGRESS.md` 保存聊天決策、最新限制、進度與下一步；完成有意義的工作後同步更新，明確記錄實際驗證結果。
- 正式使用者建模／量測只能需要手機、水瓶與水；不得要求秤、量杯、尺、貼紙、標記或治具。舊研究中的額外工具方案已由使用者撤回；純手機方案尚待可行性與精度驗證。
- 實際 iOS 程式在 `Flux/Flux/`；Xcode 專案是 `Flux/Flux.xcodeproj`。
- 後端在 `Flux/quick-oppenheimer/`；Watch 在 `Flux/FluxWatch/`。
- `archive/legacy-swift/` 是不參與編譯的歷史版本，勿將其移入同步編譯目錄。
- 延續既有 SwiftUI／SwiftData／FastAPI 架構，修改前先讀相關模組與呼叫端。
- 回覆使用繁體中文，明確區分原始碼閱讀、測試通過、建置成功與實機精度驗證。
- 執行 Git 指令時確認根目錄是本儲存庫；上層 CODE 另有 Competitive-Programming 儲存庫。
