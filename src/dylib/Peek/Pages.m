#import "Peek.h"
#import <objc/message.h>

static NSMapTable *DPPeekFactories;
static NSMapTable<NSWindow *, id> *DPPeekBrowsers;
static __weak id DPPeekLastFactory;
static id DPPeekWarmPage;
static NSView *DPPeekWarmView;
static NSURL *DPPeekWarmURL;

static void DPPeekRemember(id factory, id page) {
    if (!page) return;
    [DPPeekFactories setObject:factory forKey:page];
    DPPeekLastFactory = factory;
}

static id DPContext_create(id self, SEL _cmd, id configuration) {
    id page = DPCallOriginal(DPContext_create, self, configuration);
    DPPeekRemember(self, page);
    return page;
}

static id DPBrowser_create(id self, SEL _cmd, id configuration) {
    id page = DPCallOriginal(DPBrowser_create, self, configuration);
    DPPeekRemember(self, page);
    return page;
}

static void DPBrowser_setWindow(id self, SEL _cmd, NSWindow *window) {
    DPCallOriginal(DPBrowser_setWindow, self, window);
    if (window) [DPPeekBrowsers setObject:self forKey:window];
}

static void DPPage_attach(id self, SEL _cmd, NSView *host) {
    for (NSWindow *window in NSApp.windows) {
        DPPeekCard *peek = (DPPeekCard *)DPFindView(window.contentView, ^BOOL(NSView *view) {
            return [view isKindOfClass:DPPeekCard.class] && ((DPPeekCard *)view).page == self;
        });
        if (peek && host != peek.host) [peek handOver];
    }
    DPCallOriginal(DPPage_attach, self, host);
}

// Restored tabs' pages skip the hooked createWebContents, so they fall back to the window's browser.
static id DPPeekFactoryFor(id source, NSWindow *window) {
    if (!source) return nil;
    return [DPPeekFactories objectForKey:source] ?: (window ? [DPPeekBrowsers objectForKey:window] : nil) ?: DPPeekLastFactory;
}

BOOL DPPeekCanOpen(id source) { return DPPeekFactoryFor(source, NSApp.keyWindow) != nil; }

BOOL DPPeekShows(id page) {
    if (!page) return NO;
    for (NSWindow *window in NSApp.windows) if (DPPeekCardIn(window).page == page) return YES;
    return NO;
}

void DPPeekLoad(id page, NSURL *url) {
    id navigation = [(NSObject *)page valueForKey:@"navigationController"];
    SEL load = @selector(load:initiatorOrigin:);
    if (url && [navigation respondsToSelector:load]) ((id (*)(id, SEL, NSURL *, NSURL *))objc_msgSend)(navigation, load, url, nil);
}

static BOOL DPPeekGive(id page, id delegate, id source, NSURL *url, DPPeekExit exit) {
    SEL adopt = @selector(webContents:didCreateNewWebContent:targetURL:disposition:);
    if (!page || !source || ![url isKindOfClass:NSURL.class] || ![delegate respondsToSelector:adopt]) return NO;
    NSInteger disposition = exit == DPPeekSplit ? DPSplitView : DPForegroundTab;
    ((void (*)(id, SEL, id, id, NSURL *, NSInteger))objc_msgSend)(delegate, adopt, source, page, url, disposition);
    return YES;
}

static void DPPeekDetach(id page, NSView *host) {
    if (!host) return;
    [page detachFromPaneHostView:host];
    [host removeFromSuperview];
}

// Some extensions crash Dia when a page closes while still showing a site, so it goes blank first.
static void DPPeekCloseWhenBlank(id page, int checks) {
    if (checks && ![[[(NSObject *)page valueForKey:@"url"] absoluteString] isEqual:@"about:blank"])
        return (void)dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ DPPeekCloseWhenBlank(page, checks - 1); });
    [page performSelector:@selector(close)];
}

static void DPPeekDiscard(id page, NSView *host) {
    DPPeekDetach(page, host);
    DPPeekLoad(page, [NSURL URLWithString:@"about:blank"]);
    DPPeekCloseWhenBlank(page, 40);
}

static void DPPeekFindLink(NSWindow *window, id source, NSPoint origin, NSView *warmHost, void (^found)(NSRect link)) {
    NSRect fallback = NSMakeRect(origin.x - 40, origin.y - 10, 80, 20);
    NSPoint inWindow = [window convertPointFromScreen:origin];
    NSView *web = DPFindView(window.contentView, ^BOOL(NSView *view) {
        return DPIsKind(view, "WebContentsHostView") && !view.isHiddenOrHasHiddenAncestor && ![view isDescendantOf:warmHost]
            && NSPointInRect([view convertPoint:inWindow fromView:nil], view.bounds);
    });
    if (!web || ![source respondsToSelector:@selector(executeJavascript:completion:)]) return found(fallback);
    NSPoint point = [web convertPoint:inWindow fromView:nil];
    NSString *script = [NSString stringWithFormat:@"(function(x, y, w) {"
        "var k = innerWidth / w, e = document.elementFromPoint(x * k, y * k); if (!e) return '';"
        "var a = e.closest('a') || e, r = a.getBoundingClientRect();"
        "for (var b of a.getClientRects()) if (x * k >= b.left && x * k <= b.right && y * k >= b.top && y * k <= b.bottom) r = b;"
        "return [r.left / k - x, r.top / k - y, r.width / k, r.height / k].join(',');"
        "})(%f, %f, %f)", point.x, web.isFlipped ? point.y : NSHeight(web.bounds) - point.y, NSWidth(web.bounds)];
    __block BOOL done = NO;
    void (^finish)(NSRect) = ^(NSRect link) {
        if (done) return;
        done = YES;
        found(link);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ finish(fallback); });
    void (^answer)(NSString *, BOOL) = ^(NSString *result, BOOL ok) {
        NSString *box = [result stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];  // JSON-quoted
        NSArray<NSString *> *parts = [box componentsSeparatedByString:@","];
        NSRect link = fallback;
        if (ok && parts.count == 4 && parts[2].doubleValue >= 1 && parts[3].doubleValue >= 1) {
            CGFloat dx = parts[0].doubleValue, dy = parts[1].doubleValue, w = parts[2].doubleValue, h = parts[3].doubleValue;
            link = NSMakeRect(origin.x + dx, origin.y - dy - h, w, h);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ finish(link); });
    };
    ((void (*)(id, SEL, NSString *, id))objc_msgSend)(source, @selector(executeJavascript:completion:), script, answer);
}

