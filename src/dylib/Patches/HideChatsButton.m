#import "../DiaPatches.h"

static NSColor *DPTeal(void) { return NSColor.systemTealColor; }

DPPatch DPHideChatsButton = {
    .key = @"hideChatsButton",
    .title = @"Hide Chats button",
    .detail = @"Hide the Chats button in the tab bar or sidebar.",
    .symbol = @"doc.plaintext",
    .tint = DPTeal,
    .classes = DPClasses("_TtC10DiaLibrary17LibraryButtonView", "_TtC10TabSidebar15LibraryCellView"),
    .apply = DPApplyButtons,
    .verify = DPVerifyButtons,
};
