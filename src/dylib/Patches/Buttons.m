#import "../DiaPatches.h"

static NSHashTable<NSView *> *DPBars, *DPSuppressed;
static char DPButtonKey, DPCollapsedKey;

static BOOL DPIsKind(NSView *view, NSString *className) {
    Class cls = NSClassFromString(className);
    return cls && [view isKindOfClass:cls];
}

static DPPatch *DPButtonPatch(NSView *view) {
    NSValue *patch = objc_getAssociatedObject(view, &DPButtonKey);
    if (patch) return patch.pointerValue;
    NSString *label = view.accessibilityLabel;
    DPPatch *match = [label isEqualToString:@"Chat with this tab"]                ? &DPHideChatButton
                   : [label isEqualToString:@"Toggle sidebar"]                    ? &DPHideSidebarButton
                   : [label isEqualToString:@"Recent tabs"]                       ? &DPHideRecentTabsButton
                   : DPIsKind(view, @"_TtC10DiaLibrary17LibraryButtonView")       ? &DPHideChatsButton
                   : DPIsKind(view, @"_TtC10TabSidebar15LibraryCellView")         ? &DPHideChatsButton
                                                                                  : NULL;
    if (match) objc_setAssociatedObject(view, &DPButtonKey, [NSValue valueWithPointer:match], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return match;
}

static void DPButton_setHidden(NSView *self, SEL _cmd, BOOL hidden) {
    DPPatch *patch = DPButtonPatch(self);
    BOOL suppress = !hidden && patch && patch->on;
    if (suppress) [DPSuppressed addObject:self];
    else [DPSuppressed removeObject:self];
    DPCallOriginal(void (*)(id, SEL, BOOL), self, _cmd, hidden || suppress);
}

static void DPEnforceButton(NSView *view) {
    DPPatch *patch = DPButtonPatch(view);
    if (!patch) return;
    DPHook(view.class, @selector(setHidden:), DPButton_setHidden);
    if (!patch->on || view.hidden) return;
    // As if Dia showed it again: the hook hides it and remembers to restore it.
    DPButton_setHidden(view, @selector(setHidden:), NO);
}

static void DPButton_viewDidMoveToWindow(NSView *self, SEL _cmd) {
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
    DPEnforceButton(self);
}

static BOOL DPEnforceButtons(NSView *view) {
    if (DPButtonPatch(view)) {
        DPHook(view.class, @selector(viewDidMoveToWindow), DPButton_viewDidMoveToWindow);
        BOOL wasHidden = view.hidden;
        DPEnforceButton(view);
        return view.hidden != wasHidden;
    }
    BOOL changed = NO;
    for (NSView *sub in view.subviews) changed |= DPEnforceButtons(sub);
    return changed;
}

static void DPBar_layout(NSView *self, SEL _cmd) {
    [DPBars addObject:self];
    DPEnforceButtons(self);
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
}

static void DPRelayoutBars(void) {
    for (NSView *bar in DPBars.allObjects) {
        bar.needsLayout = YES;
        [bar layoutSubtreeIfNeeded];
    }
}

// With everything in the sidebar footer hidden, the view above it grows over the footer's space.
static void DPSidebar_viewDidLayout(NSViewController *self, SEL _cmd) {
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
    NSView *sidebar = self.view, *footer = nil;
    [DPBars addObject:sidebar];
    for (NSView *sub in sidebar.subviews) if (DPIsKind(sub, @"_TtC10TabSidebar26SidebarContainerFooterView")) footer = sub;
    if (!footer || !sidebar.isFlipped) return;
    DPEnforceButtons(footer);
    BOOL empty = DPHideChatsButton.on && DPHideRecentTabsButton.on;
    for (NSView *item in footer.subviews) empty &= item.hidden;
    NSHashTable<NSView *> *grown = objc_getAssociatedObject(footer, &DPCollapsedKey);
    if (empty) {
        if (!grown) objc_setAssociatedObject(footer, &DPCollapsedKey, grown = [NSHashTable weakObjectsHashTable], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        footer.hidden = YES;
        for (NSView *sub in sidebar.subviews) {
            if (sub == footer || fabs(NSMaxY(sub.frame) - NSMinY(footer.frame)) > 0.5) continue;
            [sub setFrameSize:NSMakeSize(NSWidth(sub.frame), NSMaxY(footer.frame) - NSMinY(sub.frame))];
            [grown addObject:sub];
        }
    } else if (grown) {
        objc_setAssociatedObject(footer, &DPCollapsedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        footer.hidden = NO;
        for (NSView *sub in grown)
            if (fabs(NSMaxY(sub.frame) - NSMaxY(footer.frame)) < 0.5)
                [sub setFrameSize:NSMakeSize(NSWidth(sub.frame), NSMinY(footer.frame) - NSMinY(sub.frame))];
    }
}

// The tab strip's Chats and recent tabs buttons sit directly in its root view, beside the tabs.
static void DPTabStrip_viewWillLayout(NSViewController *self, SEL _cmd) {
    [DPBars addObject:self.view];
    for (NSView *sub in self.view.subviews) if (DPButtonPatch(sub)) DPEnforceButtons(sub);
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
}

static void DPRestoreButtons(DPPatch *patch) {
    for (NSView *view in DPSuppressed.allObjects)
        if (DPButtonPatch(view) == patch) view.hidden = NO;
}

void DPApplyButtons(DPPatch *patch) {
    if (patch->on) for (NSView *bar in DPBars.allObjects) DPEnforceButtons(bar);
    else DPRestoreButtons(patch);
    DPRelayoutBars();
}

void DPInstallButtons(void) {
    DPBars = [NSHashTable weakObjectsHashTable];
    DPSuppressed = [NSHashTable weakObjectsHashTable];
    for (NSString *bar in @[@"_TtC13NavigationBar17NavigationBarView", @"_TtC10TabSidebar17SidebarHeaderView", @"_TtC10TabSidebar26SidebarContainerFooterView"])
        DPHook(NSClassFromString(bar), @selector(layout), DPBar_layout);
    DPHook(NSClassFromString(@"_TtC10TabSidebar30SidebarContainerViewController"), @selector(viewDidLayout), DPSidebar_viewDidLayout);
    DPHook(NSClassFromString(@"_TtC8TabStrip31TabStripContainerViewController"), @selector(viewWillLayout), DPTabStrip_viewWillLayout);
}
