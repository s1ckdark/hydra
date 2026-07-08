// Hydra/Hydra/Views/Console/ConsoleView.swift
#if os(macOS)
import SwiftUI

struct ConsoleView: View {
    @StateObject private var vm = ConsoleViewModel()

    var body: some View {
        HSplitView {
            // 사이드바: 스니펫 목록
            VStack(alignment: .leading, spacing: 0) {
                List(selection: Binding(get: { vm.selectedID }, set: { vm.select($0) })) {
                    ForEach(vm.store.snippets) { s in
                        Text(s.name).tag(s.id)
                    }
                    .onMove { vm.store.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                Button { vm.newSnippet() } label: {
                    Label("새 스니펫", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 180, maxWidth: 260)

            // 디테일: 이름 + 에디터 + 실행/취소 + 콘솔
            VStack(alignment: .leading, spacing: 8) {
                TextField("이름", text: $vm.draftName)
                    .textFieldStyle(.roundedBorder)

                TextEditor(text: $vm.draftCode)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                    .border(Color.gray.opacity(0.3))

                HStack {
                    Button { Task { await vm.run() } } label: {
                        Label("실행", systemImage: "play.fill")
                    }
                    .disabled(vm.executor.isRunning)

                    Button { vm.executor.cancel() } label: {
                        Label("취소", systemImage: "stop.fill")
                    }
                    .disabled(!vm.executor.isRunning)

                    Spacer()
                    Button("저장") { vm.saveDraft() }
                    Button(role: .destructive) { vm.deleteSelected() } label: { Text("삭제") }
                }

                consoleOutput

                if let code = vm.executor.lastExitCode {
                    Text("exit code: \(code)").font(.caption).foregroundColor(code == 0 ? .green : .red)
                }
                Text("로컬(:8080)에서 실행됨 — 사용자 코드가 이 머신에서 그대로 실행됩니다.")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(10)
        }
    }

    private var consoleOutput: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(vm.executor.output) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(color(for: line.stream))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(6)
            }
            .background(Color.black.opacity(0.04))
            .frame(minHeight: 120)
            .onChange(of: vm.executor.output.count) { _ in
                if let last = vm.executor.output.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func color(for stream: ConsoleStream) -> Color {
        switch stream {
        case .stdout: return .primary
        case .stderr: return .red
        case .system: return .orange
        }
    }
}
#endif
