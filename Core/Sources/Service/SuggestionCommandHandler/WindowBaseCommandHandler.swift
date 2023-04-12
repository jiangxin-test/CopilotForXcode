import ChatService
import CopilotModel
import CopilotService
import Environment
import Foundation
import LanguageServerProtocol
import Logger
import OpenAIService
import SuggestionInjector
import SuggestionWidget
import XPCShared

@ServiceActor
struct WindowBaseCommandHandler: SuggestionCommandHandler {
    nonisolated init() {}

    let presenter = PresentInWindowSuggestionPresenter()

    func presentSuggestions(editor: EditorContent) async throws -> UpdatedContent? {
        Task {
            do {
                try await _presentSuggestions(editor: editor)
            } catch let error as ServerError {
                Logger.service.error(error)
            } catch {
                presenter.presentError(error)
                Logger.service.error(error)
            }
        }
        return nil
    }

    private func _presentSuggestions(editor: EditorContent) async throws {
        presenter.markAsProcessing(true)
        defer {
            presenter.markAsProcessing(false)
        }
        let fileURL = try await Environment.fetchCurrentFileURL()
        let (workspace, filespace) = try await Workspace
            .fetchOrCreateWorkspaceIfNeeded(fileURL: fileURL)

        try Task.checkCancellation()

        let snapshot = Filespace.Snapshot(
            linesHash: editor.lines.hashValue,
            cursorPosition: editor.cursorPosition
        )

        // There is no need to regenerate suggestions for the same editor content.
        guard filespace.suggestionSourceSnapshot != snapshot else { return }

        try await workspace.generateSuggestions(
            forFileAt: fileURL,
            editor: editor
        )

        if filespace.presentingSuggestion != nil {
            presenter.presentSuggestion(fileURL: fileURL)
        } else {
            presenter.discardSuggestion(fileURL: fileURL)
        }
    }

    func presentNextSuggestion(editor: EditorContent) async throws -> UpdatedContent? {
        Task {
            do {
                try await _presentNextSuggestion(editor: editor)
            } catch {
                presenter.presentError(error)
            }
        }
        return nil
    }

    private func _presentNextSuggestion(editor: EditorContent) async throws {
        presenter.markAsProcessing(true)
        defer { presenter.markAsProcessing(false) }
        let fileURL = try await Environment.fetchCurrentFileURL()
        let (workspace, filespace) = try await Workspace
            .fetchOrCreateWorkspaceIfNeeded(fileURL: fileURL)
        workspace.selectNextSuggestion(forFileAt: fileURL)

        if filespace.presentingSuggestion != nil {
            presenter.presentSuggestion(fileURL: fileURL)
        } else {
            presenter.discardSuggestion(fileURL: fileURL)
        }
    }

    func presentPreviousSuggestion(editor: EditorContent) async throws -> UpdatedContent? {
        Task {
            do {
                try await _presentPreviousSuggestion(editor: editor)
            } catch {
                presenter.presentError(error)
            }
        }
        return nil
    }

    private func _presentPreviousSuggestion(editor: EditorContent) async throws {
        presenter.markAsProcessing(true)
        defer { presenter.markAsProcessing(false) }
        let fileURL = try await Environment.fetchCurrentFileURL()
        let (workspace, filespace) = try await Workspace
            .fetchOrCreateWorkspaceIfNeeded(fileURL: fileURL)
        workspace.selectPreviousSuggestion(forFileAt: fileURL)

        if filespace.presentingSuggestion != nil {
            presenter.presentSuggestion(fileURL: fileURL)
        } else {
            presenter.discardSuggestion(fileURL: fileURL)
        }
    }

    func rejectSuggestion(editor: EditorContent) async throws -> UpdatedContent? {
        Task {
            do {
                try await _rejectSuggestion(editor: editor)
            } catch {
                presenter.presentError(error)
            }
        }
        return nil
    }

    private func _rejectSuggestion(editor: EditorContent) async throws {
        presenter.markAsProcessing(true)
        defer { presenter.markAsProcessing(false) }
        let fileURL = try await Environment.fetchCurrentFileURL()
        let (workspace, _) = try await Workspace.fetchOrCreateWorkspaceIfNeeded(fileURL: fileURL)
        workspace.rejectSuggestion(forFileAt: fileURL, editor: editor)
        presenter.discardSuggestion(fileURL: fileURL)
    }

