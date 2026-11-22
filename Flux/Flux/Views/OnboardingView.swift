import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var revealedCharacters = 0

    private let pages: [GuidePage] = [
        .init(step: "序章", title: "用拍照記錄水量", dialogue: "歡迎來到 Flux！藉由技術突破優化了紀錄水量的誤差。", tips: ["飲水紀錄保存在這支 iPhone", "首頁隨時查看今日進度"]),
        .init(step: "第一章 · 日常記錄", title: "先從一杯水開始", dialogue: "喝完水，點一下常用水量就能記錄。也可以自己輸入毫升數，Siri 和 Apple Watch 也能幫忙。", tips: ["快速加入 100、250 或 500 ml", "自訂輸入 1–5000 ml"]),
        .init(step: "第二章 · 建立水瓶", title: "幫水瓶建立專屬檔案", dialogue: "拍下直立水瓶的完整側面，再用手機量瓶高、確認容量。只需要手機、水瓶和水。", tips: ["瓶口到瓶底都要入鏡", "容量可手動輸入"]),
        .init(step: "第三章 · 拍照掃描", title: "對準瓶口，保持水平", dialogue: "打開瓶蓋，把瓶口內緣對齊取景圈。拿穩手機，Flux 會自動拍照尋找水面。", tips: ["讓瓶內有足夠光線", "照片估算需要同網路的 Mac 掃描服務"]),
        .init(step: "第四章 · 確認水線", title: "最後由你確認水面", dialogue: "檢查水面圈有沒有貼合水與內壁接觸的位置。抓錯層時，換個候選圈或自己微調。", tips: ["看不清楚就重拍或手動記錄", "照片水量是估算值"]),
        .init(step: "第五章 · 養成習慣", title: "讓進度持續累積", dialogue: "趨勢頁會整理七日飲水、月份紀錄和連續達標天數。你也能設定每日目標與白天提醒。", tips: ["提醒會依記錄調整時間", "小工具顯示今日進度"]),
        .init(step: "第六章 · 自由連結", title: "選擇你的冒險夥伴", dialogue: "Apple 健康、Apple Watch、Siri 和小工具都能依需要使用。以後也能在設定裡重播這段教學。", tips: ["健康資料同步可自行開啟", "Watch 支援離線排隊傳輸"])
    ]

    private var pageColor: Color {
        let progress = Double(page) / Double(max(pages.count - 1, 1))
        return Color(red: 0.72 - 0.37 * progress, green: 0.88 - 0.13 * progress, blue: 1)
    }

    private var isTyping: Bool { revealedCharacters < pages[page].dialogue.count }

    var body: some View {
        ZStack {
            FluxTheme.background.ignoresSafeArea()
            RadialGradient(colors: [pageColor.opacity(0.18), .clear], center: .top, startRadius: 20, endRadius: 430)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text("FLUX").font(.fluxFont(.headline, weight: .bold)).tracking(3)
                    Spacer()
                    Button("略過") { onFinish() }
                        .font(.fluxFont(.subheadline))
                        .foregroundStyle(FluxTheme.muted)
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)

                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index <= page ? pageColor : Color.white.opacity(0.14))
                            .frame(height: 4)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        ComicGuideScene(index: page, tint: pageColor, reduceMotion: reduceMotion)
                            .id(page)
                            .frame(height: 220)

                        VStack(alignment: .leading, spacing: 9) {
                            Text(pages[page].step)
                                .font(.fluxFont(.caption, weight: .bold))
                                .tracking(2)
                                .foregroundStyle(pageColor)
                            Text(pages[page].title)
                                .font(.fluxFont(size: 29, relativeTo: .largeTitle, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .fixedSize(horizontal: false, vertical: true)

                        dialogueBox

                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(pages[page].tips, id: \.self) { tip in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(pageColor)
                                    Text(tip).foregroundStyle(Color.white.opacity(0.85))
                                }
                                .font(.fluxFont(.subheadline))
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 26)
                    .padding(.bottom, 24)
                }

                if page > 0 {
                    HStack {
                        Button {
                            page -= 1
                        } label: {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 56, height: 54)
                                .fluxCard(cornerRadius: 18)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("上一頁")
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .task(id: page) {
            let characterCount = pages[page].dialogue.count
            revealedCharacters = reduceMotion ? characterCount : 0
            guard !reduceMotion else { return }
            for count in 1...characterCount {
                try? await Task.sleep(for: .milliseconds(42))
                guard !Task.isCancelled else { return }
                if revealedCharacters == characterCount { return }
                revealedCharacters = count
            }
        }
    }

    private var dialogueBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("FLUX 導覽員")
                    .font(.fluxFont(.caption, weight: .bold))
                    .foregroundStyle(pageColor)
                Spacer()
                Text(String(format: "%02d / %02d", page + 1, pages.count))
                    .font(.fluxFont(.caption))
                    .foregroundStyle(FluxTheme.muted)
            }
            Text(String(pages[page].dialogue.prefix(revealedCharacters)))
                .font(.fluxFont(.body))
                .foregroundStyle(.white)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            HStack {
                Spacer()
                Text(isTyping ? "點一下顯示全文" : (page == pages.count - 1 ? "▼ 按一下開始使用" : "▼ 按一下繼續"))
                    .font(.fluxFont(.caption, weight: .medium))
                    .foregroundStyle(pageColor)
            }
        }
        .padding(18)
        .background(FluxTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(pageColor.opacity(0.7), lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture(perform: advance)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("FLUX 導覽員：\(pages[page].dialogue)")
        .accessibilityHint(isTyping ? "點一下顯示全文" : (page == pages.count - 1 ? "點一下開始使用" : "點一下繼續"))
    }

    private func advance() {
        if isTyping {
            revealedCharacters = pages[page].dialogue.count
        } else if page == pages.count - 1 {
            onFinish()
        } else {
            page += 1
        }
    }
}

