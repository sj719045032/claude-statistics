import SwiftUI
import ClaudeStatisticsKit

struct PricingManageView: View {
    enum ModelScope: String, CaseIterable, Identifiable {
        case provider
        case all

        var id: String { rawValue }
    }

    let provider: any SessionProvider
    let onBack: () -> Void

    @State private var models: [(id: String, pricing: ModelPricing.Pricing)] = []
    @State private var isFetching = false
    @State private var fetchMessage: String?
    @State private var fetchIsError = false
    @State private var editingModel: String?
    @State private var editInput = ""
    @State private var editOutput = ""
    @State private var editCache5m = ""
    @State private var editCache1h = ""
    @State private var editCacheRead = ""
    @State private var showAddModel = false
    @State private var newModelId = ""
    @State private var modelScope: ModelScope = .provider
    @State private var listOpacity = 1.0
    @State private var listOffset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("pricing.back")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.blue)

                Spacer()

                if isFetching {
                    ProgressView()
                        .scaleEffect(0.6)
                }

                Button(action: {
                    showAddModel = true
                    newModelId = ""
                    editInput = "3"; editOutput = "15"
                    editCache5m = "3.75"; editCache1h = "6"; editCacheRead = "0.3"
                }) {
                    Label("pricing.add", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if provider.pricingFetcher != nil {
                    Button(action: fetchRemote) {
                        Label("pricing.fetchLatest", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isFetching)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let pricingSourceKey = provider.pricingSourceLocalizationKey {
                Group {
                    if let pricingSourceURL = provider.pricingSourceURL {
                        Link(destination: pricingSourceURL) {
                            Text(LocalizedStringKey(pricingSourceKey))
                                .underline(false)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(LocalizedStringKey(pricingSourceKey))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let msg = fetchMessage {
                HStack {
                    Image(systemName: fetchIsError ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.system(size: 10))
                    Text(msg)
                        .font(.system(size: 11))
                }
                .foregroundStyle(fetchIsError ? .red : .green)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()

            Picker("", selection: $modelScope) {
                Text("pricing.scope.provider").tag(ModelScope.provider)
                Text("pricing.scope.all").tag(ModelScope.all)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Add model form
            if showAddModel {
                VStack(spacing: 6) {
                    HStack {
                        TextField("pricing.modelId", text: $newModelId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    HStack(spacing: 4) {
                        editField("pricing.input", text: $editInput)
                        editField("pricing.output", text: $editOutput)
                        editField("pricing.5mW", text: $editCache5m)
                        editField("pricing.1hW", text: $editCache1h)
                        editField("pricing.read", text: $editCacheRead)
                    }
                    HStack {
                        Button("session.cancel") {
                            showAddModel = false
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("pricing.save") {
                            saveNewModel()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(newModelId.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.05))
            }

            // Pricing table
            ScrollView {
                VStack(spacing: 0) {
                    // Table header
                    HStack(spacing: 0) {
                        Text("pricing.model")
                            .frame(width: 140, alignment: .leading)
                        Text("pricing.input")
                            .frame(width: 55, alignment: .trailing)
                        Text("pricing.output")
                            .frame(width: 55, alignment: .trailing)
                        Text("pricing.5mW")
                            .frame(width: 55, alignment: .trailing)
                        Text("pricing.1hW")
                            .frame(width: 55, alignment: .trailing)
                        Text("pricing.read")
                            .frame(width: 50, alignment: .trailing)
                        Spacer()
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.gray.opacity(0.08))

                    ForEach(Array(models.enumerated()), id: \.element.id) { index, item in
                        Group {
                            if editingModel == item.id {
                                editRow(item)
                            } else {
                                displayRow(item)
                            }
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                        .animation(Theme.quickSpring.delay(Double(index) * 0.015), value: models.map(\.id))
                        Divider()
                    }
                }
            }
            .opacity(listOpacity)
            .offset(y: listOffset)
        }
        .onAppear { refreshModels(animated: false) }
        .onChange(of: modelScope) { _, _ in refreshModels(animated: true) }
        .onChange(of: provider.kind) { _, _ in
            fetchMessage = nil
            fetchIsError = false
            editingModel = nil
            showAddModel = false
            modelScope = .provider
            refreshModels(animated: true)
        }
        .animation(Theme.quickSpring, value: provider.kind)
        .animation(Theme.quickSpring, value: modelScope)
        .animation(Theme.quickSpring, value: fetchMessage != nil)
    }

    // MARK: - Display row

    private func displayRow(_ item: (id: String, pricing: ModelPricing.Pricing)) -> some View {
        HStack(spacing: 0) {
            Text(shortModelName(item.id))
                .frame(width: 140, alignment: .leading)
                .lineLimit(1)
            Text(fmtPrice(item.pricing.input))
                .frame(width: 55, alignment: .trailing)
            Text(fmtPrice(item.pricing.output))
                .frame(width: 55, alignment: .trailing)
            Text(fmtPrice(item.pricing.cacheWrite5m))
                .frame(width: 55, alignment: .trailing)
            Text(fmtPrice(item.pricing.cacheWrite1h))
                .frame(width: 55, alignment: .trailing)
            Text(fmtPrice(item.pricing.cacheRead))
                .frame(width: 50, alignment: .trailing)

            Button(action: { startEditing(item) }) {
                Image(systemName: "pencil")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.leading, 6)

            Button(action: { deleteModel(item.id) }) {
                Image(systemName: "trash")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.6))
            .padding(.leading, 2)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .textSelection(.enabled)
    }

    // MARK: - Edit row

    private func editRow(_ item: (id: String, pricing: ModelPricing.Pricing)) -> some View {
        VStack(spacing: 6) {
            Text(item.id)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                editField("pricing.input", text: $editInput)
                editField("pricing.output", text: $editOutput)
                editField("pricing.5mW", text: $editCache5m)
                editField("pricing.1hW", text: $editCache1h)
                editField("pricing.read", text: $editCacheRead)
            }

            HStack {
                Button("session.cancel") { editingModel = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("pricing.save") { saveEditing(item.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.05))
    }

    private func editField(_ label: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            TextField("$", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 65)
        }
    }

    // MARK: - Actions

    private func loadModels() {
        let preferred = Set(provider.builtinPricingModels.keys)
        models = ModelPricing.shared.models
            .sorted {
                let lhsPreferred = preferred.contains($0.key)
                let rhsPreferred = preferred.contains($1.key)
                if lhsPreferred != rhsPreferred {
                    return lhsPreferred && !rhsPreferred
                }
                return $0.key < $1.key
            }
            .filter { item in
                switch modelScope {
                case .provider:
                    return preferred.contains(item.key)
                case .all:
                    return true
                }
            }
            .map { (id: $0.key, pricing: $0.value) }
    }

    private func startEditing(_ item: (id: String, pricing: ModelPricing.Pricing)) {
        editingModel = item.id
        editInput = fmtPrice(item.pricing.input)
        editOutput = fmtPrice(item.pricing.output)
        editCache5m = fmtPrice(item.pricing.cacheWrite5m)
        editCache1h = fmtPrice(item.pricing.cacheWrite1h)
        editCacheRead = fmtPrice(item.pricing.cacheRead)
    }

    private func saveEditing(_ modelId: String) {
        guard let input = Double(editInput),
              let output = Double(editOutput),
              let c5m = Double(editCache5m),
              let c1h = Double(editCache1h),
              let cRead = Double(editCacheRead) else { return }

        let pricing = ModelPricing.Pricing(
            input: input, output: output,
            cacheWrite5m: c5m, cacheWrite1h: c1h,
            cacheRead: cRead
        )
        ModelPricing.shared.updateModel(id: modelId, pricing: pricing)
        editingModel = nil
        loadModels()
    }

    private func saveNewModel() {
        let id = newModelId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty,
              let input = Double(editInput),
              let output = Double(editOutput),
              let c5m = Double(editCache5m),
              let c1h = Double(editCache1h),
              let cRead = Double(editCacheRead) else { return }

        let pricing = ModelPricing.Pricing(
            input: input, output: output,
            cacheWrite5m: c5m, cacheWrite1h: c1h,
            cacheRead: cRead
        )
        ModelPricing.shared.updateModel(id: id, pricing: pricing)
        showAddModel = false
        loadModels()
    }

    private func deleteModel(_ id: String) {
        ModelPricing.shared.removeModel(id: id)
        loadModels()
    }

    private func fetchRemote() {
        isFetching = true
        fetchMessage = nil

        Task {
            do {
                guard let fetcher = provider.pricingFetcher else {
                    await MainActor.run {
                        fetchMessage = "Failed to fetch pricing page"
                        fetchIsError = true
                        isFetching = false
                    }
                    return
                }

                let fetched = try await fetcher.fetchPricing()
                await MainActor.run {
                    ModelPricing.shared.updateModels(fetched)
                    loadModels()
                    if let key = provider.pricingUpdatedLocalizationKey {
                        let format = NSLocalizedString("\(key) %lld", comment: "")
                        fetchMessage = String(format: format, locale: Locale.current, fetched.count)
                    } else {
                        fetchMessage = nil
                    }
                    fetchIsError = false
                    isFetching = false
                }
            } catch {
                await MainActor.run {
                    fetchMessage = error.localizedDescription
                    fetchIsError = true
                    isFetching = false
                }
            }
        }
    }

    // MARK: - Helpers

    private func fmtPrice(_ value: Double) -> String {
        if value >= 1.0 {
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", value)
                : String(format: "%.2f", value)
        }
        // Remove trailing zeros
        let s = String(format: "%.4f", value)
        return s.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }

    private func shortModelName(_ id: String) -> String {
        id.replacingOccurrences(of: "claude-", with: "")
    }

    private func refreshModels(animated: Bool) {
        if !animated {
            loadModels()
            listOpacity = 1
            listOffset = 0
            return
        }

        withAnimation(.easeOut(duration: 0.12)) {
            listOpacity = 0
            listOffset = 10
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            loadModels()
            withAnimation(Theme.springAnimation) {
                listOpacity = 1
                listOffset = 0
            }
        }
    }
}