    func acceptSuggestion(editor: EditorContent) async throws -> UpdatedContent? {
        presenter.markAsProcessing(true)
        defer { presenter.markAsProcessing(false) }

        do {
            let result = try await CommentBaseCommandHandler().acceptSuggestion(editor: editor)
            Task {
                let fileURL = try await Environment.fetchCurrentFileURL()
                presenter.discardSuggestion(fileURL: fileURL)
            }
            return result
        } catch {
            presenter.presentError(error)
            throw error
        }
    }

    func presentRealtimeSuggestions(editor: EditorContent) async throws -> UpdatedContent? {
        Task {
            try? await prepareCache(editor: editor)
        }
        return nil
    }

    func prepareCache(editor: EditorContent) async throws -> UpdatedContent? {
        let fileURL = try await Environment.fetchCurrentFileURL()
        let (_, filespace) = try await Workspace
            .fetchOrCreateWorkspaceIfNeeded(fileURL: fileURL)
        filespace.uti = editor.uti
        filespace.tabSize = editor.tabSize
        filespace.indentSize = editor.indentSize
        filespace.usesTabsForIndentation = editor.usesTabsForIndentation
        return nil
    }

    func generateRealtimeSuggestions(editor: EditorContent) async throws -> UpdatedContent? {
        return try await presentSuggestions(editor: editor)
    }

    func explainSelection(editor: EditorContent) async throws -> UpdatedContent? {
        Task {
            do {
                try await _explainSelection(editor: editor)
            } catch {
                presenter.presentError(error)
            }
        }
        return nil
    }

    private func _explainSelection(editor: EditorContent) async throws {
        presenter.markAsProcessing(true)
        defer { presenter.markAsProcessing(false) }

        let fileURL = try await Environment.fetchCurrentFileURL()
        let language = UserDefaults.shared.value(for: \.chatGPTLanguage)
        let codeLanguage = languageIdentifierFromFileURL(fileURL)
        guard let selection = editor.selections.last else { return }

        let chat = WidgetDataSource.shared.createChatIfNeeded(for: fileURL)

        await chat.mutateSystemPrompt(
            """
            \(language.isEmpty ? "" : "You must always reply in \(language)")
            You are a code explanation engine, you can only explain the code concisely, do not interpret or translate it.
            """
        )

        let code = editor.selectedCode(in: selection)
        Task {
            try? await chat.chatGPTService.send(
                content: """
                ```\(codeLanguage.rawValue)
                \(code)
                ```
                """,
                summary: "Explain selected code in `\(fileURL.lastPathComponent)` from `\(selection.start.line + 1):\(selection.start.character + 1)` to `\(selection.end.line + 1):\(selection.end.character + 1)`."
            )
        }

        presenter.presentChatRoom(fileURL: fileURL)
    }

    func chatWithSelection(editor: EditorContent) async throws -> UpdatedContent? {
        Task {
            do {
                try await _chatWithSelection(editor: editor)
            } catch {
                presenter.presentError(error)
            }
        }
        return nil
    }

    private func _chatWithSelection(editor: EditorContent) async throws {
        presenter.markAsProcessing(true)
        defer { presenter.markAsProcessing(false) }

        let fileURL = try await Environment.fetchCurrentFileURL()
        let language = UserDefaults.shared.value(for: \.chatGPTLanguage)
        let codeLanguage = languageIdentifierFromFileURL(fileURL)

        let code = {
            guard let selection = editor.selections.last,
                  selection.start != selection.end else { return "" }
            return editor.selectedCode(in: selection)
        }()

        let prompt = {
            if code.isEmpty {
                return """
                \(language.isEmpty ? "" : "You must always reply in \(language)")
                You are a senior programmer, you will answer my questions concisely. If you are replying with code, embed the code in a code block in markdown.
                """
            }
            return """
            \(language.isEmpty ? "" : "You must always reply in \(language)")
            You are a senior programmer, you will answer my questions concisely about the code below, or modify it according to my requests. When you receive a modification request, reply with the modified code in a code block.
            ```\(codeLanguage.rawValue)
            \(code)
            ```
            """
        }()

        let chat = WidgetDataSource.shared.createChatIfNeeded(for: fileURL)

        await chat.mutateSystemPrompt(prompt)

        Task {
            if !code.isEmpty, let selection = editor.selections.last {
                await chat.chatGPTService.mutateHistory { history in
                    history.append(.init(
                        role: .user,
                        content: "",
                        summary: "Chat about selected code in `\(fileURL.lastPathComponent)` from `\(selection.start.line + 1):\(selection.start.character + 1)` to `\(selection.end.line + 1):\(selection.end.character)`.\nThe code will persist in the conversation."
                    ))
                }
            }
        }

        presenter.presentChatRoom(fileURL: fileURL)
    }
}