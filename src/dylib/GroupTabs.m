#import "DiaPatches.h"
#import <objc/message.h>

// Group Tabs by Domain is a one-shot command in the tab context menu and the Tabs menu. The hooks only remember
// live browsers and web contents so the command can read each tab's session ID; nothing is grouped until it's chosen.

static NSHashTable *DPTrackedContents, *DPBrowsers;
static NSMapTable *DPBrowserByContents, *DPDelegateByBrowser, *DPWindowByBrowser;
static char DPSessionKey;

static const NSInteger DPGroupMenuTag = 0xD1A7001;
static NSString *const DPGroupMenuTitle = @"Group Tabs by Domain";
static BOOL DPInserting;

static long long DPLongID(id value) {
    if (!value || value == NSNull.null) return 0;
    if ([value isKindOfClass:NSNumber.class]) return ((NSNumber *)value).longLongValue;
    if ([value isKindOfClass:NSString.class]) {
        NSScanner *scanner = [NSScanner scannerWithString:value];
        long long number = 0;
        return [scanner scanLongLong:&number] && [scanner isAtEnd] ? number : 0;
    }
    if ([value respondsToSelector:@selector(identifier)]) {
        NSInteger (*msg)(id, SEL) = (void *)objc_msgSend;
        return msg(value, @selector(identifier));
    }
    return 0;
}

static id DPMsg(id object, SEL sel) {
    id (*msg)(id, SEL) = (void *)objc_msgSend;
    return object ? msg(object, sel) : nil;
}

static BOOL DPMsgBool(id object, SEL sel) {
    BOOL (*msg)(id, SEL) = (void *)objc_msgSend;
    return object ? msg(object, sel) : NO;
}

static NSString *DPText(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSURL.class]) return ((NSURL *)value).absoluteString;
    if ([value isKindOfClass:NSNumber.class]) return ((NSNumber *)value).stringValue;
    return nil;
}

static long long DPContentsSession(id contents) {
    return [contents respondsToSelector:@selector(sessionId)] ? DPLongID(DPMsg(contents, @selector(sessionId))) : 0;
}

static NSString *DPDecodeLabel(NSString *label) {
    if (![label hasPrefix:@"xn--"]) return label;
    NSString *decoded = [label stringByApplyingTransform:@"Any-Punycode" reverse:YES];
    return decoded.length && ![decoded isEqualToString:label] ? decoded.lowercaseString : label;
}

// nil for the new tab page, dia://, chrome://, file and other internal pages.
static NSString *DPDomainKey(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString ?: @""];
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return nil;
    NSString *host = url.host.lowercaseString;
    if (!host.length) return nil;
    while ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    for (NSString *part in [host componentsSeparatedByString:@"."]) [labels addObject:DPDecodeLabel(part)];
    host = [labels componentsJoinedByString:@"."];
    if ([host hasPrefix:@"www."] && host.length > 4) host = [host substringFromIndex:4];
    return host.length ? host : nil;
}

