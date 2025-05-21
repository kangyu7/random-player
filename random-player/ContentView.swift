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
    
    @State private var customExtension = ""
    @State private var selectedDirectories: [URL] = []
    @State private var indexedFiles: [URL] = []
    @State private var selectedApp: URL? = nil
    @State private var lastExecutedFile: URL?
    @State private var showDeleteConfirmation = false
    @State private var isIndexing = false
    @State private var deleteStatus: (message: String, isSuccess: Bool)? = nil
    
    @AppStorage("selectedAppPath") private var selectedAppPath: String = ""

    var body: some View {
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
                    guard let app = selectedApp else { return }
                    guard let file = indexedFiles.randomElement() else { return }
                    NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                    lastExecutedFile = file
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
            }
            
            List {
                ForEach(extensionItems, id: \.self) { extItem in
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
            
            Button("Add Path") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = true

                if panel.runModal() == .OK {
                    selectedDirectories.append(contentsOf: panel.urls)
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
                                }
                            } label: {
                                Label("delete", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(.bottom, 10)
        }
        .padding()
        .onAppear {
            let path = selectedAppPath
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                selectedApp = url
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [ExtensionItem.self], inMemory: true)
}
