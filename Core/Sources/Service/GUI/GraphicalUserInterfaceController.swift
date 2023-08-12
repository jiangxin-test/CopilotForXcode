import AppKit
import ChatGPTChatTab
import ChatTab
import ComposableArchitecture
import Dependencies
import Environment
import Preferences
import SuggestionWidget

struct GUI: ReducerProtocol {
    struct State: Equatable {
        var suggestionWidgetState = WidgetFeature.State()

        var chatTabGroup: ChatPanelFeature.ChatTabGroup {
            get { suggestionWidgetState.chatPanelState.chatTapGroup }
            set { suggestionWidgetState.chatPanelState.chatTapGroup = newValue }
        }
    }

    enum Action {
        case openChatPanel(forceDetach: Bool)
        case createChatGPTChatTabIfNeeded
        case sendCustomCommandToActiveChat(CustomCommand)

        case suggestionWidget(WidgetFeature.Action)
    }

    @Dependency(\.chatTabPool) var chatTabPool: ChatTabPool

    var body: some ReducerProtocol<State, Action> {
        Scope(state: \.suggestionWidgetState, action: /Action.suggestionWidget) {
            WidgetFeature()
        }

        Scope(
            state: \.chatTabGroup,
            action: /Action.suggestionWidget .. /WidgetFeature.Action.chatPanel
        ) {
            Reduce { _, action in
                switch action {
                case let .createNewTapButtonClicked(kind):
                    return .run { send in
                        if let (_, chatTabInfo) = await chatTabPool.createTab(for: kind) {
                            await send(.appendAndSelectTab(chatTabInfo))
                        }
                    }

                case let .closeTabButtonClicked(id):
                    return .run { _ in
                        chatTabPool.removeTab(of: id)
                    }

                case let .chatTab(_, .openNewTab(builder)):
                    return .run { send in
                        if let (_, chatTabInfo) = await chatTabPool
                            .createTab(from: builder.chatTabBuilder)
                        {
                            await send(.appendAndSelectTab(chatTabInfo))
                        }
                    }

                default:
                    return .none
                }
            }
        }

        Reduce { state, action in
            switch action {
            case let .openChatPanel(forceDetach):
                return .run { send in
                    await send(
                        .suggestionWidget(.chatPanel(.presentChatPanel(forceDetach: forceDetach)))
                    )
                }

            case .createChatGPTChatTabIfNeeded:
                if state.chatTabGroup.tabInfo.contains(where: {
                    chatTabPool.getTab(of: $0.id) is ChatGPTChatTab
                }) {
                    return .none
                }
                return .run { send in
                    if let (_, chatTabInfo) = await chatTabPool.createTab(for: nil) {
                        await send(.suggestionWidget(.chatPanel(.appendAndSelectTab(chatTabInfo))))
                    }
                }

            case let .sendCustomCommandToActiveChat(command):
                @Sendable func stopAndHandleCommand(_ tab: ChatGPTChatTab) async {
                    if tab.service.isReceivingMessage {
                        await tab.service.stopReceivingMessage()
                    }
                    try? await tab.service.handleCustomCommand(command)
                }

                if let info = state.chatTabGroup.selectedTabInfo,
                   let activeTab = chatTabPool.getTab(of: info.id) as? ChatGPTChatTab
                {
                    return .run { send in
                        await send(.openChatPanel(forceDetach: false))
                        await stopAndHandleCommand(activeTab)
                    }
                }

                if let info = state.chatTabGroup.tabInfo.first(where: {
                    chatTabPool.getTab(of: $0.id) is ChatGPTChatTab
                }),
                    let chatTab = chatTabPool.getTab(of: info.id) as? ChatGPTChatTab
                {
                    state.chatTabGroup.selectedTabId = chatTab.id
                    return .run { send in
                        await send(.openChatPanel(forceDetach: false))
                        await stopAndHandleCommand(chatTab)
                    }
                }

                return .run { send in
                    guard let (chatTab, chatTabInfo) = await chatTabPool.createTab(for: nil) else {
                        return
                    }
                    await send(.suggestionWidget(.chatPanel(.appendAndSelectTab(chatTabInfo))))
                    await send(.openChatPanel(forceDetach: false))
                    if let chatTab = chatTab as? ChatGPTChatTab {
                        await stopAndHandleCommand(chatTab)
                    }
                }

            case .suggestionWidget:
                return .none
            }
        }
    }
}