static void DPRemember(id contents, id session, id browser, id delegate) {
    if (browser) [DPBrowsers addObject:browser];
    if (browser && delegate) [DPDelegateByBrowser setObject:delegate forKey:browser];
    if (!contents || !browser) return;
    [DPBrowserByContents setObject:browser forKey:contents];
    [DPTrackedContents addObject:contents];
    long long sid = DPLongID(session);
    if (sid <= 0) sid = DPContentsSession(contents);
    if (sid > 0) objc_setAssociatedObject(contents, &DPSessionKey, @(sid), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id DPGroupingDelegate(id self, id browser) {
    if ([self respondsToSelector:@selector(browser:getAllTabGroupsWithCompletion:)]) return self;
    return [DPDelegateByBrowser objectForKey:browser];
}

static void DPBrowser_setDelegate(id self, SEL _cmd, id delegate) {
    DPCallOriginal(void (*)(id, SEL, id), self, _cmd, delegate);
    [DPBrowsers addObject:self];
    if (delegate) [DPDelegateByBrowser setObject:delegate forKey:self];
}

static void DPBrowser_setWindow(id self, SEL _cmd, NSWindow *window) {
    DPCallOriginal(void (*)(id, SEL, NSWindow *), self, _cmd, window);
    [DPBrowsers addObject:self];
    if (window) [DPWindowByBrowser setObject:window forKey:self];
}

static void DPBrowser_didRestore(id self, SEL _cmd, id browser, id contents, id session) {
    DPCallOriginal(void (*)(id, SEL, id, id, id), self, _cmd, browser, contents, session);
    if (browser) DPRemember(contents, session, browser, DPGroupingDelegate(self, browser));
}

static void DPBrowser_didCreate(id self, SEL _cmd, id browser, id contents, BOOL active) {
    DPCallOriginal(void (*)(id, SEL, id, id, BOOL), self, _cmd, browser, contents, active);
    if (browser && contents) DPRemember(contents, nil, browser, DPGroupingDelegate(self, browser));
}

// Tabs opened from Dia's own UI come from here, not from the Chromium callbacks above, which only see
// tabs restored at launch and ones a page opens.
static id DPBrowser_createWebContents(id self, SEL _cmd, id params) {
    id contents = DPCallOriginal(id (*)(id, SEL, id), self, _cmd, params);
    DPRemember(contents, nil, self, [DPDelegateByBrowser objectForKey:self]);
    return contents;
}

// A tab dragged to another window changes browser.
static void DPBrowser_takeOwnership(id self, SEL _cmd, id contents) {
    DPCallOriginal(void (*)(id, SEL, id), self, _cmd, contents);
    DPRemember(contents, nil, self, [DPDelegateByBrowser objectForKey:self]);
}

static BOOL DPIsNewGroupTitle(NSString *title) {
    if ([title isEqualToString:@"New Group with Tab"] || [title isEqualToString:@"New Group with Tabs"]) return YES;
    return [title hasPrefix:@"New Group with "] && ([title hasSuffix:@" Tab"] || [title hasSuffix:@" Tabs"]);
}

@interface DPGroupCommand : NSObject
+ (instancetype)shared;
- (void)groupTabsByDomain:(id)sender;
@end

static id DPCommandBrowser(void) {
    NSWindow *key = NSApp.keyWindow;
    id only = nil;
    NSUInteger ready = 0;
    for (id browser in DPBrowsers.allObjects) {
        if (![[DPDelegateByBrowser objectForKey:browser] respondsToSelector:@selector(browser:getAllTabGroupsWithCompletion:)]) continue;
        ready++;
        only = browser;
        NSWindow *window = [DPWindowByBrowser objectForKey:browser];
        if (window && key && window == key) return browser;
    }
    return ready == 1 ? only : nil;
}

static void DPCollectPinned(NSMutableSet<NSNumber *> *sessions, NSMutableSet<NSString *> *pinnedURLs, NSMutableSet<NSString *> *openURLs) {
    id app = NSApp.delegate;
    if (![app respondsToSelector:@selector(appleScriptWindows)]) return;
    NSArray *windows = DPMsg(app, @selector(appleScriptWindows));
    if (![windows isKindOfClass:NSArray.class]) return;
    for (id window in windows) {
        if (![window respondsToSelector:@selector(appleScriptTabs)]) continue;
        NSArray *tabs = DPMsg(window, @selector(appleScriptTabs));
        if (![tabs isKindOfClass:NSArray.class]) continue;
        for (id tab in tabs) {
            NSString *url = [tab respondsToSelector:@selector(URL)] ? DPText(DPMsg(tab, @selector(URL))) : nil;
            BOOL pinned = [tab respondsToSelector:@selector(isPinned)] && DPMsgBool(tab, @selector(isPinned));
            id rawID = [tab respondsToSelector:@selector(tabId)] ? DPMsg(tab, @selector(tabId)) : nil;
            if (pinned && url.length) [pinnedURLs addObject:url];
            else if (url.length) [openURLs addObject:url];
            if (!pinned) continue;
            long long sid = DPLongID(rawID);
            if (sid > 0) [sessions addObject:@(sid)];
        }
    }
}

static BOOL DPPinned(long long sid, NSString *url, NSSet<NSNumber *> *sessions, NSSet<NSString *> *urls, NSSet<NSString *> *openURLs) {
    if ([sessions containsObject:@(sid)]) return YES;
    return url.length && [urls containsObject:url] && ![openURLs containsObject:url];
}

static id DPGroupProperties(NSString *title) {
    Class cls = NSClassFromString(@"ArcTabGroupProperties");
    id props = cls ? [cls new] : nil;
    if ([props respondsToSelector:@selector(setTitle:)]) [props setTitle:title];
    return props;
}

static void DPRunOps(id delegate, id browser, NSArray<NSDictionary *> *ops, NSUInteger index) {
    if (index >= ops.count) return;
    NSDictionary *op = ops[index];
    void (^next)(id) = ^(id result) {
        dispatch_async(dispatch_get_main_queue(), ^{ DPRunOps(delegate, browser, ops, index + 1); });
    };
    void (*create)(id, SEL, id, NSArray *, id, void (^)(id)) = (void *)objc_msgSend;
    void (*add)(id, SEL, id, NSString *, NSArray *, void (^)(id)) = (void *)objc_msgSend;
    if ([op[@"op"] isEqual:@"create"]) {
        id props = DPGroupProperties(op[@"title"]);
        if (!props) return DPRunOps(delegate, browser, ops, index + 1);
        create(delegate, @selector(browser:createTabGroupWithSessionIds:properties:completion:), browser, op[@"ids"], props, next);
    } else {
        add(delegate, @selector(browser:addTabsToGroupWithId:sessionIds:completion:), browser, op[@"group"], op[@"ids"], next);
    }
}

// Loose tabs join an existing group whose title is exactly the domain. Tabs in any other group stay put.
static NSArray<NSDictionary *> *DPOps(NSArray<NSDictionary *> *tabs, NSArray *groups) {
    NSMutableDictionary<NSNumber *, NSString *> *groupTitle = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *homeID = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableSet<NSNumber *> *> *homeMembers = [NSMutableDictionary dictionary];
    for (id info in groups) {
        if (![info respondsToSelector:@selector(groupId)]) continue;
        NSString *groupID = DPText(DPMsg(info, @selector(groupId)));
        NSString *title = [info respondsToSelector:@selector(title)] ? DPText(DPMsg(info, @selector(title))) ?: @"" : @"";
        if (!groupID.length) continue;
        NSArray *rawIDs = [info respondsToSelector:@selector(tabSessionIds)] ? DPMsg(info, @selector(tabSessionIds)) : nil;
        if ([rawIDs isKindOfClass:NSArray.class]) for (id raw in rawIDs) {
            long long sid = DPLongID(raw);
            if (sid > 0) groupTitle[@(sid)] = title;
        }
        if (title.length && !homeID[title]) {
            homeID[title] = groupID;
            homeMembers[title] = [NSMutableSet set];
        }
        if (homeMembers[title]) {
            if ([rawIDs isKindOfClass:NSArray.class]) for (id raw in rawIDs) {
                long long sid = DPLongID(raw);
                if (sid > 0) [homeMembers[title] addObject:@(sid)];
            }
        }
    }
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *pools = [NSMutableDictionary dictionary];
    for (NSDictionary *tab in tabs) {
        NSNumber *sid = tab[@"session"];
        NSString *domain = tab[@"domain"];
        NSString *title = groupTitle[sid];
        if (title && ![title isEqualToString:domain]) continue;
        NSMutableArray *pool = pools[domain] ?: (pools[domain] = [NSMutableArray array]);
        [pool addObject:tab];
    }
    NSMutableArray<NSDictionary *> *ops = [NSMutableArray array];
    for (NSString *domain in pools) {
        NSArray<NSDictionary *> *pool = pools[domain];
        if (pool.count < 2) continue;
        NSMutableArray<NSNumber *> *ids = [NSMutableArray array];
        for (NSDictionary *tab in pool) if (![homeMembers[domain] containsObject:tab[@"session"]]) [ids addObject:tab[@"session"]];
        if (!ids.count) continue;
        if (homeID[domain]) [ops addObject:@{@"op": @"add", @"group": homeID[domain], @"ids": ids}];
        else if (ids.count >= 2) [ops addObject:@{@"op": @"create", @"title": domain, @"ids": ids}];
    }
    return ops;
}

static void DPGroupTabsOnce(void) {
    id browser = DPCommandBrowser();
    if (!browser) return;
    id delegate = [DPDelegateByBrowser objectForKey:browser];
    if (![delegate respondsToSelector:@selector(browser:getAllTabGroupsWithCompletion:)]) return;
    NSMutableSet<NSNumber *> *pinnedSessions = [NSMutableSet set];
    NSMutableSet<NSString *> *pinnedURLs = [NSMutableSet set], *openURLs = [NSMutableSet set];
    DPCollectPinned(pinnedSessions, pinnedURLs, openURLs);
    NSMutableArray<NSDictionary *> *tabs = [NSMutableArray array];
    for (id contents in DPTrackedContents.allObjects) {
        if ([DPBrowserByContents objectForKey:contents] != browser) continue;
        long long sid = DPContentsSession(contents);
        if (sid <= 0) sid = DPLongID(objc_getAssociatedObject(contents, &DPSessionKey));
        NSString *url = DPText(DPMsg(contents, @selector(url)));
        NSString *domain = DPDomainKey(url);
        if (sid <= 0 || !domain || DPPinned(sid, url, pinnedSessions, pinnedURLs, openURLs)) continue;
        [tabs addObject:@{@"session": @(sid), @"domain": domain}];
    }
    void (*ask)(id, SEL, id, void (^)(NSArray *)) = (void *)objc_msgSend;
    NSArray *snapshot = [tabs copy];
    ask(delegate, @selector(browser:getAllTabGroupsWithCompletion:), browser, ^(NSArray *groups) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![groups isKindOfClass:NSArray.class]) return;
            NSArray *ops = DPOps(snapshot, groups);
            DPRunOps(delegate, browser, ops, 0);
        });
    });
}

