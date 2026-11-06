#import "Peek.h"

static BOOL DPPeekOn;

// The Peek defaults' values: the upstream settings rows aren't ported.
double DPPeekDarkness(void) { return 0.45; }
double DPPeekResponse(void) { return 0.24 / 0.9; }
BOOL DPPeekGenie(void) { return YES; }

typedef struct { Class cls; SEL sel; IMP replacement, original; } DPHookRecord;
static DPHookRecord *DPHooks;
static size_t DPHookCount;

void DPHook(const char *className, SEL sel, IMP replacement) {
    Class cls = objc_getClass(className);
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!method) return (void)NSLog(@"[DiaPatches] Peek: can't hook -[%s %s]", className, sel_getName(sel));
    IMP original = method_getImplementation(method);
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method))) method_setImplementation(method, replacement);
    DPHooks = realloc(DPHooks, ++DPHookCount * sizeof *DPHooks);
    DPHooks[DPHookCount - 1] = (DPHookRecord){cls, sel, replacement, original};
}

IMP DPOriginalIMP(id object, SEL sel, IMP replacement) {
    for (Class c = object_getClass(object); c; c = class_getSuperclass(c))
        for (size_t i = 0; i < DPHookCount; i++)
            if (DPHooks[i].cls == c && DPHooks[i].sel == sel && DPHooks[i].replacement == replacement) return DPHooks[i].original;
    abort();
}

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

NSArray<NSView *> *DPFindViews(const char *className) {
    Class cls = objc_getClass(className);
    NSMutableArray<NSView *> *views = [NSMutableArray new];
    for (NSWindow *window in NSApp.windows)
        if (cls && window.isVisible) DPCollectViews(window.contentView, cls, views);
    return views;
}

BOOL DPIsKind(id object, const char *className) {
    Class cls = objc_getClass(className);
    return cls && [object isKindOfClass:cls];
}

id DPGet(id object, const void *key) { return objc_getAssociatedObject(object, key); }
void DPSet(id object, const void *key, id value) { objc_setAssociatedObject(object, key, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }

void DPPeekSetOn(BOOL on) { DPPeekOn = on; }
BOOL DPPeekShowingIn(NSWindow *window) { return DPPeekCardIn(window) != nil; }

static NSURL *DPPeekHovered;
static __weak id DPPeekHoveredPage;

static BOOL DPPeekWanted(NSInteger disposition) {
    BOOL elsewhere = disposition == DPForegroundTab || disposition == DPBackgroundTab || disposition == DPPopup || disposition == DPNewWindow;
    return DPPeekOn && elsewhere && (NSEvent.modifierFlags & NSEventModifierFlagShift);
}

static void DPPeekOpenLater(id delegate, id source, NSURL *url) {
    NSWindow *window = NSApp.keyWindow;
    NSPoint origin = NSEvent.mouseLocation;
    dispatch_async(dispatch_get_main_queue(), ^{ DPPeekOpen(window, url, origin, delegate, source); });
}

static void DPWebContent_didCreate(id self, SEL _cmd, id webContents, id newWebContent, NSURL *url, NSInteger disposition) {
    if (!DPPeekWanted(disposition) || !(DPPeekShows(webContents) || DPPeekCanOpen(webContents)))
        return (void)DPCallOriginal(DPWebContent_didCreate, self, webContents, newWebContent, url, disposition);
    DPCallOriginal(DPWebContent_didCreate, self, webContents, newWebContent, url, (NSInteger)DPIgnoreAction);
    if (DPPeekShows(webContents)) return DPPeekLoad(webContents, url);
    DPPeekOpenLater(self, webContents, url);
}

static NSInteger DPWebContent_decidePolicy(id self, SEL _cmd, id webContents, id action) {
    NSInteger disposition = [[action valueForKey:@"navigationDisposition"] integerValue];
    if (!DPPeekWanted(disposition)) return DPCallOriginal(DPWebContent_decidePolicy, self, webContents, action);
    if (DPPeekShows(webContents)) return DPCurrentTab;
    if (!DPPeekCanOpen(webContents)) return DPCallOriginal(DPWebContent_decidePolicy, self, webContents, action);
    DPPeekOpenLater(self, webContents, [action valueForKey:@"url"]);
    return DPIgnoreAction;
}

static void DPPeekLookAhead(void) {
    NSEventModifierFlags mods = NSEvent.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask & ~NSEventModifierFlagCapsLock;
    id page = DPPeekHoveredPage;
    if (DPPeekOn && mods == NSEventModifierFlagShift && DPPeekHovered && page && !DPPeekShows(page) && DPPeekCanOpen(page))
        DPPeekWarm(NSApp.keyWindow, page, DPPeekHovered);
    else DPPeekCool();
}

static void DPWebContent_status(id self, SEL _cmd, id webContents, NSString *text) {
    DPCallOriginal(DPWebContent_status, self, webContents, text);
    NSURL *url = text.length ? [NSURL URLWithString:text] : nil;
    if (!url && webContents != DPPeekHoveredPage) return;  // Other pages, the warm one included, clear their own.
    DPPeekHovered = [@[ @"http", @"https" ] containsObject:url.scheme.lowercaseString] ? url : nil;
    DPPeekHoveredPage = webContents;
        DPPeekLookAhead();
}

void DPPeekInstall(void) {
    DPPeekInstallPages();
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *_) {
        DPHook(DPDiaWebContent, @selector(webContents:didCreateNewWebContent:targetURL:disposition:), (IMP)DPWebContent_didCreate);
        DPHook(DPDiaWebContent, @selector(webContents:decidePolicyForNavigationAction:), (IMP)DPWebContent_decidePolicy);
        DPHook(DPDiaWebContent, @selector(webContents:didChangeStatusText:), (IMP)DPWebContent_status);
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^NSEvent *(NSEvent *event) {
            DPPeekLookAhead();
            return event;
        }];
    }];
}
