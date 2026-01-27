//
//  ContentView.swift
//  random-player
//
//  Created by 강동호 on 5/21/25.
//

import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    
    let defaultExtensions = ["mp4", "avi"]
    
    @Environment(\.modelContext) private var modelContext
    
    @Query private var extensionItems: [ExtensionItem]
    @Query private var directoryItems: [DirectoryBookmark]

    @State private var customExtension = ""
    @State private var selectedDirectories: [URL] = []
    @State private var indexedFiles: [URL] = []
    @State private var selectedApp: URL? = nil
    @State private var lastExecutedFile: URL?
    @State private var recentExecutedFiles: [URL] = []
    @State private var showDeleteConfirmation = false
    @State private var isIndexing = false
    @State private var isCleaning = false
    @State private var deleteStatus: (message: String, isSuccess: Bool)? = nil
    @State private var pendingCleanTargets: [URL] = []
    @State private var showCleanConfirmation = false
    
    @State private var selectedCleanTargets: Set<URL> = []
    @State private var showCleanSheet = false

    private func cleanEmptySubdirectories(targets: [URL]) -> (deleted: Int, failed: Int) {
        var deletedCount = 0
        var failedCount = 0
        let fileManager = FileManager.default
        for subdir in targets {
            do {
                try fileManager.removeItem(at: subdir)
                deletedCount += 1
            } catch {
                failedCount += 1
            }
        }
        return (deletedCount, failedCount)
    }
    
    private func computeCleanTargets(minBytes: Int64) -> [URL] {
        var targets: [URL] = []
        let fileManager = FileManager.default
        func directoryContainsLargeFile(_ url: URL, minBytes: Int64) -> Bool {
            let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
            let options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants, .skipsHiddenFiles]
            guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: Array(resourceKeys), options: options) else {
                return false
            }
            for case let fileURL as URL in enumerator {
                do {
                    let resourceValues = try fileURL.resourceValues(forKeys: resourceKeys)
                    if resourceValues.isRegularFile == true, let fileSize = resourceValues.fileSize, fileSize >= minBytes {
                        return true
                    }
                } catch {
                    // Ignore errors and continue
                }
            }
            return false
        }
        for directory in selectedDirectories {
            do {
                let subdirectories = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                for subdir in subdirectories {
                    do {
                        let resourceValues = try subdir.resourceValues(forKeys: [.isDirectoryKey])
                        if resourceValues.isDirectory == true {
                            if !directoryContainsLargeFile(subdir, minBytes: minBytes) {
                                targets.append(subdir)
                            }
                        }
                    } catch {
                        // Ignore errors and continue
                    }
                }
            } catch {
                // Ignore errors and continue
            }
        }
        return targets
    }
    
    private func updateDirectories(from items: [DirectoryBookmark]) {
        selectedDirectories.removeAll()
        for item in items {
            if let url = item.resolveURL() {
                _ = url.startAccessingSecurityScopedResource()
                selectedDirectories.append(url)
            }
        }
    }
    
    private func execute(file: URL) {
        guard let app = selectedApp else { return }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        lastExecutedFile = file
        // Update recent list: put most recent at front, unique, cap at 10
        recentExecutedFiles.removeAll { $0 == file }
        recentExecutedFiles.insert(file, at: 0)
        if recentExecutedFiles.count > 10 {
            recentExecutedFiles.removeLast(recentExecutedFiles.count - 10)
        }
    }
    
    @AppStorage("selectedAppPath") private var selectedAppPath: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading) {
                HStack {
                    ForEach(defaultExtensions, id: \.self) { ext in
                        Toggle(isOn: Binding(
                            get: { extensionItems.map(\.name).contains(ext) },
                            set: { isSelected in
                                if isSelected {
                                    if !extensionItems.map(\.name).contains(ext) {
                                        modelContext.insert(ExtensionItem(name: ext))
                                    }
                                } else {
                                    if let item = extensionItems.first(where: { $0.name == ext }) {
                                        modelContext.delete(item)
                                    }
                                }
                            })) {
                                Text(ext)
                            }
                    }

                    TextField("Add Extension", text: $customExtension)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .onSubmit {
                            let trimmed = customExtension.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty, !extensionItems.map(\.name).contains(trimmed) else { return }
                            modelContext.insert(ExtensionItem(name: trimmed))
                            customExtension = ""
                        }
                    
                    Button("Indexing") {
                        isIndexing = true
                        indexedFiles.removeAll()
                        DispatchQueue.global(qos: .userInitiated).async {
                            var results: [URL] = []
                            for directory in selectedDirectories {
                                let fileManager = FileManager.default
                                if let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) {
                                    for case let fileURL as URL in enumerator {
                                        if extensionItems.map(\.name).contains(fileURL.pathExtension.lowercased()) {
                                            results.append(fileURL)
                                        }
                                    }
                                }
                            }
                            DispatchQueue.main.async {
                                indexedFiles = results
                                isIndexing = false
                            }
                        }
                    }
                    .keyboardShortcut("i", modifiers: [.command])
                    .disabled(isIndexing || selectedDirectories.isEmpty)
                    
                    Button("Choose App") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        panel.canChooseFiles = true
                        panel.allowedContentTypes = [UTType.application]
                        if panel.runModal() == .OK, let url = panel.url {
                            selectedApp = url
                            selectedAppPath = url.path
                        }
                    }
                    Button("Execution") {
                        guard let file = indexedFiles.randomElement() else { return }
                        execute(file: file)
                    }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(indexedFiles.isEmpty)
                    Button("Delete") {
                        showDeleteConfirmation = true
                    }
                    .keyboardShortcut("d", modifiers: [.command])
                    .disabled(lastExecutedFile == nil)
                    .alert("are you sure delete?", isPresented: $showDeleteConfirmation) {
                        Button("delete", role: .destructive) {
                            guard let file = lastExecutedFile else { return }
                            do {
                                try FileManager.default.removeItem(at: file)
                                indexedFiles.removeAll { $0 == file }
                                recentExecutedFiles.removeAll { $0 == file }
                                //lastExecutedFile = nil
                                deleteStatus = (String(localized: "delete_success"), true)
                            } catch {
                                deleteStatus = (String(localized: "delete_failed"), false)
                            }
                        }
                        Button("cancel", role: .cancel) {}
                    }
                    Button {
                        // Phase 1: compute targets and ask for confirmation
                        isCleaning = true
                        DispatchQueue.global(qos: .userInitiated).async {
                            let targets = computeCleanTargets(minBytes: 10 * 1024 * 1024)
                            DispatchQueue.main.async {
                                pendingCleanTargets = targets
                                selectedCleanTargets = Set(targets)
                                isCleaning = false
                                if !targets.isEmpty {
                                    // Use sheet with per-item selection instead of single alert
                                    showCleanSheet = true
                                } else {
                                    deleteStatus = (String(localized: "clean_success 0"), true)
                                }
                            }
                        }
                    } label: {
                        Text(Locale.current.language.languageCode?.identifier == "ko" ? "정리" : "Clean")
                    }
                    .keyboardShortcut("k", modifiers: [.command])
                    .disabled(isCleaning || selectedDirectories.isEmpty)
                    .sheet(isPresented: $showCleanSheet) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(Locale.current.language.languageCode?.identifier == "ko" ? "삭제할 폴더를 선택하세요" : "Select folders to delete")
                                .font(.headline)
                            if pendingCleanTargets.isEmpty {
                                Text(Locale.current.language.languageCode?.identifier == "ko" ? "삭제할 항목이 없습니다." : "No items to delete.")
                                    .foregroundColor(.secondary)
                            } else {
                                HStack(spacing: 12) {
                                    Button(Locale.current.language.languageCode?.identifier == "ko" ? "모두 선택" : "Select All") {
                                        selectedCleanTargets = Set(pendingCleanTargets)
                                    }
                                    Button(Locale.current.language.languageCode?.identifier == "ko" ? "모두 해제" : "Deselect All") {
                                        selectedCleanTargets.removeAll()
                                    }
                                }
                                List {
                                    ForEach(pendingCleanTargets, id: \.self) { url in
                                        HStack {
                                            Toggle(isOn: Binding(
                                                get: { selectedCleanTargets.contains(url) },
                                                set: { isOn in
                                                    if isOn { selectedCleanTargets.insert(url) } else { selectedCleanTargets.remove(url) }
                                                }
                                            )) {
                                                Text(url.path)
                                                    .font(.caption)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                        }
                                    }
                                }
                            }
                            HStack {
                                Spacer()
                                Button(role: .cancel) {
                                    pendingCleanTargets.removeAll()
                                    selectedCleanTargets.removeAll()
                                    showCleanSheet = false
                                } label: {
                                    Text(Locale.current.language.languageCode?.identifier == "ko" ? "취소" : "Cancel")
                                }
                                Button(role: .destructive) {
                                    // Perform deletion of selected items
                                    isCleaning = true
                                    let targets = Array(selectedCleanTargets)
                                    pendingCleanTargets.removeAll()
                                    selectedCleanTargets.removeAll()
                                    showCleanSheet = false
                                    DispatchQueue.global(qos: .userInitiated).async {
                                        let (deleted, failed) = cleanEmptySubdirectories(targets: targets)
                                        DispatchQueue.main.async {
                                            // Remove deleted paths from recent history
                                            if !targets.isEmpty {
                                                let deletedDirs = targets
                                                recentExecutedFiles.removeAll { fileURL in
                                                    // Remove if the file is exactly one of the targets or is contained in a deleted directory
                                                    if deletedDirs.contains(fileURL) { return true }
                                                    return deletedDirs.contains { dir in fileURL.path.hasPrefix(dir.path + "/") }
                                                }
                                            }
                                            if failed == 0 {
                                                deleteStatus = (String(localized: "clean_success \(deleted)"), true)
                                            } else {
                                                deleteStatus = (String(localized: "clean_success_failed \(deleted) \(failed)"), failed == 0)
                                            }
                                            isCleaning = false
                                        }
                                    }
                                } label: {
                                    Text(Locale.current.language.languageCode?.identifier == "ko" ? "삭제" : "Delete")
                                }
                            }
                        }
                        .padding()
                        .frame(minWidth: 600, minHeight: 400)
                    }
                }
                .padding(.bottom, 5)
                
                if isIndexing {
                    Text("Indexing...")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                
                if isCleaning {
                    Text("Cleaning...")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                
                if let appURL = selectedApp {
                    Text("Selected App: \(appURL.lastPathComponent)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if !indexedFiles.isEmpty {
                    Text("Total File count: \(indexedFiles.count)개")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if let lastFile = lastExecutedFile {
                    Text("Last Executed File: \(lastFile.path)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                if let status = deleteStatus {
                    Text(status.message)
                        .font(.caption)
                        .foregroundColor(status.isSuccess ? .green : .red)
                        .transition(.opacity)
                }
                
                List {
                    ForEach(extensionItems, id: \.id) { extItem in
                        Text(extItem.name)
                            .contextMenu {
                                Button(role: .destructive) {
                                    modelContext.delete(extItem)
                                } label: {
                                    Label("delete", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            modelContext.delete(extensionItems[index])
                        }
                    }
                }
                
                HStack {
                    Button("Add Path") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = true

                        if panel.runModal() == .OK {
                            for url in panel.urls {
                                guard !directoryItems.contains(where: { $0.path == url.path }) else { continue }
                                selectedDirectories.append(url)
                                _ = url.startAccessingSecurityScopedResource()
                                modelContext.insert(DirectoryBookmark(url: url))
                            }
                            try? modelContext.save()
                        }
                    }
                    Button("Clear Path") {
                        for url in selectedDirectories {
                            url.stopAccessingSecurityScopedResource()
                        }
                        selectedDirectories.removeAll()
                        for item in directoryItems {
                            modelContext.delete(item)
                        }
                        try? modelContext.save()
                    }
                }
                .padding(.top, 10)
                
                List {
                    ForEach(selectedDirectories, id: \.self) { url in
                        Text(url.path)
                            .contextMenu {
                                Button(role: .destructive) {
                                    if let index = selectedDirectories.firstIndex(of: url) {
                                        selectedDirectories.remove(at: index)
                                        url.stopAccessingSecurityScopedResource()
                                    }
                                    if let item = directoryItems.first(where: { $0.path == url.path }) {
                                        modelContext.delete(item)
                                    }
                                    try? modelContext.save()
                                } label: {
                                    Label("delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            
            VStack(alignment: .leading, spacing: 8) {
                Text(Locale.current.language.languageCode?.identifier == "ko" ? "최근 실행한 파일" : "Recently Executed")
                    .font(.headline)
                if recentExecutedFiles.isEmpty {
                    Text(Locale.current.language.languageCode?.identifier == "ko" ? "최근 실행 이력이 없습니다." : "No recent items.")
                        .foregroundColor(.secondary)
                } else {
                    List {
                        ForEach(recentExecutedFiles, id: \.self) { url in
                            Button {
                                execute(file: url)
                            } label: {
                                HStack {
                                    Image(systemName: "play.circle")
                                    Text(url.path)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(selectedApp == nil)
                        }
                    }
                }
            }
            .frame(minWidth: 280, maxWidth: 360, maxHeight: .infinity, alignment: .top)
        }
        .padding()
        .onAppear {
            let path = selectedAppPath
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                selectedApp = url
            }
            updateDirectories(from: directoryItems)
        }
        .onChange(of: directoryItems) { oldValue, newValue in
            updateDirectories(from: newValue)
        }
        .onChange(of: deleteStatus?.message) { oldValue, newValue in
            guard newValue != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation {
                    deleteStatus = nil
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [ExtensionItem.self, DirectoryBookmark.self], inMemory: true)
}