static id DPPeekMakePage(NSWindow *window, id source, void (^attach)(id page)) {
    id factory = DPPeekFactoryFor(source, window);
    Class configuration = objc_getClass(DPDiaWebContentsConfiguration);
    if (!window || !factory || !configuration) return nil;
    id page = ((id (*)(id, SEL, id))objc_msgSend)(factory, @selector(createWebContents:), [configuration new]);
    if (!page) return nil;
    if ([page respondsToSelector:@selector(bootstrapRendering)]) [page performSelector:@selector(bootstrapRendering)];
    attach(page);
    if ([page respondsToSelector:@selector(bootstrapRenderingComplete)]) [page performSelector:@selector(bootstrapRenderingComplete)];
    return page;
}

void DPPeekWarm(NSWindow *window, id source, NSURL *url) {
    if ([url isEqual:DPPeekWarmURL] || DPPeekCardIn(window)) return;
    DPPeekCool();
    __block NSView *host = nil;
    id page = DPPeekMakePage(window, source, ^(id page) { host = DPPeekWarmHost(window, page); });
    if (!page) return;
    if (!host) return DPPeekDiscard(page, nil);
    DPPeekLoad(page, url);
    DPPeekWarmPage = page;
    DPPeekWarmView = host;
    DPPeekWarmURL = url;
}

static void DPPeekForgetWarm(void) {
    DPPeekWarmPage = nil;
    DPPeekWarmView = nil;
    DPPeekWarmURL = nil;
}

void DPPeekCool(void) {
    if (!DPPeekWarmPage) return;
    DPPeekDiscard(DPPeekWarmPage, DPPeekWarmView);
    DPPeekForgetWarm();
}

static void DPPeekOpenFrom(NSWindow *window, NSURL *url, NSRect link, id delegate, id source, id warmPage, NSView *warmHost) {
    if (!window || !url || DPPeekCardIn(window)) {
        if (warmPage) DPPeekDiscard(warmPage, warmHost);
        return;
    }
    __block DPPeekCard *peek = nil;
    id page = warmPage ?: DPPeekMakePage(window, source, ^(id page) { peek = DPPeekShowCard(window, page, nil, link); });
    if (!page) return;
    if (warmPage) peek = DPPeekShowCard(window, page, warmHost, link);
    else DPPeekLoad(page, url);
    if (!peek) {
        DPPeekDetach(page, warmHost);
        DPPeekGive(page, delegate, source, url, DPPeekTab);
        return;
    }
    peek.sourceDelegate = delegate;
    peek.source = source;
}

void DPPeekOpen(NSWindow *window, NSURL *url, NSPoint origin, id delegate, id source) {
    // Taken now, before releasing Shift can cool it.
    BOOL warm = DPPeekWarmPage && [url isEqual:DPPeekWarmURL] && DPPeekWarmView.window == window;
    id warmPage = warm ? DPPeekWarmPage : nil;
    NSView *warmHost = warm ? DPPeekWarmView : nil;
    if (warm) DPPeekForgetWarm();
    DPPeekCool();
    DPPeekFindLink(window, source, origin, warmHost, ^(NSRect link) { DPPeekOpenFrom(window, url, link, delegate, source, warmPage, warmHost); });
}

@implementation DPPeekCard (Handoff)

- (void)finish:(DPPeekExit)exit {
    NSObject *page = (NSObject *)self.page;
    [self.window makeKeyWindow];
    if (exit != DPPeekClose && DPPeekGive(page, self.sourceDelegate, self.source, [page valueForKey:@"url"], exit)) {
        // DPPage_attach takes the card down once Dia shows the page.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ if (self.superview) [self handOver]; });
        return;
    }
    [self handOver];
    DPPeekDiscard(page, nil);
}

@end

void DPPeekInstallPages(void) {
    DPPeekFactories = [NSMapTable weakToWeakObjectsMapTable];
    DPPeekBrowsers = [NSMapTable weakToWeakObjectsMapTable];
    DPHook(DPDiaBrowser, @selector(setWindow:), (IMP)DPBrowser_setWindow);
    DPHook(DPDiaBrowserContext, @selector(createWebContents:), (IMP)DPContext_create);
    DPHook(DPDiaBrowser, @selector(createWebContents:), (IMP)DPBrowser_create);
    DPHook(DPDiaWebContents, @selector(attachToPaneHostView:), (IMP)DPPage_attach);
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        [DPPeekCardIn(note.object) close:DPPeekClose];
    }];
}