private struct GuidePage {
    let step: String
    let title: String
    let dialogue: String
    let tips: [String]
}

private struct ComicGuideScene: View {
    let index: Int
    let tint: Color
    let reduceMotion: Bool
    @State private var active = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(red: 0.08, green: 0.15, blue: 0.21))
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(tint.opacity(0.8), lineWidth: 2)
            comicPanel
                .padding(20)
        }
        .overlay(alignment: .topLeading) {
            Text(String(format: "SCENE %02d", index + 1))
                .font(.fluxFont(.caption2, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(FluxTheme.background)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(tint, in: UnevenRoundedRectangle(topLeadingRadius: 26, bottomTrailingRadius: 12))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sceneDescription)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
                active = true
            }
        }
    }

    private var sceneDescription: String {
        switch index {
        case 0: "水滴與今日飲水進度示意"
        case 1: "首頁快速加入 250 毫升的示意"
        case 2: "拍攝水瓶側面與量測瓶高的示意"
        case 3: "對準瓶口並自動拍照的示意"
        case 4: "確認水面圈位置的示意"
        case 5: "七日飲水趨勢圖的示意"
        default: "健康、手錶、Siri 與小工具整合的示意"
        }
    }

    @ViewBuilder
    private var comicPanel: some View {
        switch index {
        case 0:
            HStack(spacing: 24) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 86))
                    .foregroundStyle(tint)
                    .offset(y: active ? -8 : 8)
                VStack(alignment: .leading, spacing: 12) {
                    Text("今日任務")
                        .font(.fluxFont(.caption, weight: .bold))
                    Text("0 / 2000 ml")
                        .font(.fluxFont(.title3, weight: .bold))
                    Capsule().fill(tint.opacity(0.28)).frame(width: 118, height: 10)
                    Text("開始記錄！")
                        .font(.fluxFont(.caption, weight: .medium))
                        .padding(8)
                        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        case 1:
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("今日飲水")
                    Spacer()
                    Image(systemName: "drop.fill")
                }
                .font(.fluxFont(.caption, weight: .bold))
                Text(active ? "1000 / 2000 ml" : "750 / 2000 ml")
                    .font(.fluxFont(.title2, weight: .bold))
                    .contentTransition(.numericText())
                GeometryReader { proxy in
                    Capsule().fill(tint.opacity(0.18))
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint).frame(width: proxy.size.width * (active ? 0.5 : 0.375))
                        }
                }
                .frame(height: 12)
                HStack {
                    Spacer()
                    Text("＋ 250 ml")
                        .font(.fluxFont(.subheadline, weight: .bold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(tint, in: Capsule())
                        .foregroundStyle(FluxTheme.background)
                }
            }
            .padding(18)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
        case 2:
            HStack(spacing: 18) {
                Image(systemName: "waterbottle.fill")
                    .font(.system(size: 110, weight: .ultraLight))
                    .foregroundStyle(tint)
                    .frame(width: 105)
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [6, 5])))
                    .offset(y: active ? -4 : 4)
                VStack(alignment: .leading, spacing: 12) {
                    comicLabel("側面照片", symbol: "camera")
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 36))
                        .foregroundStyle(tint)
                    comicLabel("量瓶高", symbol: "ruler")
                    comicLabel("確認容量", symbol: "checkmark")
                }
            }
        case 3:
            ZStack {
                Circle().stroke(tint.opacity(0.45), lineWidth: 8).frame(width: 150, height: 150)
                Circle().stroke(tint, lineWidth: 3).frame(width: active ? 125 : 140, height: active ? 125 : 140)
                Image(systemName: "viewfinder")
                    .font(.system(size: 150, weight: .ultraLight))
                    .foregroundStyle(tint)
                Text("對準 · 保持水平")
                    .font(.fluxFont(.caption, weight: .bold))
                    .padding(7)
                    .background(FluxTheme.background.opacity(0.85), in: Capsule())
                    .offset(y: 80)
            }
            .frame(maxWidth: .infinity)
        case 4:
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(tint.opacity(0.45), lineWidth: 5).frame(width: 146, height: 146)
                    Circle().stroke(tint, lineWidth: 3).frame(width: active ? 96 : 83, height: active ? 96 : 83)
                    Image(systemName: "scope")
                        .font(.system(size: 24))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 12) {
                    comicLabel("瓶口外圈", symbol: "circle")
                    comicLabel("水面內圈", symbol: "circle.dotted")
                    Text("確認位置 ✓")
                        .font(.fluxFont(.caption, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
        case 5:
            VStack(alignment: .leading, spacing: 12) {
                Text("七日趨勢")
                    .font(.fluxFont(.subheadline, weight: .bold))
                HStack(alignment: .bottom, spacing: 11) {
                    ForEach(Array([0.35, 0.53, 0.46, 0.72, 0.6, 0.88, 0.78].enumerated()), id: \.offset) { item in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(tint.opacity(0.5 + item.element * 0.5))
                            .frame(maxWidth: .infinity)
                            .frame(height: 110 * item.element * (active ? 1 : 0.75))
                    }
                }
                Text("每天都更靠近目標")
                    .font(.fluxFont(.caption))
                    .foregroundStyle(tint)
            }
        default:
            VStack(spacing: 16) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 39))
                    .foregroundStyle(tint)
                    .scaleEffect(active ? 1.15 : 0.9)
                HStack(spacing: 7) {
                    integrationBadge("heart.fill", "健康")
                    integrationBadge("applewatch", "Watch")
                    integrationBadge("waveform", "Siri")
                    integrationBadge("square.grid.2x2", "小工具")
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func comicLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.fluxFont(.caption, weight: .medium))
            .foregroundStyle(.white)
            .padding(8)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    private func integrationBadge(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 21))
            Text(title).font(.fluxFont(.caption2, weight: .medium))
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
        .frame(height: 67)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}