@MainActor
public final class GraphicalUserInterfaceController {
    public static let shared = GraphicalUserInterfaceController()
    private let store: StoreOf<GUI>
    let widgetController: SuggestionWidgetController
    let widgetDataSource: WidgetDataSource
    let viewStore: ViewStoreOf<GUI>
    let chatTabPool: ChatTabPool

    class WeakStoreHolder {
        weak var store: StoreOf<GUI>?
    }

    private init() {
        let chatTabPool = ChatTabPool()
        let suggestionDependency = SuggestionWidgetControllerDependency()
        let setupDependency: (inout DependencyValues) -> Void = { dependencies in
            dependencies.suggestionWidgetControllerDependency = suggestionDependency
            dependencies.suggestionWidgetUserDefaultsObservers = .init()
            dependencies.chatTabPool = chatTabPool
            dependencies.chatTabBuilderCollection = ChatTabFactory.chatTabBuilderCollection
        }
        let store = StoreOf<GUI>(
            initialState: .init(),
            reducer: GUI(),
            prepareDependencies: setupDependency
        )
        self.store = store
        self.chatTabPool = chatTabPool
        viewStore = ViewStore(store)
        widgetDataSource = .init()

        widgetController = SuggestionWidgetController(
            store: store.scope(
                state: \.suggestionWidgetState,
                action: GUI.Action.suggestionWidget
            ),
            chatTabPool: chatTabPool,
            dependency: suggestionDependency
        )

        chatTabPool.createStore = { id in
            store.scope(
                state: { state in
                    state.chatTabGroup.tabInfo[id: id]
                        ?? .init(id: id, title: "")
                },
                action: { childAction in
                    .suggestionWidget(.chatPanel(.chatTab(id: id, action: childAction)))
                }
            )
        }

        suggestionDependency.suggestionWidgetDataSource = widgetDataSource
        suggestionDependency.onOpenChatClicked = { [weak self] in
            Task { [weak self] in
                await self?.viewStore.send(.createChatGPTChatTabIfNeeded).finish()
                self?.viewStore.send(.openChatPanel(forceDetach: false))
            }
        }
        suggestionDependency.onCustomCommandClicked = { command in
            Task {
                let commandHandler = PseudoCommandHandler()
                await commandHandler.handleCustomCommand(command)
            }
        }
    }

    public func openGlobalChat() {
        Task {
            await self.viewStore.send(.createChatGPTChatTabIfNeeded).finish()
            viewStore.send(.openChatPanel(forceDetach: true))
        }
    }
}

extension ChatTabPool {
    @MainActor
    func createTab(
        from builder: ChatTabBuilder
    ) -> (any ChatTab, ChatTabInfo)? {
        let id = UUID().uuidString
        let info = ChatTabInfo(id: id, title: "")
        guard builder.buildable else { return nil }
        let chatTap = builder.build(store: createStore(id))
        setTab(chatTap)
        return (chatTap, info)
    }

    @MainActor
    func createTab(
        for kind: ChatTabKind?
    ) -> (any ChatTab, ChatTabInfo)? {
        let id = UUID().uuidString
        let info = ChatTabInfo(id: id, title: "")
        guard let builder = kind?.builder else {
            let chatTap = ChatGPTChatTab(store: createStore(id))
            setTab(chatTap)
            return (chatTap, info)
        }
        guard builder.buildable else { return nil }
        let chatTap = builder.build(store: createStore(id))
        setTab(chatTap)
        return (chatTap, info)
    }
}

