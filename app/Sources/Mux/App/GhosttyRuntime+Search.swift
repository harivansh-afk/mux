import GhosttyKit

/// Search notifications share the same surface routing as other core actions.
func searchAction(_ view: PaneView?, action: ghostty_action_s) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_START_SEARCH:
        let needle = action.action.start_search.needle.map { String(cString: $0) } ?? ""
        return onMain(view) { $0.scrollHost?.showSearch(needle: needle) }

    case GHOSTTY_ACTION_END_SEARCH:
        return onMain(view) { $0.scrollHost?.hideSearch() }

    case GHOSTTY_ACTION_SEARCH_TOTAL:
        let total = action.action.search_total.total
        return onMain(view) { $0.scrollHost?.searchBar.total = total }

    case GHOSTTY_ACTION_SEARCH_SELECTED:
        let selected = action.action.search_selected.selected
        return onMain(view) { $0.scrollHost?.searchBar.selected = selected }

    default:
        return false
    }
}