@implementation DPGroupCommand
+ (instancetype)shared {
    static DPGroupCommand *command;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ command = [DPGroupCommand new]; });
    return command;
}
- (void)groupTabsByDomain:(id)sender { DPGroupTabsOnce(); }
@end

static NSMenuItem *DPGroupMenuItem(void) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:DPGroupMenuTitle action:@selector(groupTabsByDomain:) keyEquivalent:@""];
    item.target = DPGroupCommand.shared;
    item.tag = DPGroupMenuTag;
    item.image = [NSImage imageWithSystemSymbolName:@"rectangle.3.group" accessibilityDescription:nil];
    return item;
}

static void DPPlaceGroupItem(NSMenu *menu) {
    if (DPInserting || !menu) return;
    NSInteger anchor = NSNotFound, visible = NSNotFound, existing = NSNotFound;
    for (NSInteger i = 0; i < menu.numberOfItems; i++) {
        NSMenuItem *item = [menu itemAtIndex:i];
        if (item.tag == DPGroupMenuTag) existing = i;
        else if (DPIsNewGroupTitle(item.title)) {
            if (!item.hidden && visible == NSNotFound) visible = i;
            if (anchor == NSNotFound) anchor = i;
        }
    }
    if (visible != NSNotFound) anchor = visible;
    if (anchor == NSNotFound) return;
    DPInserting = YES;
    for (NSInteger i = menu.numberOfItems - 1; i >= 0; i--)
        if ([menu itemAtIndex:i].tag == DPGroupMenuTag && i != existing) {
            [menu removeItemAtIndex:i];
            if (i < existing) existing--;
            if (i < anchor) anchor--;
        }
    DPInserting = NO;
    NSInteger end = menu.numberOfItems;
    for (NSInteger i = anchor + 1; i < menu.numberOfItems; i++)
        if ([menu itemAtIndex:i].isSeparatorItem) { end = i; break; }
    if (existing == end - 1) return;
    DPInserting = YES;
    NSMenuItem *item = existing != NSNotFound ? [menu itemAtIndex:existing] : DPGroupMenuItem();
    if (existing != NSNotFound) {
        [menu removeItemAtIndex:existing];
        if (existing < end) end--;
    }
    [menu insertItem:item atIndex:end];
    DPInserting = NO;
}

