module ApplicationHelper
  # Bottom navigation tab index for the current page; -1 = no active tab.
  NAV_TABS = { "home" => 0, "follows" => 1, "relays" => 2, "settings" => 3 }.freeze

  def nav_index
    NAV_TABS.fetch(controller_name, -1)
  end
end
