#import "DiaPatches.h"

static const CFTimeInterval DPAnimationDuration = 0.25;

static NSUserDefaults *DPDefaults;

NSView *DPFindView(NSView *root, BOOL (^match)(NSView *)) {
    if (!root || match(root)) return root;
    for (NSView *sub in root.subviews) {
        NSView *found = DPFindView(sub, match);
        if (found) return found;
    }
    return nil;
}

static void DPCollectViews(NSView *view, Class cls, NSMutableArray<NSView *> *views) {
    if ([view isKindOfClass:cls]) [views addObject:view];
    for (NSView *sub in view.subviews) DPCollectViews(sub, cls, views);
}

NSArray<NSView *> *DPFindViews(Class cls) {
    NSMutableArray<NSView *> *views = [NSMutableArray new];
    for (NSWindow *window in NSApp.windows)
        if (cls && window.isVisible) DPCollectViews(window.contentView, cls, views);
    return views;
}

// Settings lists the patches in this order.
DPPatch *const DPPatches[] = {
    &DPEdgeToEdge,
    &DPSquareSidebarCorners,
    &DPHideToolbar,
    &DPRevealToolbarOnHover,
    &DPHideSidebarButton,
    &DPHideChatButton,
    &DPHideChatsButton,
    &DPHideRecentTabsButton,
};
const NSUInteger DPPatchCount = sizeof DPPatches / sizeof *DPPatches;

static void DPAnimate(void) {
    static NSTimer *timer;
    static CFTimeInterval start;
    static CGFloat from[sizeof DPPatches / sizeof *DPPatches];
    start = CACurrentMediaTime();
    for (NSUInteger i = 0; i < DPPatchCount; i++) from[i] = DPPatches[i]->progress;
    if (timer) return;
    timer = [NSTimer timerWithTimeInterval:1.0 / 120 repeats:YES block:^(NSTimer *t) {
        CGFloat elapsed = CACurrentMediaTime() - start, omega = 22;
        BOOL done = elapsed >= DPAnimationDuration * 2;
        CGFloat eased = done ? 1 : 1 - (1 + omega * elapsed) * exp(-omega * elapsed);
        for (NSUInteger i = 0; i < DPPatchCount; i++) DPPatches[i]->progress = from[i] + (DPPatches[i]->on - from[i]) * eased;
        for (NSUInteger i = 0; i < DPPatchCount; i++) if (DPPatches[i]->relayout) DPPatches[i]->relayout();
        if (done) {
            [t invalidate];
            timer = nil;
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

void DPSetPatch(DPPatch *patch, BOOL on) {
    if (patch->on == on) return;
    patch->on = on;
    [DPDefaults setBool:on forKey:patch->key];
    if (patch->apply) patch->apply(patch);
    else DPAnimate();
}

__attribute__((constructor)) static void DPInit(void) {
    DPBeginLaunch();
    if (DPSafeMode == 2) return;
    DPDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.diapatches"];
    for (NSUInteger i = 0; i < DPPatchCount; i++)
        for (const char *const *name = DPPatches[i]->classes; name && *name; name++) DPPatches[i]->unavailable |= !objc_getClass(*name);
    for (NSUInteger i = 0; i < DPPatchCount; i++) {
        DPPatch *patch = DPPatches[i];
        for (DPPatch *required = patch->requires; required; required = required->requires) patch->unavailable |= required->unavailable;
        id value = [DPDefaults objectForKey:patch->key];
        patch->on = !patch->unavailable && (value ? [value boolValue] : patch->defaultOn);
        patch->progress = patch->on;
    }

    if (!DPSafeMode) {
        for (NSUInteger i = 0; i < DPPatchCount; i++) if (!DPPatches[i]->unavailable && DPPatches[i]->install) DPPatches[i]->install();
        DPInstallButtons();
        DPInstallGroupTabs();
    }
    DPInstallSettings();

    DPInstallUpdates();
}
