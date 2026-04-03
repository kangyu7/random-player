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

enum SidebarItem: String, CaseIterable, Identifiable {
    case player
    case clean
    case duplicates
    case settings
    
    var id: String { rawValue }
    
    var label: String {
        let isKo = Locale.current.language.languageCode?.identifier == "ko"
        switch self {
        case .player: return isKo ? "플레이어" : "Player"
        case .clean: return isKo ? "정리" : "Clean"
        case .duplicates: return isKo ? "중복" : "Duplicates"
        case .settings: return isKo ? "설정" : "Settings"
        }
    }
    
    var icon: String {
        switch self {
        case .player: return "play.circle"
        case .clean: return "trash.circle"
        case .duplicates: return "doc.on.doc"
        case .settings: return "gearshape"
        }
    }
}

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
    
    @State private var selectedCleanTargets: Set<URL> = []
    
    @State private var duplicateGroups: [[URL]] = []
    @State private var isFindingDuplicates = false
    
    @State private var selectedSidebarItem: SidebarItem? = .player

    private func findDuplicateGroups(files: [URL]) -> [[URL]] {
        // Extract filename without extension for each file
        let fileNames = files.map { $0.deletingPathExtension().lastPathComponent }
        
        // Build adjacency: two files are "duplicates" if one name fully contains the other
        let count = files.count
        // Union-Find for grouping
        var parent = Array(0..<count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        
        // Sort indices by name length (ascending) so shorter names come first
        let sortedIndices = (0..<count).sorted { fileNames[$0].count < fileNames[$1].count }
        
        // For each pair, check containment (case-insensitive)
        // Optimization: group by checking shorter names against longer ones
        for i in 0..<sortedIndices.count {
            let idxA = sortedIndices[i]
            let nameA = fileNames[idxA].lowercased()
            for j in (i + 1)..<sortedIndices.count {
                let idxB = sortedIndices[j]
                let nameB = fileNames[idxB].lowercased()
                // nameA is shorter or equal; check if nameA is contained in nameB or equal
                if nameA == nameB || nameB.contains(nameA) {
                    union(idxA, idxB)
                }
            }
        }
        
        // Collect groups
        var groups: [Int: [URL]] = [:]
        for i in 0..<count {
            let root = find(i)
            groups[root, default: []].append(files[i])
        }
        
        // Only return groups with more than one file, sorted by group size descending
        return groups.values
            .filter { $0.count > 1 }
            .sorted { $0.count > $1.count }
    }
    
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
        lastExecutedFile = file
        recentExecutedFiles.removeAll { $0 == file }
        recentExecutedFiles.insert(file, at: 0)
        if recentExecutedFiles.count > maxRecentCount {
            recentExecutedFiles.removeLast(recentExecutedFiles.count - maxRecentCount)
        }

        if useInternalPlayer {
            showingInternalPlayer = true
        } else {
            guard let app = selectedApp else { return }
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }
    
    @AppStorage("selectedAppPath") private var selectedAppPath: String = ""
    @AppStorage("maxRecentCount") private var maxRecentCount: Int = 10
    @AppStorage("useInternalPlayer") private var useInternalPlayer: Bool = false
    @AppStorage("seekSeconds") private var seekSeconds: Int = 1

    @State private var showingInternalPlayer = false

    // MARK: - Player View
    
    @ViewBuilder
    private var playerView: some View {
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
                    
                    Picker("", selection: $useInternalPlayer) {
                        Text(Locale.current.language.languageCode?.identifier == "ko" ? "내부 플레이어" : "Internal").tag(true)
                        Text(Locale.current.language.languageCode?.identifier == "ko" ? "외부 앱" : "External App").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)

                    if !useInternalPlayer {
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
                
                if !useInternalPlayer, let appURL = selectedApp {
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
                            .disabled(!useInternalPlayer && selectedApp == nil)
                        }
                    }
                }
            }
            .frame(minWidth: 280, maxWidth: 360, maxHeight: .infinity, alignment: .top)
        }
        .padding()
    }
    
    // MARK: - Clean View
    
    @ViewBuilder
    private var cleanView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Locale.current.language.languageCode?.identifier == "ko" ? "폴더 정리" : "Clean Folders")
                    .font(.headline)
                Spacer()
                Button {
                    isCleaning = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        let targets = computeCleanTargets(minBytes: 10 * 1024 * 1024)
                        DispatchQueue.main.async {
                            pendingCleanTargets = targets
                            selectedCleanTargets = Set(targets)
                            isCleaning = false
                        }
                    }
                } label: {
                    Text(Locale.current.language.languageCode?.identifier == "ko" ? "검색" : "Scan")
                }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(isCleaning || selectedDirectories.isEmpty)
            }
            
            if isCleaning {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(Locale.current.language.languageCode?.identifier == "ko" ? "검색 중..." : "Scanning...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if selectedDirectories.isEmpty {
                Text(Locale.current.language.languageCode?.identifier == "ko" ? "먼저 플레이어 탭에서 경로를 추가하세요." : "Add paths in the Player tab first.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pendingCleanTargets.isEmpty && !isCleaning {
                Text(Locale.current.language.languageCode?.identifier == "ko" ? "검색 버튼을 눌러 정리할 폴더를 찾으세요." : "Press Scan to find folders to clean.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !pendingCleanTargets.isEmpty {
                HStack(spacing: 12) {
                    Button(Locale.current.language.languageCode?.identifier == "ko" ? "모두 선택" : "Select All") {
                        selectedCleanTargets = Set(pendingCleanTargets)
                    }
                    Button(Locale.current.language.languageCode?.identifier == "ko" ? "모두 해제" : "Deselect All") {
                        selectedCleanTargets.removeAll()
                    }
                    Spacer()
                    Text(Locale.current.language.languageCode?.identifier == "ko"
                         ? "\(pendingCleanTargets.count)개 폴더 발견, \(selectedCleanTargets.count)개 선택됨"
                         : "\(pendingCleanTargets.count) folders found, \(selectedCleanTargets.count) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        isCleaning = true
                        let targets = Array(selectedCleanTargets)
                        pendingCleanTargets.removeAll()
                        selectedCleanTargets.removeAll()
                        DispatchQueue.global(qos: .userInitiated).async {
                            let (deleted, failed) = cleanEmptySubdirectories(targets: targets)
                            DispatchQueue.main.async {
                                if !targets.isEmpty {
                                    let deletedDirs = targets
                                    recentExecutedFiles.removeAll { fileURL in
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
                    .disabled(selectedCleanTargets.isEmpty)
                }
            }
            
            if let status = deleteStatus {
                Text(status.message)
                    .font(.caption)
                    .foregroundColor(status.isSuccess ? .green : .red)
                    .transition(.opacity)
            }
        }
        .padding()
    }
    
    // MARK: - Duplicates View
    
    @ViewBuilder
    private var duplicatesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Locale.current.language.languageCode?.identifier == "ko" ? "중복 파일 검색" : "Find Duplicate Files")
                    .font(.headline)
                Spacer()
                if !duplicateGroups.isEmpty {
                    let totalFiles = duplicateGroups.reduce(0) { $0 + $1.count }
                    Text(Locale.current.language.languageCode?.identifier == "ko"
                         ? "\(duplicateGroups.count)개 그룹, \(totalFiles)개 파일"
                         : "\(duplicateGroups.count) groups, \(totalFiles) files")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button {
                    isFindingDuplicates = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        let groups = findDuplicateGroups(files: indexedFiles)
                        DispatchQueue.main.async {
                            duplicateGroups = groups
                            isFindingDuplicates = false
                        }
                    }
                } label: {
                    Text(Locale.current.language.languageCode?.identifier == "ko" ? "검색" : "Scan")
                }
                .disabled(isFindingDuplicates || indexedFiles.isEmpty)
            }
            
            if isFindingDuplicates {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(Locale.current.language.languageCode?.identifier == "ko" ? "검색 중..." : "Scanning...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if indexedFiles.isEmpty {
                Text(Locale.current.language.languageCode?.identifier == "ko" ? "먼저 플레이어 탭에서 인덱싱을 실행하세요." : "Run Indexing in the Player tab first.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if duplicateGroups.isEmpty && !isFindingDuplicates {
                Text(Locale.current.language.languageCode?.identifier == "ko" ? "검색 버튼을 눌러 중복 파일을 찾으세요." : "Press Scan to find duplicate files.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !duplicateGroups.isEmpty {
                List {
                    ForEach(Array(duplicateGroups.enumerated()), id: \.offset) { groupIndex, group in
                        Section {
                            ForEach(group, id: \.self) { url in
                                Text(url.path)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .onTapGesture(count: 2) {
                                        execute(file: url)
                                    }
                                    .contextMenu {
                                        Button {
                                            NSWorkspace.shared.activateFileViewerSelecting([url])
                                        } label: {
                                            Label(Locale.current.language.languageCode?.identifier == "ko" ? "Finder에서 보기" : "Show in Finder", systemImage: "folder")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            do {
                                                try FileManager.default.removeItem(at: url)
                                                indexedFiles.removeAll { $0 == url }
                                                // Remove from duplicate groups and clean up empty groups
                                                duplicateGroups = duplicateGroups.compactMap { group in
                                                    let filtered = group.filter { $0 != url }
                                                    return filtered.count > 1 ? filtered : nil
                                                }
                                            } catch {
                                                deleteStatus = (String(localized: "delete_failed"), false)
                                            }
                                        } label: {
                                            Label(Locale.current.language.languageCode?.identifier == "ko" ? "파일 삭제" : "Delete File", systemImage: "trash")
                                        }
                                    }
                            }
                        } header: {
                            let baseName = group.first.map { $0.deletingPathExtension().lastPathComponent } ?? ""
                            Text(Locale.current.language.languageCode?.identifier == "ko"
                                 ? "그룹 \(groupIndex + 1) - \(baseName) (\(group.count)개)"
                                 : "Group \(groupIndex + 1) - \(baseName) (\(group.count) files)")
                        }
                    }
                }
            }
        }
        .padding()
    }
    
    // MARK: - Settings View
    
    @ViewBuilder
    private var settingsView: some View {
        let isKo = Locale.current.language.languageCode?.identifier == "ko"
        Form {
            Section(isKo ? "일반" : "General") {
                Stepper(value: $maxRecentCount, in: 1...100) {
                    HStack {
                        Text(isKo ? "최근 이력 저장 개수" : "Recent history limit")
                        Spacer()
                        Text("\(maxRecentCount)")
                            .foregroundColor(.secondary)
                    }
                }
                .onChange(of: maxRecentCount) { _, newValue in
                    if recentExecutedFiles.count > newValue {
                        recentExecutedFiles.removeLast(recentExecutedFiles.count - newValue)
                    }
                }
            }
            Section(isKo ? "플레이어" : "Player") {
                Stepper(value: $seekSeconds, in: 1...60) {
                    HStack {
                        Text(isKo ? "키보드 탐색 간격" : "Keyboard seek interval")
                        Spacer()
                        Text(isKo ? "\(seekSeconds)초" : "\(seekSeconds)s")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selectedSidebarItem) { item in
                Label(item.label, systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 180)
        } detail: {
            // 내부 플레이어 재생 중일 때 detail 전체를 비디오 플레이어로 채움
            if showingInternalPlayer, let file = lastExecutedFile {
                InternalVLCPlayerView(
                    fileURL: file,
                    title: file.lastPathComponent,
                    onNextRandom: {
                        guard let f = indexedFiles.randomElement() else { return }
                        execute(file: f)
                    },
                    onOpenExternal: selectedApp.map { app in
                        {
                            NSWorkspace.shared.open([file], withApplicationAt: app,
                                                   configuration: .init(), completionHandler: nil)
                        }
                    },
                    onClose: { showingInternalPlayer = false }
                )
            } else {
                switch selectedSidebarItem {
                case .player, .none:
                    playerView
                case .clean:
                    cleanView
                case .duplicates:
                    duplicatesView
                case .settings:
                    settingsView
                }
            }
        }
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

/// 비디오 트랙의 코덱·해상도·프레임레이트·비트레이트 정보
struct VideoInfo {
    let codec: String
    let resolution: CGSize
    let frameRate: Float
    let bitrateMbps: Double

    var summary: String {
        var parts = [codec]
        if resolution != .zero {
            parts.append("\(Int(resolution.width))×\(Int(resolution.height))")
        }
        if bitrateMbps > 0 {
            parts.append(String(format: "%.1f Mbps", bitrateMbps))
        }
        return parts.joined(separator: " · ")
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [ExtensionItem.self, DirectoryBookmark.self], inMemory: true)
}

