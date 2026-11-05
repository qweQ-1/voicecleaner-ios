import SwiftUI

/// 主界面：状态卡 + 控制区 + 实时电平表。
struct ContentView: View {
    @StateObject private var viewModel = VoiceCleanerViewModel()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    levelMeter
                    controls
                    modeSelector
                    strengthSlider
                    hardwareCard
                    noiseProfileCard
                    instructionsCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("净声")
        }
        .task {
            await viewModel.bootstrap()
        }
        .onDisappear {
            viewModel.shutdown()
        }
    }

    // MARK: - 状态卡

    private var statusCard: some View {
        VStack(spacing: 10) {
            HStack {
                Circle()
                    .fill(viewModel.statusColor)
                    .frame(width: 12, height: 12)
                Text(viewModel.statusText)
                    .font(.headline)
                Spacer()
                if viewModel.isRunning {
                    Text("已处理 \(viewModel.stats.processedFrames) 帧")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.isLearning {
                ProgressView(value: viewModel.learningProgress)
                    .tint(.blue)
                Text("正在学习环境噪声…请保持安静")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case .failed(let message) = viewModel.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 电平表

    private var levelMeter: some View {
        VStack(spacing: 10) {
            HStack {
                Text("输入")
                    .font(.caption)
                    .frame(width: 36, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.tertiarySystemFill))
                        Capsule()
                            .fill(Color.orange)
                            .frame(width: geo.size.width * CGFloat(min(viewModel.stats.inputLevel * 3, 1)))
                    }
                }
                .frame(height: 10)
                Text("\(Int(viewModel.stats.inputLevel * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }

            HStack {
                Text("输出")
                    .font(.caption)
                    .frame(width: 36, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.tertiarySystemFill))
                        Capsule()
                            .fill(Color.green)
                            .frame(width: geo.size.width * CGFloat(min(viewModel.stats.outputLevel * 3, 1)))
                    }
                }
                .frame(height: 10)
                Text("\(Int(viewModel.stats.outputLevel * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }

            HStack {
                Text("降噪量")
                    .font(.caption)
                Spacer()
                Text(String(format: "%.1f dB", viewModel.stats.attenuationDb))
                    .font(.caption.monospacedDigit())
                Text("信噪比 \(String(format: "%.0f", viewModel.stats.snrDb)) dB")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 控制区

    private var controls: some View {
        VStack(spacing: 12) {
            Button {
                viewModel.toggle()
            } label: {
                HStack {
                    Image(systemName: viewModel.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title2)
                    Text(viewModel.isRunning ? "停止" : "开始降噪")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isRunning ? .red : .accentColor)

            if viewModel.isRunning {
                Button {
                    viewModel.relearn()
                } label: {
                    Label("重新学习环境噪声", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - 模式选择

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("输出模式").font(.subheadline.bold())
            Picker("输出模式", selection: $viewModel.mode) {
                ForEach(NoiseSuppressionEngine.OutputMode.allCases, id: \.self) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)

            Text(modeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var modeDescription: String {
        switch viewModel.mode {
        case .silent:
            return "只采集和降噪，不外放。用于配合「外放接管」方案：开启后用扬声器播放处理后的声音。"
        case .monitor:
            return "实时外放降噪后的声音，用耳机听效果。注意外放时会串到其他 App 的麦克风。"
        case .record:
            return "把降噪后的音频写成 WAV 文件。"
        }
    }

    // MARK: - 强度

    private var strengthSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("降噪强度").font(.subheadline.bold())
                Spacer()
                Text(String(format: "%.0f%%", viewModel.strength * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $viewModel.strength, in: 0...1)
                .onChange(of: viewModel.strength) { _, newValue in
                    viewModel.applyStrength(newValue)
                }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 硬件语音处理

    private var hardwareCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $viewModel.useHardwareVoiceProcessing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple 硬件语音处理").font(.subheadline.bold())
                    Text("系统 DSP 提供回声消除 + 自动增益 + 硬件降噪，效果远好于纯软件算法，且几乎不占 CPU。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(viewModel.isRunning)

            if viewModel.isRunning {
                Text("需停止后重新开始才能生效")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 噪声剖面

    private var noiseProfileCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("环境噪声剖面").font(.subheadline.bold())
            Text("展示学习到的噪声频谱分布，峰值越高说明该频段背景噪音越强。")
                .font(.caption)
                .foregroundStyle(.secondary)
            NoiseProfileView(profile: viewModel.noiseProfile)
                .frame(height: 90)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 说明

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("怎么让别的 App 用上降噪音频").font(.subheadline.bold())

            ForEach(Array(instructions.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                    Text(item)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider().padding(.vertical, 2)

            Text("关于「系统级虚拟麦克风」").font(.caption.bold())
            Text("iPhone 上做不到。Apple 的 DriverKit 音频驱动（AudioDriverKit）官方只支持 macOS 和 M 芯片 iPadOS，且需要向 Apple 单独申请 com.apple.developer.driverkit 权限。所以这里用外放接管的方式。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var instructions: [String] {
        switch viewModel.route {
        case .speakerRelay:
            return [
                "1. 选「实时监听」模式并开始降噪，处理后的声音会从扬声器放出。",
                "2. 在目标 App（如微信、钉钉、录音机）里正常使用，麦克风会拾取扬声器里干净的语音。",
                "3. 想减少环境噪音干扰时，把手机麦克风孔贴近嘴部稍下方。",
                "这是折中方案：音质受房间声学影响，目标 App 仍会录到少量环境底噪。",
                "若目标 App 支持选输入设备，可优先选「扬声器 + 麦克风」并把音量调低以减少失真。"
            ]
        }
    }
}

/// 噪声剖面可视化
struct NoiseProfileView: View {
    let profile: [Float]

    var body: some View {
        Canvas { context, size in
            guard profile.count > 1 else { return }
            let maxValue = max(profile.max() ?? 0, 1e-6)
            var path = Path()
            for (index, value) in profile.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(profile.count - 1)
                let normalized = CGFloat(value / maxValue)
                let y = size.height * (1 - normalized)
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(.orange), lineWidth: 1.5)
            context.fill(path, with: .linearGradient(
                Gradient(colors: [.orange.opacity(0.4), .orange.opacity(0.05)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            ))
        }
    }
}

#Preview {
    ContentView()
}
