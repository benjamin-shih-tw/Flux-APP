# Legacy Swift snapshot

這裡是早期版本的 Swift 檔案，**不參與編譯**，保留只為了查閱歷史寫法。

原本的位置是 `Flux/Views/`、`Flux/Models/`、`Flux/Managers/`、`Flux/FluxApp.swift`，
與實際會被編譯的 `Flux/Flux/` 同名檔案重複，但內容已經分歧（例如 `ARScannerView.swift`
這裡是 81 行，現行版本是 673 行）。

## 為什麼原本不會被編譯

`Flux/Flux.xcodeproj` 使用 Xcode 16 的 `PBXFileSystemSynchronizedRootGroup`
（`objectVersion = 77`），App target 的同步根目錄是 `path = Flux`，相對於
`.xcodeproj` 所在的 `Flux/`，也就是 `Flux/Flux/`。因此 `Flux/` 底下其他目錄
一律不在 target 內。

## 移動到這裡的注意事項

`archive/` 位於 repo 根目錄，在所有同步根目錄（`Flux/Flux`、`Flux/FluxTests`、
`Flux/FluxUITests`）之外，所以不會被 Xcode 自動收錄。

**不要把這個資料夾放回 `Flux/Flux/` 底下**，否則檔案會被自動加入編譯，
與現行檔案產生重複型別定義（duplicate declaration）錯誤。

確認可以丟掉之後，整個 `archive/` 目錄直接刪除即可；git 歷史仍保留這些內容。
