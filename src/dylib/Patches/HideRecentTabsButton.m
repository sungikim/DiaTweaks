#import "../DiaPatches.h"

static NSColor *DPPink(void) { return NSColor.systemPinkColor; }

DPPatch DPHideRecentTabsButton = {
    .key = @"hideRecentTabsButton",
    .title = @"Hide recent tabs button",
    .detail = @"Hide the recent tabs button in the tab bar or sidebar.",
    .symbol = @"clock.arrow.circlepath",
    .tint = DPPink,
    .classes = DPClasses("_TtC10TabSidebar26SidebarContainerFooterView", "_TtC8TabStrip31TabStripContainerViewController"),
    .apply = DPApplyButtons,
    .verify = DPVerifyButtons,
};