static void DPInstallMenuBarItem(void) {
    NSMenu *tabMenu = nil, *commandMenu = nil, *windowMenu = nil, *fileMenu = nil;
    for (NSMenuItem *top in NSApp.mainMenu.itemArray) {
        NSString *title = top.title ?: @"";
        if ([title isEqualToString:@"Tab"] || [title isEqualToString:@"Tabs"]) tabMenu = top.submenu;
        if ([title isEqualToString:@"Window"]) windowMenu = top.submenu;
        if ([title isEqualToString:@"File"]) fileMenu = top.submenu;
        for (NSMenuItem *item in top.submenu.itemArray)
            if (DPIsNewGroupTitle(item.title) || [item.title isEqualToString:@"New Tab"] || [item.title isEqualToString:@"Close Tab"]
                || [item.title isEqualToString:@"Select Next Tab"] || [item.title isEqualToString:@"Reopen Closed Tab"])
                commandMenu = top.submenu;
    }
    NSMenu *menu = tabMenu ?: commandMenu ?: windowMenu ?: fileMenu;
    if (!menu || [menu itemWithTag:DPGroupMenuTag]) return;
    for (NSMenuItem *item in menu.itemArray)
        if (DPIsNewGroupTitle(item.title)) return DPPlaceGroupItem(menu);
    NSInteger index = menu.numberOfItems;
    for (NSInteger i = 0; i < menu.numberOfItems; i++) {
        NSString *title = [menu itemAtIndex:i].title;
        if (DPIsNewGroupTitle(title) || [title isEqualToString:@"New Tab"]) index = i + 1;
    }
    DPInserting = YES;
    [menu insertItem:DPGroupMenuItem() atIndex:MIN(index, menu.numberOfItems)];
    DPInserting = NO;
}

