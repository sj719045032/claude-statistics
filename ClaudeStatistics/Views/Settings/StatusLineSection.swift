import SwiftUI
import ClaudeStatisticsKit

struct StatusLineSection: View {
    let installer: any StatusLineInstalling

    @State private var isInstalled: Bool
    @State private var showsLegendPopover = false
    @State private var message: LocalizedStringKey?
    @State private var isError = false

    init(installer: any StatusLineInstalling) {
        self.installer = installer
        _isInstalled = State(initialValue: installer.isInstalled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: "terminal")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(LocalizedStringKey(installer.titleLocalizationKey))
                            .font(.system(size: 13, weight: .medium))

                        if !installer.legendSections.isEmpty {
                            Button {
                                showsLegendPopover.toggle()
                            } label: {
                                Image(systemName: "questionmark.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showsLegendPopover, arrowEdge: .top) {
                                legendContent
                                    .frame(width: 330, alignment: .leading)
                                    .padding(12)
                            }
                        }
                    }

                    Text(LocalizedStringKey(installer.descriptionLocalizationKey))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { isInstalled },
                    set: { setEnabled($0) }
                ))
                .labelsHidden()
            }

            if let message, isError {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .padding(.leading, 42)
            }
        }
    }

    @ViewBuilder
    private var legendContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(installer.legendSections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey(section.titleLocalizationKey))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(section.items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: item.example)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(width: 148, alignment: .leading)

                            Text(LocalizedStringKey(item.descriptionLocalizationKey))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.top, 2)
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try installer.install()
            } else {
                try installer.restore()
            }

            isInstalled = installer.isInstalled
            message = nil
            isError = false
        } catch {
            isInstalled = installer.isInstalled
            message = LocalizedStringKey(error.localizedDescription)
            isError = true
        }
    }
}