static void DPMenu_addItem(NSMenu *self, SEL _cmd, NSMenuItem *item) {
    DPCallOriginal(void (*)(id, SEL, id), self, _cmd, item);
    if (!DPInserting && (DPIsNewGroupTitle(item.title) || [self itemWithTag:DPGroupMenuTag])) DPPlaceGroupItem(self);
}

static void DPMenu_insertItem(NSMenu *self, SEL _cmd, NSMenuItem *item, NSInteger index) {
    DPCallOriginal(void (*)(id, SEL, id, NSInteger), self, _cmd, item, index);
    if (!DPInserting && (DPIsNewGroupTitle(item.title) || [self itemWithTag:DPGroupMenuTag])) DPPlaceGroupItem(self);
}


void DPInstallGroupTabs(void) {
    DPTrackedContents = [NSHashTable weakObjectsHashTable];
    DPBrowsers = [NSHashTable weakObjectsHashTable];
    DPBrowserByContents = [NSMapTable weakToWeakObjectsMapTable];
    DPDelegateByBrowser = [NSMapTable weakToWeakObjectsMapTable];
    DPWindowByBrowser = [NSMapTable weakToWeakObjectsMapTable];

    DPHook(NSClassFromString(@"ArcBrowser"), @selector(setDelegate:), DPBrowser_setDelegate);
    DPHook(NSClassFromString(@"ArcBrowser"), @selector(setWindow:), DPBrowser_setWindow);
    DPHook(NSClassFromString(@"ArcBrowser"), @selector(createWebContents:), DPBrowser_createWebContents);
    DPHook(NSClassFromString(@"ArcBrowser"), @selector(takeOwnershipOfWebContents:), DPBrowser_takeOwnership);
    Class browserDelegate = NSClassFromString(@"_TtC3ADK15ChromiumBrowser");
    DPHook(browserDelegate, @selector(browser:didRestoreWebContents:withSessionId:), DPBrowser_didRestore);
    DPHook(browserDelegate, @selector(browser:didCreateNewWebContents:isActive:), DPBrowser_didCreate);
    DPHook(NSMenu.class, @selector(addItem:), DPMenu_addItem);
    DPHook(NSMenu.class, @selector(insertItem:atIndex:), DPMenu_insertItem);

    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *_) { DPInstallMenuBarItem(); }];
}
