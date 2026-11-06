#import "ArcBar.h"
#import "Peek/PeekTweak.h"
#import "Tabs.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <libkern/OSCacheControl.h>
#import <libproc.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/resource.h>

typedef NS_ENUM(NSInteger, DPTweak) {
    DPEdgeToEdge, DPHideToolbar, DPSquareSidebarCorners, DPAnimatedCount,
    DPHideChatButton = DPAnimatedCount, DPHideSidebarButton, DPHideChatsButton, DPHideRecentTabsButton, DPNestedFolders,
    DPExtensionsButton, DPHideTabGlow, DPSidebarURLBar, DPCommandBar, DPFolderDropdowns, DPKeepWindowsActive, DPTidyTabs, DPDownloadsAtBottom, DPLittleWindow, DPTabMemory, DPMoveToSpace, DPNewTabBar, DPPlainNewTab, DPPeekOnShiftClick, DPArcBookmarks, DPPhoneAccess, DPTweakCount
};

static NSString *const DPKeys[DPTweakCount] = {@"edgeToEdge", @"hideToolbar", @"squareSidebarCorners", @"hideChatButton", @"hideSidebarButton", @"hideChatsButton", @"hideRecentTabsButton", @"nestedFolders", @"extensionsButton", @"hideTabGlow", @"sidebarURLBar", @"commandBar", @"folderDropdowns", @"keepWindowsActive", @"tidyTabs", @"downloadsAtBottom", @"littleWindow", @"tabMemory", @"moveToSpace", @"newTabBar", @"plainNewTab", @"peek", @"arcBookmarks", @"phoneAccess"};
static const BOOL DPDefaultsOn[DPTweakCount] = {YES, NO, YES, NO, NO, NO, NO, NO, YES, YES, YES, YES, YES, NO, YES, YES, YES, YES, YES, YES, YES, YES, YES, NO};
static const CGFloat DPWindowPadding = 6;
static const CFTimeInterval DPAnimationDuration = 0.25;

static BOOL DPOn[DPTweakCount];
static CGFloat DPProgress[DPAnimatedCount];
static NSUserDefaults *DPDefaults;
static NSHashTable<NSView *> *DPContainers, *DPPanes, *DPBars, *DPSuppressed;
static char DPExtensionsButtonKey, DPRequestedFrameKey, DPAssignedFrameKey, DPButtonKey, DPBaseRadiusKey, DPAssignedRadiusKey, DPFillsKey, DPChatKey, DPOriginalPathKey, DPAssignedPathKey, DPCollapsedKey, DPSearchItemKey;

static NSString *DPCLI(void) {
    return [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"DiaPatches/bin/diapatch"];
}

static void DPRunCLI(NSArray<NSString *> *args, void (^completion)(NSString *output)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:DPCLI()];
        task.arguments = args;
        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = NSFileHandle.fileHandleWithNullDevice;
        NSString *output = nil;
        if ([task launchAndReturnError:nil]) {
            NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
            [task waitUntilExit];
            if (task.terminationStatus == 0) output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(output); });
    });
}

static void DPHandOffAndQuit(NSString *command) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:DPCLI()];
    task.arguments = @[command, @"--wait", @(getpid()).stringValue, @"--relaunch"];
    if ([task launchAndReturnError:nil]) [NSApp terminate:nil];
}

static NSView *DPFindView(NSView *root, BOOL (^match)(NSView *)) {
    if (!root || match(root)) return root;
    for (NSView *sub in root.subviews) {
        NSView *found = DPFindView(sub, match);
        if (found) return found;
    }
    return nil;
}

#pragma mark - Hooks

// Hooks on the same method chain: each replacement's DPCallOriginal calls what was there when it was installed,
// found by the replacement's name (__func__). So pass DPHook the function itself and call DPCallOriginal directly
// in it, not from a block or helper. Button hooks are added per class as buttons appear, so the count isn't fixed;
// running out must stop here, since a hook that silently didn't land would leave its callers without an original.
typedef struct { Class cls; SEL sel; IMP replacement, original; const char *name; } DPOriginal;
static DPOriginal DPOriginals[256];
static int DPOriginalCount;

static void DPHookFunction(Class cls, SEL sel, IMP replacement, const char *name) {
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!method) return;
    for (int i = 0; i < DPOriginalCount; i++) {
        DPOriginal hook = DPOriginals[i];
        if (hook.sel != sel || strcmp(hook.name, name)) continue;
        if (hook.replacement != replacement) abort();  // two functions with one name would share originals
        // Already runs for cls, here or in a superclass. A second copy would look itself up and call itself.
        for (Class c = cls; c; c = class_getSuperclass(c)) if (c == hook.cls) return;
    }
    if (DPOriginalCount == 256) abort();
    IMP original = method_getImplementation(method);
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method))) method_setImplementation(method, replacement);
    DPOriginals[DPOriginalCount++] = (DPOriginal){cls, sel, replacement, original, name};
}

static IMP DPOriginalIMP(id object, SEL sel, const char *name) {
    for (Class c = object_getClass(object); c; c = class_getSuperclass(c))
        for (int i = 0; i < DPOriginalCount; i++)
            if (DPOriginals[i].cls == c && DPOriginals[i].sel == sel && !strcmp(DPOriginals[i].name, name)) return DPOriginals[i].original;
    abort();
}

#define DPHook(cls, sel, function) DPHookFunction(cls, sel, (IMP)function, #function)
#define DPCallOriginal(type, object, sel, ...) ((type)DPOriginalIMP(object, sel, __func__))(object, sel, ##__VA_ARGS__)

#pragma mark - Safe mode

// 0: normal. 1: Dia died twice right after launching, so no tweak hooks. 2: it kept dying, so nothing at all.
static NSInteger DPSafeMode;
static NSURL *DPSafeModeURL;
static NSMutableDictionary *DPSafeModeState;
static const int64_t DPSurviveSeconds = 15;  // a launch that neither lasts this long nor quits normally counts as a crash

static NSString *DPBuildUUID(const struct mach_header_64 *header) {
    const struct load_command *command = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const void *)((const uint8_t *)command + command->cmdsize))
        if (command->cmd == LC_UUID) return [[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)command)->uuid].UUIDString;
    return @"";
}

static void DPSurvived(void) {
    if (![DPSafeModeState[@"launching"] boolValue]) return;
    DPSafeModeState[@"launching"] = @NO;
    [DPSafeModeState writeToURL:DPSafeModeURL error:nil];
}

static void DPBeginLaunch(void) {
    Dl_info info;
    dladdr((const void *)DPBeginLaunch, &info);
    DPSafeModeURL = [NSURL fileURLWithPath:[@(info.dli_fname).stringByDeletingLastPathComponent stringByAppendingPathComponent:@"safe-mode.plist"]];
    // A new build of the dylib may be the fix, so it starts over.
    NSString *build = DPBuildUUID(info.dli_fbase);
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfURL:DPSafeModeURL error:nil];
    DPSafeModeState = [saved[@"build"] isEqual:build] ? [saved mutableCopy] : [NSMutableDictionary dictionaryWithObject:build forKey:@"build"];
    NSInteger crashes = [DPSafeModeState[@"launching"] boolValue] ? [DPSafeModeState[@"crashes"] integerValue] + 1 : 0;
    DPSafeMode = [DPSafeModeState[@"level"] integerValue];
    if (crashes == 2 && DPSafeMode < 2) DPSafeMode++, crashes = 0;
    [DPSafeModeState addEntriesFromDictionary:@{@"level": @(DPSafeMode), @"crashes": @(crashes), @"launching": @YES}];
    [DPSafeModeState writeToURL:DPSafeModeURL error:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, DPSurviveSeconds * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ DPSurvived(); });
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *_) { DPSurvived(); }];
}

static void DPLeaveSafeMode(void) {
    DPSafeModeState = [NSMutableDictionary dictionaryWithObject:DPSafeModeState[@"build"] ?: @"" forKey:@"build"];
    [DPSafeModeState writeToURL:DPSafeModeURL error:nil];
}

#pragma mark - Toolbar buttons

static BOOL DPIsKind(NSView *view, NSString *className) {
    Class cls = NSClassFromString(className);
    return cls && [view isKindOfClass:cls];
}

static NSInteger DPButtonTweak(NSView *view) {
    NSNumber *tweak = objc_getAssociatedObject(view, &DPButtonKey);
    if (tweak) return tweak.integerValue;
    NSString *label = view.accessibilityLabel;
    NSInteger match = [label isEqualToString:@"Chat with this tab"]                ? DPHideChatButton
                    : [label isEqualToString:@"Toggle sidebar"]                    ? DPHideSidebarButton
                    : [label isEqualToString:@"Recent tabs"]                       ? DPHideRecentTabsButton
                    : DPIsKind(view, @"_TtC10DiaLibrary17LibraryButtonView")       ? DPHideChatsButton
                    : DPIsKind(view, @"_TtC10TabSidebar15LibraryCellView")         ? DPHideChatsButton
                                                                                   : -1;
    if (match >= 0) objc_setAssociatedObject(view, &DPButtonKey, @(match), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return match;
}

static void DPButton_setHidden(NSView *self, SEL _cmd, BOOL hidden) {
    NSInteger tweak = DPButtonTweak(self);
    BOOL suppress = !hidden && tweak >= 0 && DPOn[tweak];
    if (suppress) [DPSuppressed addObject:self];
    else [DPSuppressed removeObject:self];
    DPCallOriginal(void (*)(id, SEL, BOOL), self, _cmd, hidden || suppress);
}

// As its window appears, Dia hides some views, but only ones that say they're showing. Until then, a view the tweak hid
// tells Dia it's showing, as Dia left it. Dia's layout afterwards and AppKit get the truth, or they'd leave its space.
static BOOL DPButton_isHidden(NSView *self, SEL _cmd) {
    Dl_info caller;
    if (!self.window.isVisible && [DPSuppressed containsObject:self] && dladdr(__builtin_return_address(0), &caller)
        && strstr(caller.dli_fname, "/Dia.app/"))
        return NO;
    return DPCallOriginal(BOOL (*)(id, SEL), self, _cmd);
}

static void DPEnforceButton(NSView *view) {
    NSInteger tweak = DPButtonTweak(view);
    if (tweak < 0) return;
    DPHook(view.class, @selector(setHidden:), DPButton_setHidden);
    DPHook(view.class, @selector(isHidden), DPButton_isHidden);
    if (!DPOn[tweak] || view.hidden) return;
    [DPSuppressed addObject:view];
    ((void (*)(id, SEL, BOOL))DPOriginalIMP(view, @selector(setHidden:), "DPButton_setHidden"))(view, @selector(setHidden:), YES);
}

static void DPButton_viewDidMoveToWindow(NSView *self, SEL _cmd) {
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
    DPEnforceButton(self);
}

static BOOL DPEnforceButtons(NSView *view) {
    if (DPButtonTweak(view) >= 0) {
        DPHook(view.class, @selector(viewDidMoveToWindow), DPButton_viewDidMoveToWindow);
        BOOL wasHidden = view.hidden;
        DPEnforceButton(view);
        return view.hidden != wasHidden;
    }
    BOOL changed = NO;
    for (NSView *sub in view.subviews) changed |= DPEnforceButtons(sub);
    return changed;
}

// A ⋯ button after the pinned extensions pops up Extensions from the menu bar: every extension, and Pin
// Extensions… to choose which stay in the toolbar. The pinned extensions move left to make room.
@interface DPExtensionsMenuTarget : NSObject
@end

@implementation DPExtensionsMenuTarget
- (void)showExtensions:(NSView *)sender {
    NSMenu *extensions = nil;
    for (NSMenuItem *item in NSApp.mainMenu.itemArray)
        if ([item.submenu.itemArray indexOfObjectPassingTest:^BOOL(NSMenuItem *i, NSUInteger _, BOOL *__) {
                return [i.title hasPrefix:@"Pin Extensions"];
            }] != NSNotFound)
            extensions = item.submenu;
    if (!extensions) return;
    if ([extensions.delegate respondsToSelector:@selector(menuNeedsUpdate:)]) [extensions.delegate menuNeedsUpdate:extensions];
    [extensions update];
    // A fixed width: long names are cut short to fit, and the menu hangs below the button, right edges aligned.
    static const CGFloat width = 330;
    // Dia's menu items can't be copied, so each one here runs its original.
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    for (NSMenuItem *original in extensions.itemArray) {
        if (original.separatorItem || original.hidden) {
            if (original.separatorItem) [menu addItem:NSMenuItem.separatorItem];
            continue;
        }
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:original.title action:@selector(runOriginal:) keyEquivalent:@""];
        item.target = self;
        item.image = original.image;
        item.enabled = original.enabled;
        item.representedObject = original;
        [menu addItem:item];
    }
    NSDictionary *font = @{NSFontAttributeName: menu.font ?: [NSFont menuFontOfSize:0]};
    CGFloat room = width - 60;  // the menu's own insets and image column
    for (NSMenuItem *item in menu.itemArray) {
        NSString *title = item.title;
        while (title.length > 1 && [title sizeWithAttributes:font].width > room)
            title = [[title substringToIndex:title.length - 2] stringByAppendingString:@"…"];
        if (title != item.title) {
            item.toolTip = item.title;
            item.title = title;
        }
    }
    menu.minimumWidth = width;
    // Below the button: right edges aligned in the toolbar, left edges in the sidebar.
    CGFloat below = sender.isFlipped ? NSHeight(sender.bounds) + 4 : -4;
    BOOL inSidebar = [sender.identifier isEqualToString:@"DiaPatchesSidebarExtensions"];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(inSidebar ? 0 : NSWidth(sender.bounds) - width, below) inView:sender];
}

- (void)runOriginal:(NSMenuItem *)sender {
    NSMenuItem *original = sender.representedObject;
    NSInteger index = [original.menu indexOfItem:original];
    if (index >= 0) [original.menu performActionForItemAtIndex:index];
}
@end

static void DPApplyExtensionsButton(NSView *bar);

void DPShowExtensionsMenu(NSView *anchor) {
    static DPExtensionsMenuTarget *target;
    target = target ?: [DPExtensionsMenuTarget new];
    [target showExtensions:anchor];
}

static void DPBar_layout(NSView *self, SEL _cmd) {
    [DPBars addObject:self];
    DPEnforceButtons(self);
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
    if (DPIsKind(self, @"_TtC13NavigationBar17NavigationBarView")) DPApplyExtensionsButton(self);
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
    BOOL empty = DPOn[DPHideChatsButton] && DPOn[DPHideRecentTabsButton];
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
    for (NSView *sub in self.view.subviews) if (DPButtonTweak(sub) >= 0) DPEnforceButtons(sub);
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
}

static void DPRestoreButtons(DPTweak tweak) {
    for (NSView *view in DPSuppressed.allObjects)
        if (DPButtonTweak(view) == tweak) view.hidden = NO;
}

#pragma mark - Edge-to-edge

// With Chat open Dia animates sidebar changes from its own geometry, so edge-to-edge steps aside.
static NSView *DPChatCard(NSView *container) {
    NSView *content = DPFindView(container, ^BOOL(NSView *v) { return v != container && v.layer.masksToBounds && v.layer.cornerRadius > 0; });
    NSSize size = content.bounds.size;
    BOOL (^isCard)(NSView *) = ^BOOL(NSView *v) {
        return v.layer.masksToBounds && v.layer.cornerRadius > 0 && NSWidth(v.bounds) > size.width / 4 && NSHeight(v.bounds) > size.height / 2;
    };
    for (NSView *root in content.subviews)
        for (NSView *host in root.subviews) {
            if (NSMinX(host.frame) < 2 && NSMinY(host.frame) < 2) continue;
            if (isCard(host)) return host;
            for (NSView *card in host.subviews) if (isCard(card)) return card;
        }
    return nil;
}

static NSRect DPEdgeToEdgeFrame(NSView *view, NSRect frame) {
    CGFloat inset = DPProgress[DPEdgeToEdge] * DPWindowPadding;
    NSView *superview = view.superview;
    if (inset == 0 || !superview || DPChatCard(view)) return frame;
    NSRect bounds = superview.bounds;
    CGFloat left = NSMinX(frame) - NSMinX(bounds), right = NSMaxX(bounds) - NSMaxX(frame);
    CGFloat top = superview.isFlipped ? NSMinY(frame) - NSMinY(bounds) : NSMaxY(bounds) - NSMaxY(frame);
    CGFloat bottom = superview.isFlipped ? NSMaxY(bounds) - NSMaxY(frame) : NSMinY(frame) - NSMinY(bounds);
    BOOL (^isPadding)(CGFloat) = ^BOOL(CGFloat gap) { return fabs(gap - DPWindowPadding) < 0.5; };
    if (isPadding(left)) frame.origin.x -= inset, frame.size.width += inset;
    if (isPadding(right)) frame.size.width += inset;
    if (isPadding(top)) {
        frame.size.height += inset;
        if (superview.isFlipped) frame.origin.y -= inset;
    }
    if (isPadding(bottom)) {
        frame.size.height += inset;
        if (!superview.isFlipped) frame.origin.y -= inset;
    }
    return frame;
}

static void DPSetCornerRadius(NSView *container, CGFloat inset) {
    static ptrdiff_t offset = -1;
    if (offset < 0) {
        Ivar ivar = class_getInstanceVariable(container.class, "cornerRadius");
        offset = ivar ? ivar_getOffset(ivar) : 0;
    }
    if (!offset) return;
    CGFloat *radius = (CGFloat *)((uint8_t *)(__bridge void *)container + offset);
    NSNumber *assigned = objc_getAssociatedObject(container, &DPAssignedRadiusKey);
    CGFloat base = assigned && assigned.doubleValue == *radius ? [objc_getAssociatedObject(container, &DPBaseRadiusKey) doubleValue] : *radius;
    objc_setAssociatedObject(container, &DPBaseRadiusKey, @(base), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(container, &DPAssignedRadiusKey, @(base + inset), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (*radius == base + inset) return;
    *radius = base + inset;
    container.needsLayout = YES;
}

static void DPContainer_setFrame(NSView *self, SEL _cmd, NSRect frame) {
    objc_setAssociatedObject(self, &DPRequestedFrameKey, [NSValue valueWithRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [DPContainers addObject:self];
    NSRect adjusted = DPEdgeToEdgeFrame(self, frame);
    DPSetCornerRadius(self, NSEqualRects(adjusted, frame) ? 0 : DPProgress[DPEdgeToEdge] * DPWindowPadding);
    DPCallOriginal(void (*)(id, SEL, NSRect), self, _cmd, adjusted);
}

// Scales the corners of the path's first subpath in place; same elements, so Dia's path animations still interpolate.
static CGPathRef DPReshapeCorners(CGPathRef path, CGFloat extent, CGFloat rightScale, CGFloat leftScale) {
    if (!path) return NULL;
    __block CGRect box = CGRectNull;
    __block int subpath = 0;
    CGPathApplyWithBlock(path, ^(const CGPathElement *element) {
        if (element->type == kCGPathElementMoveToPoint && !CGRectIsNull(box)) subpath++;
        int count = element->type == kCGPathElementAddCurveToPoint ? 3 : element->type == kCGPathElementAddQuadCurveToPoint ? 2
                  : element->type == kCGPathElementCloseSubpath ? 0 : 1;
        for (int i = 0; i < count && subpath == 0; i++) box = CGRectUnion(box, (CGRect){element->points[i], CGSizeZero});
    });
    CGMutablePathRef reshaped = CGPathCreateMutable();
    subpath = 0;
    __block BOOL started = NO;
    CGPoint (^move)(CGPoint) = ^CGPoint(CGPoint p) {
        if (subpath > 0) return p;
        CGFloat cx = p.x - CGRectGetMinX(box) < extent ? CGRectGetMinX(box) : CGRectGetMaxX(box) - p.x < extent ? CGRectGetMaxX(box) : NAN;
        CGFloat cy = p.y - CGRectGetMinY(box) < extent ? CGRectGetMinY(box) : CGRectGetMaxY(box) - p.y < extent ? CGRectGetMaxY(box) : NAN;
        if (isnan(cx) || isnan(cy)) return p;
        CGFloat scale = cx == CGRectGetMinX(box) ? leftScale : rightScale;
        return CGPointMake(cx + (p.x - cx) * scale, cy + (p.y - cy) * scale);
    };
    CGPathApplyWithBlock(path, ^(const CGPathElement *element) {
        const CGPoint *p = element->points;
        switch (element->type) {
            case kCGPathElementMoveToPoint:
                if (started) subpath++;
                started = YES;
                CGPathMoveToPoint(reshaped, NULL, move(p[0]).x, move(p[0]).y);
                break;
            case kCGPathElementAddLineToPoint: CGPathAddLineToPoint(reshaped, NULL, move(p[0]).x, move(p[0]).y); break;
            case kCGPathElementAddQuadCurveToPoint:
                CGPathAddQuadCurveToPoint(reshaped, NULL, move(p[0]).x, move(p[0]).y, move(p[1]).x, move(p[1]).y);
                break;
            case kCGPathElementAddCurveToPoint:
                CGPathAddCurveToPoint(reshaped, NULL, move(p[0]).x, move(p[0]).y, move(p[1]).x, move(p[1]).y, move(p[2]).x, move(p[2]).y);
                break;
            case kCGPathElementCloseSubpath: CGPathCloseSubpath(reshaped); break;
        }
    });
    return (CGPathRef)CFAutorelease(reshaped);
}

static void DPApplySquareCorners(NSView *container) {
    NSView *content = DPFindView(container, ^BOOL(NSView *v) { return v != container && v.layer.masksToBounds && v.layer.cornerRadius > 0; });
    CALayer *layer = content.layer;
    if (!layer) return;
    layer.cornerCurve = kCACornerCurveContinuous;
    // How far the left and right corners go square: by the sidebar, and wherever they meet a full screen's edges
    // (a full screen window has square corners).
    BOOL fullScreen = (container.window.styleMask & NSWindowStyleMaskFullScreen) && !DPChatCard(container);
    CGFloat squareRight = fullScreen ? DPProgress[DPEdgeToEdge] : 0;
    CGFloat square = NSMinX(container.frame) > DPWindowPadding + 1 && !DPChatCard(container)
        ? DPProgress[DPSquareSidebarCorners] * DPProgress[DPEdgeToEdge] : squareRight;
    CACornerMask left = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner, right = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if ((square == 0 || square == 1) && (squareRight == 0 || squareRight == 1)) {
        layer.mask = nil;
        layer.maskedCorners = (square == 1 ? 0 : left) | (squareRight == 1 ? 0 : right);
    } else {
        CALayer *mask = layer.mask.sublayers.count == 2 ? layer.mask : [CALayer layer];
        if (mask != layer.mask) {
            for (int i = 0; i < 2; i++) {
                CALayer *half = [CALayer layer];
                half.backgroundColor = NSColor.blackColor.CGColor;
                half.cornerCurve = kCACornerCurveContinuous;
                half.maskedCorners = i ? right : left;
                [mask addSublayer:half];
            }
        }
        CGRect bounds = layer.bounds;
        CGFloat half = CGRectGetWidth(bounds) / 2;
        mask.frame = bounds;
        mask.sublayers[0].frame = CGRectMake(0, 0, half + 1, CGRectGetHeight(bounds));
        mask.sublayers[1].frame = CGRectMake(half - 1, 0, half + 1, CGRectGetHeight(bounds));
        mask.sublayers[0].cornerRadius = layer.cornerRadius * (1 - square);
        mask.sublayers[1].cornerRadius = layer.cornerRadius * (1 - squareRight);
        layer.mask = mask;
        layer.maskedCorners = 0;
    }

    CGFloat base = [objc_getAssociatedObject(container, &DPBaseRadiusKey) doubleValue] ?: layer.cornerRadius;
    CGFloat grow = base > 0 ? layer.cornerRadius / base : 1;
    for (NSView *sub in container.subviews)
        for (CALayer *sublayer in sub.layer.sublayers) {
            CAShapeLayer *shape = [sublayer isKindOfClass:CAShapeLayer.class] ? (CAShapeLayer *)sublayer
                                : [sublayer.mask isKindOfClass:CAShapeLayer.class] ? (CAShapeLayer *)sublayer.mask : nil;
            if (!shape.path || CGRectGetWidth(CGPathGetBoundingBox(shape.path)) < NSWidth(container.bounds) * 0.9) continue;
            CGPathRef assigned = (__bridge CGPathRef)objc_getAssociatedObject(shape, &DPAssignedPathKey);
            if (!assigned || !CGPathEqualToPath(assigned, shape.path))
                objc_setAssociatedObject(shape, &DPOriginalPathKey, CFBridgingRelease(CGPathCreateCopy(shape.path)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CGPathRef path = DPReshapeCorners((__bridge CGPathRef)objc_getAssociatedObject(shape, &DPOriginalPathKey), base * 1.6, grow * (1 - squareRight), grow * (1 - square));
            if (!CGPathEqualToPath(path, shape.path)) shape.path = path;
            objc_setAssociatedObject(shape, &DPAssignedPathKey, (__bridge id)shape.path, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    [CATransaction commit];
}

static Class DPContainerClass(void) {
    static Class cls;
    return cls = cls ?: NSClassFromString(@"_TtC6Window20ContentContainerView");
}

static void DPRestyleContainer(NSView *container) {
    DPApplySquareCorners(container);
    CALayer *card = DPChatCard(container).layer;
    if (!card) return;
    if (card.cornerCurve != kCACornerCurveContinuous) card.cornerCurve = kCACornerCurveContinuous;
    NSValue *requested = objc_getAssociatedObject(container, &DPRequestedFrameKey);
    if (requested && !NSEqualRects(container.frame, requested.rectValue)) container.frame = requested.rectValue;
}

// Dia restyles its layers after its own layout pass.
static void DPContainer_layoutOrUpdateLayer(NSView *self, SEL _cmd) {
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
    DPRestyleContainer(self);
    dispatch_async(dispatch_get_main_queue(), ^{ DPRestyleContainer(self); });
}

// Opening or closing Chat reshapes the content without resizing the container.
static void DPShadow_layout(NSView *self, SEL _cmd) {
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
    NSView *container = self;
    while (container && ![container isKindOfClass:DPContainerClass()]) container = container.superview;
    if (!container) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL chat = DPChatCard(container) != nil;
        if ([objc_getAssociatedObject(container, &DPChatKey) boolValue] != chat) {
            objc_setAssociatedObject(container, &DPChatKey, @(chat), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSValue *requested = objc_getAssociatedObject(container, &DPRequestedFrameKey);
            if (requested) container.frame = requested.rectValue;
        }
        DPRestyleContainer(container);
    });
}

#pragma mark - Toolbar

static NSRect DPLaidOutFrame(NSView *view) {
    NSValue *assigned = objc_getAssociatedObject(view, &DPAssignedFrameKey);
    if (assigned && NSEqualRects(assigned.rectValue, view.frame))
        return [objc_getAssociatedObject(view, &DPRequestedFrameKey) rectValue];
    return view.frame;
}

static void DPAssignFrame(NSView *view, NSRect laidOut, NSRect frame) {
    objc_setAssociatedObject(view, &DPRequestedFrameKey, [NSValue valueWithRect:laidOut], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &DPAssignedFrameKey, [NSValue valueWithRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.frame = frame;
}

// Dia lays the bar out by frames: everything right of the address field moves left to make room for the button.
static void DPApplyExtensionsButton(NSView *bar) {
    static DPExtensionsMenuTarget *target;
    NSView *pinned = DPFindView(bar, ^BOOL(NSView *v) { return DPIsKind(v, @"PinnedExtensions.PinnedExtensionsView"); });
    NSView *address = DPFindView(bar, ^BOOL(NSView *v) { return DPIsKind(v, @"NavigationBar.AssistantBarView"); });
    NSView *host = pinned.superview;
    if (!host || !address) return;
    NSButton *button = objc_getAssociatedObject(bar, &DPExtensionsButtonKey);
    if (!button) {
        target = target ?: [DPExtensionsMenuTarget new];
        button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"ellipsis" accessibilityDescription:@"Extensions"]
                                    target:target action:@selector(showExtensions:)];
        button.bordered = NO;
        button.contentTintColor = NSColor.labelColor;
        button.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium];
        button.toolTip = @"Extensions";
        [host addSubview:button];
        objc_setAssociatedObject(bar, &DPExtensionsButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat room = DPOn[DPExtensionsButton] && !DPOn[DPHideToolbar] ? 30 : 0;
    NSRect addressFrame = DPLaidOutFrame(address);
    // The button goes after the pinned extensions, or with none pinned, after whatever ends the bar.
    CGFloat end = NSMaxX(addressFrame) + 5;
    for (NSView *parent in @[host, bar])
        for (NSView *view in parent.subviews) {
            if (view == button || view == address || view == host || view.hidden) continue;
            NSRect laidOut = DPLaidOutFrame(view);
            if (NSMinX(laidOut) < NSMaxX(addressFrame) || NSWidth(laidOut) > 200) continue;
            if (!NSEqualRects(view.frame, NSOffsetRect(laidOut, -room, 0))) DPAssignFrame(view, laidOut, NSOffsetRect(laidOut, -room, 0));
            if (NSWidth(laidOut) > 0) end = MAX(end, NSMaxX([host convertRect:laidOut fromView:parent]));
        }
    NSRect shorter = addressFrame;
    shorter.size.width -= room;
    if (!NSEqualRects(address.frame, shorter)) DPAssignFrame(address, addressFrame, shorter);
    button.hidden = room == 0;
    CGFloat x = !pinned.hidden && NSWidth(pinned.frame) > 0 ? NSMaxX(pinned.frame) : end - room;
    button.frame = NSMakeRect(x, NSMidY(address.frame) - 15, 30, 30);
}

static Class DPToolbarClass(void) {
    static Class cls;
    return cls = cls ?: NSClassFromString(@"_TtC13NavigationBar17NavigationBarView");
}

// The bar stays in Dia's layout: hiding it makes Dia reflow in ways it won't undo.
static NSView *DPToolbar_hitTest(NSView *self, SEL _cmd, NSPoint point) {
    return DPOn[DPHideToolbar] ? nil : DPCallOriginal(NSView *(*)(id, SEL, NSPoint), self, _cmd, point);
}

static void DPApplyToolbar(NSView *pane) {
    NSView *bar = nil;
    for (NSView *sub in pane.subviews) if ([sub isKindOfClass:DPToolbarClass()]) { bar = sub; break; }
    if (!bar) return;

    CGFloat progress = DPProgress[DPHideToolbar];
    bar.alphaValue = 1 - progress;
    NSView *lowest = pane.subviews.firstObject;
    if (progress > 0 && lowest != bar) [pane addSubview:bar positioned:NSWindowBelow relativeTo:lowest];
    else if (progress == 0 && lowest == bar) [pane addSubview:bar positioned:NSWindowAbove relativeTo:nil];

    BOOL flipped = pane.isFlipped;
    CGFloat (^top)(NSRect) = ^CGFloat(NSRect r) { return flipped ? NSMinY(r) : NSHeight(pane.bounds) - NSMaxY(r); };
    CGFloat (^bottom)(NSRect) = ^CGFloat(NSRect r) { return flipped ? NSMaxY(r) : NSHeight(pane.bounds) - NSMinY(r); };
    NSRect barLaidOut = DPLaidOutFrame(bar), barFrame = barLaidOut;
    // Out of sight, the bar waits above the pane, where the address field's text cursor can't reach the page under it.
    if (progress == 1) barFrame.origin.y += flipped ? -NSMaxY(barLaidOut) : NSHeight(pane.bounds) - NSMinY(barLaidOut);
    if (!NSEqualRects(bar.frame, barFrame)) DPAssignFrame(bar, barLaidOut, barFrame);
    CGFloat shift = NSHeight(barLaidOut) * progress, edge = bottom(barLaidOut);
    NSMutableArray<NSView *> *stack = [NSMutableArray new];
    for (NSView *sub in pane.subviews) if (sub != bar) [stack addObject:sub];
    [stack sortUsingComparator:^NSComparisonResult(NSView *a, NSView *b) {
        return [@(top(DPLaidOutFrame(a))) compare:@(top(DPLaidOutFrame(b)))];
    }];
    for (NSView *view in stack) {
        NSRect laidOut = DPLaidOutFrame(view);
        if (fabs(top(laidOut) - edge) > 0.5) continue;
        BOOL reachesBottom = fabs(bottom(laidOut) - NSHeight(pane.bounds)) < 0.5;
        if (!reachesBottom) edge = bottom(laidOut);
        NSRect frame = laidOut;
        if (reachesBottom) frame.size.height += shift;
        if (flipped) frame.origin.y -= shift;
        else if (!reachesBottom) frame.origin.y += shift;
        DPAssignFrame(view, laidOut, frame);
        // Dia sizes the web view once instead of autoresizing it.
        for (NSView *child in view.subviews) {
            if (!objc_getAssociatedObject(child, &DPFillsKey)) {
                if (!NSEqualRects(child.frame, (NSRect){NSZeroPoint, laidOut.size})) continue;
                objc_setAssociatedObject(child, &DPFillsKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            child.frame = view.bounds;
        }
    }
}

static void DPPane_layout(NSView *self, SEL _cmd) {
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
    [DPPanes addObject:self];
    DPApplyToolbar(self);
}

#pragma mark - Nested folders

// TabSurfaceDropValidationController refuses a drop target inside a group when the dragged items include a group.
// It's Swift with no symbols, so the refusing loop is redirected here, found by its exact instructions.
static const uint32_t DPValidatePrologue[] = {
    0xa9ba6ffc, 0xa90167fa, 0xa9025ff8, 0xa90357f6, 0xa9044ff4, 0xa9057bfd, 0x910143fd, 0xd12b03ff, 0xaa1403fa,
    0xaa0403f7, 0xaa0303f8, 0xaa0203f6, 0xaa0103f5, 0xaa0003f3, 0xf940085b, 0xb400021b, 0x52800308, 0x9b085b68,
};
// The scan of the dragged items, up to the refusal: x22 is the target's group ancestry, x23 the dragged item IDs.
static const uint32_t DPValidateCheck[] = {
    0xb7f811b7, 0xf9400ae8, 0x91000509, 0x5280060a, 0xf1000529, 0x540000e0, 0x386a6aeb, 0x9100614a, 0x7100057f, 0x54ffff61,
    0x72001e7f, 0x54000c20,
};
enum { DPCheckOffset = 0x7c, DPRedirectOffset = 0xac, DPRejectOffset = 0x22c, DPAcceptOffset = 0x2b0, DPContextOffset = 0x1e8 };

// Swift's native array storage: count at 0x10, elements from 0x20. A TabItem.ID is a String and a case tag
// (1 = group); a group ancestry component is the group's ID String and an index.
typedef struct { uint64_t bits, object; } DPString;
typedef struct { DPString id; uint8_t tag; } DPItemID;
typedef struct { DPString groupID; int64_t index; } DPGroupComponent;

static uintptr_t DPNestAccept, DPNestReject;
static BOOL (*DPStringEquals)(DPString, DPString);

__attribute__((used, visibility("hidden"))) uintptr_t DPNestDestination(const uint8_t *ancestry, const uint8_t *items) {
    int64_t depth = *(const int64_t *)(ancestry + 0x10), count = *(const int64_t *)(items + 0x10);
    const DPGroupComponent *groups = (const void *)(ancestry + 0x20);
    const uint8_t *item = items + 0x20;
    BOOL anyGroup = NO;
    for (int64_t i = 0; i < count; i++, item += 0x18) {
        const DPItemID *dragged = (const void *)item;
        if (dragged->tag != 1) continue;
        anyGroup = YES;
        // A group can't go inside itself or its own subfolders.
        for (int64_t g = 0; g < depth; g++)
            if (DPStringEquals(dragged->id, groups[g].groupID)) return DPNestReject;
    }
    return depth == 0 || !anyGroup || DPOn[DPNestedFolders] ? DPNestAccept : DPNestReject;
}

__attribute__((naked)) static void DPNestShim(void) {
    __asm__ volatile(
        "stp x29, x30, [sp, #-16]!\n"
        "mov x29, sp\n"
        "mov x0, x22\n"
        "mov x1, x23\n"
        "bl _DPNestDestination\n"
        "mov x16, x0\n"
        "ldp x29, x30, [sp], #16\n"
        "br x16\n");
}

// TabListCollectionViewLayout only lays out drop targets inside a group when the dragged items hold no group.
// Both checks open with the same scan of the dragged items (the second is now in a helper just before the function);
// the shims skip it while the tweak is on.
static const uint32_t DPLayoutPrologue[] = {
    0x6db63bef, 0x6d0133ed, 0x6d022beb, 0x6d0323e9, 0xa9046ffc, 0xa90567fa, 0xa9065ff8, 0xa90757f6,
    0xa9084ff4, 0xa9097bfd, 0x910243fd, 0xd10983ff, 0xaa1403fb, 0xaa0503f3, 0xaa0403f6, 0xaa0303f5,
};
static const uint32_t DPLayoutScan[] = {0xf940090a, 0x9100c109, 0x91000548, 0xf1000508};  // after cbz x8
static const int32_t DPLayoutSites[] = {0x1008, -0xc58};

__attribute__((used, visibility("hidden"))) const BOOL *DPNestingSwitch;
__attribute__((used, visibility("hidden"))) uintptr_t DPLayoutScan0, DPLayoutNoGroup0, DPLayoutScan1, DPLayoutNoGroup1;

// x8 is the dragged items; the original sets up x8-x10 and scans from the next instruction.
#define DP_LAYOUT_SHIM(n)                                                        \
    __attribute__((naked)) static void DPLayoutShim##n(void) {                   \
        __asm__ volatile(                                                        \
            "adrp x16, _DPNestingSwitch@PAGE\n"                                  \
            "ldr x16, [x16, _DPNestingSwitch@PAGEOFF]\n"                         \
            "ldrb w16, [x16]\n"                                                  \
            "cbnz w16, 1f\n"                                                     \
            "cbz x8, 1f\n"                                                       \
            "ldr x10, [x8, #0x10]\n"                                             \
            "add x9, x8, #0x30\n"                                                \
            "add x8, x10, #1\n"                                                  \
            "adrp x16, _DPLayoutScan" #n "@PAGE\n"                               \
            "ldr x16, [x16, _DPLayoutScan" #n "@PAGEOFF]\n"                      \
            "br x16\n"                                                           \
            "1:\n"                                                               \
            "adrp x16, _DPLayoutNoGroup" #n "@PAGE\n"                            \
            "ldr x16, [x16, _DPLayoutNoGroup" #n "@PAGEOFF]\n"                   \
            "br x16\n");                                                         \
    }
DP_LAYOUT_SHIM(0)
DP_LAYOUT_SHIM(1)

// TabGroupingController places a new group where its tabs are only when they share a parent with tag 2; tabs in a
// group (tag 0x80) send it up beside the outermost group. The shim lets a group parent keep it in place.
static const uint32_t DPLocationPrologue[] = {
    0xa9ba6ffc, 0xa90167fa, 0xa9025ff8, 0xa90357f6, 0xa9044ff4, 0xa9057bfd,
    0x910143fd, 0xd12883ff, 0x910003f3, 0xaa1403fc, 0xaa0103f9, 0xaa0003f7, 0xaa0803f8,
};
static const uint32_t DPLocationSite[] = {0x395e4268, 0x7100091f, 0, 0xf9402a60, 0xaa1c03e1, 0xaa1503e2, 0xaa1703e3, 0xf9403264};
enum { DPLocationOffset = 0x524 };

__attribute__((used, visibility("hidden"))) uintptr_t DPLocationSame, DPLocationCopied, DPLocationAncestor, DPLocationCopyParent;
static BOOL DPSubfolderMenuAvailable;

// x19 is the frame: the shared parent at 0x770 (tag at 0x790), its first word also at 0x50 and its tag at 0x60.
// The parent copy only retains a group's ID as a single-payload case, so it's handed tag 2.
__attribute__((naked)) static void DPLocationShim(void) {
    __asm__ volatile(
        "ldrb w8, [x19, #0x790]\n"
        "cmp w8, #2\n"
        "b.eq 2f\n"
        "cmp w8, #0x80\n"
        "b.ne 1f\n"
        "adrp x16, _DPNestingSwitch@PAGE\n"
        "ldr x16, [x16, _DPNestingSwitch@PAGEOFF]\n"
        "ldrb w16, [x16]\n"
        "cbz w16, 1f\n"
        "ldr x0, [x19, #0x50]\n"
        "mov x1, x28\n"
        "mov x2, x21\n"
        "mov x3, x23\n"
        "mov w4, #2\n"
        "adrp x16, _DPLocationCopyParent@PAGE\n"
        "ldr x16, [x16, _DPLocationCopyParent@PAGEOFF]\n"
        "blr x16\n"
        "adrp x16, _DPLocationCopied@PAGE\n"
        "ldr x16, [x16, _DPLocationCopied@PAGEOFF]\n"
        "br x16\n"
        "2:\n"
        "ldr x0, [x19, #0x50]\n"
        "adrp x16, _DPLocationSame@PAGE\n"
        "ldr x16, [x16, _DPLocationSame@PAGEOFF]\n"
        "br x16\n"
        "1:\n"
        "adrp x16, _DPLocationAncestor@PAGE\n"
        "ldr x16, [x16, _DPLocationAncestor@PAGEOFF]\n"
        "br x16\n");
}

static BOOL DPRedirect(uint8_t *at, void (*to)(void)) {
    uint32_t redirect[4] = {0x58000050, 0xd61f0200};  // ldr x16, #8; br x16
    uintptr_t shim = (uintptr_t)to;
    memcpy(&redirect[2], &shim, sizeof shim);
    vm_address_t page = (vm_address_t)at & ~(vm_address_t)(vm_page_size - 1);
    vm_size_t span = (vm_address_t)at + sizeof redirect - page;
    if (vm_protect(mach_task_self(), page, span, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return NO;
    memcpy(at, redirect, sizeof redirect);
    vm_protect(mach_task_self(), page, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate(at, sizeof redirect);
    return YES;
}

// After a move, TabMoveController deletes the folder the items left if it's now empty. While the tweak is on the
// folder stays: moving its last item out of it, as dragging nested folders around often does, isn't a deletion.
static const uint32_t DPCleanupPrologue[] = {
    0xa9ba6ffc, 0xa90167fa, 0xa9025ff8, 0xa90357f6, 0xa9044ff4, 0xa9057bfd, 0x910143fd, 0xd10fc3ff, 0x910003f3, 0xf9001e74, 0xaa0003fc,
};
static const uint32_t DPCleanupSite[] = {0xf9400669, 0xf8686928, 0xf9400908};  // the folder's child count, then cbz
enum { DPCleanupOffset = 0x288 };

__attribute__((used, visibility("hidden"))) uintptr_t DPCleanupKeep, DPCleanupDelete;

// x8 is the field offset of the folder's childIDs and x19 + 8 points at the folder.
__attribute__((naked)) static void DPCleanupShim(void) {
    __asm__ volatile(
        "ldr x9, [x19, #0x8]\n"
        "ldr x8, [x9, x8]\n"
        "ldr x8, [x8, #0x10]\n"
        "cbnz x8, 1f\n"
        "adrp x16, _DPNestingSwitch@PAGE\n"
        "ldr x16, [x16, _DPNestingSwitch@PAGEOFF]\n"
        "ldrb w16, [x16]\n"
        "cbnz w16, 1f\n"
        "adrp x16, _DPCleanupDelete@PAGE\n"
        "ldr x16, [x16, _DPCleanupDelete@PAGEOFF]\n"
        "br x16\n"
        "1:\n"
        "adrp x16, _DPCleanupKeep@PAGE\n"
        "ldr x16, [x16, _DPCleanupKeep@PAGEOFF]\n"
        "br x16\n");
}

// TabListCollectionViewLayout picks the target under the pointer by its height alone, first match wins: the
// end of a folder is a sliver a few points tall, and a collapsed folder's "inside" target reaches into the next row,
// so drops kept landing a level too deep. The replacement keeps Dia's pick away from folder edges; near an edge the
// pointer's indent chooses the level, Arc-style, and a collapsed folder only claims the top of the next row.
static const uint32_t DPHitTestPrologue[] = {
    0xd10283ff, 0x6d0233ed, 0x6d032beb, 0x6d0423e9, 0xa90567fa, 0xa9065ff8, 0xa90757f6, 0xa9084ff4, 0xa9097bfd, 0x910243fd, 0x4ea11c28,
};
enum { DPHitTestStrideOffset = 0xc8, DPHitTestStride = 0x9100e339 };  // add x25, x25, #0x38

typedef struct {
    uint8_t section;
    int64_t index;
    const uint8_t *ancestry;  // [TabSurfaceIndexPath.GroupComponent]
    CGRect rect;
} DPDropTarget;

static int64_t DPTargetDepth(const DPDropTarget *t) { return t->ancestry ? *(const int64_t *)(t->ancestry + 0x10) : 0; }

static BOOL DPTargetContains(const DPDropTarget *t, CGFloat y) { return y >= CGRectGetMinY(t->rect) && y < CGRectGetMaxY(t->rect); }

static const DPDropTarget *DPPickDropTarget(const DPDropTarget *targets, int64_t count, CGFloat x, CGFloat y, BOOL dragging) {
    const DPDropTarget *first = NULL, *row = NULL;
    for (int64_t i = 0; i < count; i++) {
        const DPDropTarget *t = &targets[i];
        if (!DPTargetContains(t, y)) continue;
        if (!first) first = t;
        if (CGRectGetHeight(t->rect) > 10 && (!row || CGRectGetMinY(t->rect) > CGRectGetMinY(row->rect))) row = t;
    }
    if (!DPOn[DPNestedFolders] || !dragging || !row) return first;
    // A level shallower than the row, or a folder's end, close enough to the pointer to mean "out of here".
    const DPDropTarget *options[64];
    int n = 0;
    options[n++] = row;
    for (int64_t i = 0; i < count && n < 64; i++) {
        const DPDropTarget *t = &targets[i];
        CGFloat gap = y < CGRectGetMinY(t->rect) ? CGRectGetMinY(t->rect) - y : y >= CGRectGetMaxY(t->rect) ? y - CGRectGetMaxY(t->rect) : 0;
        if (t != row && gap <= 14 && (CGRectGetHeight(t->rect) <= 10 || DPTargetDepth(t) < DPTargetDepth(row)) && t->section == row->section)
            options[n++] = t;
    }
    if (n == 1) {
        // A collapsed folder's "inside" target reaching down from the row above only takes the row's top.
        if (first != row && DPTargetDepth(first) > DPTargetDepth(row) && y >= CGRectGetMinY(row->rect) + 8) return row;
        return first;
    }
    int64_t wanted = MAX(0, (int64_t)floor((x - 4) / 19));
    const DPDropTarget *best = row;
    for (int i = 1; i < n; i++) {
        int64_t d = DPTargetDepth(options[i]), bestD = DPTargetDepth(best);
        int64_t distance = llabs(d - wanted), bestDistance = llabs(bestD - wanted);
        if (distance < bestDistance || (distance == bestDistance && d > bestD)) best = options[i];
    }
    return best;
}

static NSString *DPStringFromSwift(DPString string);

// The folder the drag in progress would drop into (nil for none) and its target's rect, for DPTabList_performDrag.
static NSString *DPDragFolderID;
static CGRect DPDragFolderRect;

__attribute__((used, visibility("hidden"))) void DPHitTest(void *layout, double x, double y, uint64_t *result) {
    result[0] = result[1] = result[2] = 0;
    Ivar ivar = class_getInstanceVariable(object_getClass((__bridge id)layout), "dropTargets");
    const uint8_t *array = ivar ? *(const uint8_t *const *)((const uint8_t *)layout + ivar_getOffset(ivar)) : NULL;
    if (!array) return;
    // Clicks find the folder under the pointer through here too; only a drag gets the indent-aware pick.
    Ivar dragState = class_getInstanceVariable(object_getClass((__bridge id)layout), "dragDropState");
    BOOL dragging = dragState && ((const uint64_t *)((const uint8_t *)layout + ivar_getOffset(dragState)))[1] != 0;
    const DPDropTarget *t = DPPickDropTarget((const void *)(array + 0x20), *(const int64_t *)(array + 0x10), x, y, dragging);
    if (dragging) {
        int64_t depth = t ? DPTargetDepth(t) : 0;
        DPDragFolderID = depth ? DPStringFromSwift(((const DPGroupComponent *)(t->ancestry + 0x20))[depth - 1].groupID) : nil;
        DPDragFolderRect = t ? t->rect : CGRectZero;
    }
    if (!t) return;
    result[0] = t->section;
    result[1] = (uint64_t)t->index;
    result[2] = (uint64_t)t->ancestry;
    ((void (*)(const void *))dlsym(RTLD_DEFAULT, "swift_bridgeObjectRetain"))(t->ancestry);
}

// The layout is in x20 and the point in d0/d1; the target comes back in x0-x2.
__attribute__((naked)) static void DPHitTestShim(void) {
    __asm__ volatile(
        "stp x29, x30, [sp, #-48]!\n"
        "mov x29, sp\n"
        "mov x0, x20\n"
        "add x1, sp, #16\n"
        "bl _DPHitTest\n"
        "ldp x0, x1, [sp, #16]\n"
        "ldr x2, [sp, #32]\n"
        "ldp x29, x30, [sp], #48\n"
        "ret\n");
}

// A cbz's or b.cond's target, from its 19-bit word offset.
static uintptr_t DPCbzTarget(const uint8_t *at) {
    int32_t imm = (int32_t)(*(const uint32_t *)at << 8) >> 13;
    return (uintptr_t)at + imm * 4;
}

static uintptr_t DPBlTarget(const uint8_t *at) {
    int32_t imm = (int32_t)(*(const uint32_t *)at << 6) >> 6;
    return (uintptr_t)at + imm * 4;
}

// An adrp/add pair's address, or 0 if the two instructions aren't one into the same register.
static uintptr_t DPAdrpAddTarget(const uint8_t *at) {
    uint32_t adrp = ((const uint32_t *)at)[0], add = ((const uint32_t *)at)[1];
    if ((adrp & 0x9f000000) != 0x90000000 || (add & 0xffc00000) != 0x91000000 || (add & 31) != (adrp & 31) || ((add >> 5) & 31) != (adrp & 31))
        return 0;
    int64_t pages = (int64_t)(((adrp >> 5) & 0x7ffff) << 2 | ((adrp >> 29) & 3)) << 43 >> 43;
    return ((uintptr_t)at & ~(uintptr_t)0xfff) + pages * 0x1000 + ((add >> 10) & 0xfff);
}

// What Dia passes alongside each DynamicDependency getter; read from the validator, which fetches one.
static uintptr_t DPDependencyContext;

static BOOL DPFindLocationSite(uint8_t *text, unsigned long size) {
    uint8_t *function = memmem(text, size, DPLocationPrologue, sizeof DPLocationPrologue);
    uint8_t *site = function ? function + DPLocationOffset : NULL;
    if (!site || site + 0x28 > text + size) return NO;
    const uint32_t *words = (const uint32_t *)site;
    for (int i = 0; i < 8; i++)
        if (DPLocationSite[i] && words[i] != DPLocationSite[i]) return NO;
    if ((words[2] & 0xff00001f) != 0x54000001 || (words[8] & 0xfc000000) != 0x94000000) return NO;  // b.ne, bl
    DPLocationSame = (uintptr_t)site + 0x10;
    DPLocationCopied = (uintptr_t)site + 0x24;
    DPLocationAncestor = DPCbzTarget(site + 8);
    DPLocationCopyParent = DPBlTarget(site + 0x20);
    return YES;
}

static void DPFindFolderSpacing(uint8_t *layout);

// Runs before Dia starts its threads, so nothing executes these pages while they're writable.
static BOOL DPInstallNestedFolders(void) {
    DPStringEquals = dlsym(RTLD_DEFAULT, "$sSS2eeoiySbSS_SStFZ");
    DPNestingSwitch = &DPOn[DPNestedFolders];
    unsigned long size = 0;
    uint8_t *text = getsectiondata((const struct mach_header_64 *)_dyld_get_image_header(0), "__TEXT", "__text", &size);
    uint8_t *validate = text && DPStringEquals ? memmem(text, size, DPValidatePrologue, sizeof DPValidatePrologue) : NULL;
    uint8_t *layout = text ? memmem(text, size, DPLayoutPrologue, sizeof DPLayoutPrologue) : NULL;
    if (!validate || validate + DPAcceptOffset > text + size
        || memcmp(validate + DPCheckOffset, DPValidateCheck, sizeof DPValidateCheck) != 0 || !layout)
        return NO;
    BOOL inPlace = DPFindLocationSite(text, size);
    DPDependencyContext = DPAdrpAddTarget(validate + DPContextOffset);
    DPFindFolderSpacing(layout);
    uint8_t *sites[2];
    for (int i = 0; i < 2; i++) {
        sites[i] = layout + DPLayoutSites[i];
        uint32_t cbz = *(const uint32_t *)sites[i];
        if (sites[i] + 16 > text + size || (cbz & 0xff00001f) != 0xb4000008 || memcmp(sites[i] + 4, DPLayoutScan, sizeof DPLayoutScan) != 0)
            return NO;
    }
    DPLayoutScan0 = (uintptr_t)sites[0] + 16, DPLayoutNoGroup0 = DPCbzTarget(sites[0]);
    DPLayoutScan1 = (uintptr_t)sites[1] + 16, DPLayoutNoGroup1 = DPCbzTarget(sites[1]);
    DPNestAccept = (uintptr_t)validate + DPAcceptOffset;
    DPNestReject = (uintptr_t)validate + DPRejectOffset;
    BOOL ok = DPRedirect(validate + DPRedirectOffset, DPNestShim) && DPRedirect(sites[0], DPLayoutShim0) && DPRedirect(sites[1], DPLayoutShim1);
    DPSubfolderMenuAvailable = ok && inPlace && DPRedirect((uint8_t *)DPLocationSame - 0x10, DPLocationShim);
    uint8_t *hitTest = memmem(text, size, DPHitTestPrologue, sizeof DPHitTestPrologue);
    if (ok && hitTest && hitTest + DPHitTestStrideOffset + 4 <= text + size
        && *(const uint32_t *)(hitTest + DPHitTestStrideOffset) == DPHitTestStride)
        DPRedirect(hitTest, DPHitTestShim);
    uint8_t *cleanup = memmem(text, size, DPCleanupPrologue, sizeof DPCleanupPrologue);
    uint8_t *check = cleanup ? cleanup + DPCleanupOffset : NULL;
    if (ok && check && check + 16 <= text + size && memcmp(check, DPCleanupSite, sizeof DPCleanupSite) == 0
        && (*(const uint32_t *)(check + 12) & 0xff00001f) == 0xb4000008) {  // cbz x8
        DPCleanupKeep = (uintptr_t)check + 16;
        DPCleanupDelete = DPCbzTarget(check + 12);
        DPRedirect(check, DPCleanupShim);
    }
    return ok;
}

static BOOL DPNestedFoldersAvailable;

// "New Subfolder" in a folder's menu makes a new folder among the window's tabs and moves it into this one. New Group
// with Tab on a tab inside the folder does nothing in the bookmarks section; a move works in both.
static NSMenuItem *DPItemWithShortcut(NSMenu *menu, NSString *key, NSEventModifierFlags modifiers) {
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.keyEquivalent isEqualToString:key] && (item.keyEquivalentModifierMask & NSEventModifierFlagDeviceIndependentFlagsMask) == modifiers)
            return item;
        NSMenuItem *found = item.submenu ? DPItemWithShortcut(item.submenu, key, modifiers) : nil;
        if (found) return found;
    }
    return nil;
}

static NSMenu *DPRowMenu(NSView *row);
static NSMenuItem *DPMenuItemTitled(NSMenu *menu, NSString *prefix);
static void DPCollectTabRows(NSView *view, NSMutableArray<NSView *> *rows);
static NSString *DPTabIDOfRow(NSView *row);
static NSString *DPStripFolderID(NSView *view);
static void DPNewSubfolder(NSWindow *window, NSString *folderID);
static NSString *DPScriptString(NSString *string);
static NSString *DPRunScript(NSString *body, NSString *what);
static NSString *DPWindowRef(NSWindow *window);

// A folder can't be empty, so a new one starts with a new tab: this runs New Group with Tab from that tab's own row,
// once the row is there. The menu bar's item is only the fallback, since Dia can leave it disabled on a new tab.
static void DPGroupNewTab(NSWindow *window, NSString *tabID, int tries) {
    NSMutableArray<NSView *> *rows = [NSMutableArray array];
    if (window.contentView.superview) DPCollectTabRows(window.contentView.superview, rows);
    NSView *row = nil;
    for (NSView *candidate in rows) if ([DPTabIDOfRow(candidate) isEqual:tabID]) row = candidate;
    NSMenuItem *group = row ? DPMenuItemTitled(DPRowMenu(row), @"New Group with Tab") : nil;
    if (group) {
        BOOL sent = [NSApp sendAction:group.action to:group.target from:group];
        NSLog(@"[DiaPatches] new folder: row's item sent %d after %d tries", sent, tries);
        return;
    }
    if (tries < 40) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ DPGroupNewTab(window, tabID, tries + 1); });
        return;
    }
    NSMenuItem *fallback = DPItemWithShortcut(NSApp.mainMenu, @"n", NSEventModifierFlagControl | NSEventModifierFlagCommand);
    NSLog(@"[DiaPatches] new folder: row found %d, menu bar item %d", row != nil, fallback != nil);
    if (fallback) [fallback.menu performActionForItemAtIndex:[fallback.menu indexOfItem:fallback]];
}

// A new folder among the window's own tabs.
static NSString *DPNewFolder(NSWindow *window) {
    NSString *tabID = DPRunScript([NSString stringWithFormat:@"set newTab to make new tab at end of tabs of %@\nfocus newTab\nreturn id of newTab", DPWindowRef(window)], @"making the folder's tab");
    if (tabID.length) DPGroupNewTab(window, tabID, 0);
    return tabID;
}

@interface DPSubfolderAction : NSObject
@end

@implementation DPSubfolderAction
- (void)newSubfolder:(NSMenuItem *)sender {
    DPNewSubfolder(NSApp.keyWindow, sender.representedObject);
}
@end

static void DPAddSubfolderItem(NSMenu *menu) {
    static DPSubfolderAction *action;
    if (!DPOn[DPNestedFolders] || !DPSubfolderMenuAvailable) return;
    NSMenuItem *newTab = nil;
    for (NSMenuItem *item in menu.itemArray) {
        if (item.action == @selector(newSubfolder:)) return;
        if ([item.keyEquivalent isEqualToString:@"t"] && (item.keyEquivalentModifierMask & NSEventModifierFlagDeviceIndependentFlagsMask) == (NSEventModifierFlagOption | NSEventModifierFlagCommand)
            && DPIsKind((id)item.target, @"ARCUI.CallbackMenuItem"))
            newTab = item;
    }
    if (!newTab) return;
    NSEvent *click = NSApp.currentEvent;
    if (click.type != NSEventTypeRightMouseDown && click.type != NSEventTypeLeftMouseDown) return;
    NSView *root = click.window.contentView.superview;
    NSView *cell = root ? [root hitTest:[root convertPoint:click.locationInWindow fromView:nil]] : nil;
    while (cell && !DPIsKind(cell, @"TabUI.TabGroupCellView") && !DPIsKind(cell, @"TabUI.TabGroupView")) cell = cell.superview;
    NSString *folderID = cell ? DPStripFolderID(cell) : nil;
    if (!folderID) return;
    action = action ?: [DPSubfolderAction new];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"New Subfolder" action:@selector(newSubfolder:) keyEquivalent:@""];
    item.target = action;
    item.representedObject = folderID;
    item.image = [NSImage imageWithSystemSymbolName:@"folder.badge.plus" accessibilityDescription:nil];
    [menu insertItem:item atIndex:[menu indexOfItem:newTab] + 1];
}

static void DPTakeOverSpaceMoves(NSMenu *menu, NSMenu *spaces);

#pragma mark - Arc-style bookmarks

// Dia's sidebar bookmarks are pinned tabs. Whether a row is one, and its commands, come from the row's own context menu.

// The row's context menu, as Dia builds it for a right click at the row's centre.
static NSMenu *DPRowMenu(NSView *row) {
    NSWindow *w = row.window;
    if (!w) return nil;
    NSPoint p = [row convertPoint:NSMakePoint(NSMidX(row.bounds), NSMidY(row.bounds)) toView:nil];
    NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:p modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                                windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
    for (NSView *v = row; v && !DPIsKind(v, @"TabList.TabListView"); v = v.superview) {
        NSMenu *menu = [v menuForEvent:e];
        if (menu && !menu.numberOfItems && [menu.delegate respondsToSelector:@selector(menuNeedsUpdate:)]) [menu.delegate menuNeedsUpdate:menu];
        if (!menu.numberOfItems) continue;
        // It was never shown: tell Dia it closed, so the row doesn't stay in its context-menu state.
        if ([menu.delegate respondsToSelector:@selector(menuDidClose:)]) [menu.delegate menuDidClose:menu];
        return menu;
    }
    return nil;
}

static NSMenuItem *DPMenuItemTitled(NSMenu *menu, NSString *prefix) {
    for (NSMenuItem *item in menu.itemArray) if ([item.title hasPrefix:prefix]) return item;
    return nil;
}

// Arc had "replace the bookmark's URL with the current page" right in a bookmark's menu; Dia keeps it under Edit
// Pinned Page. This adds it at the top level, running Dia's own item (and greyed out when Dia's is).
@interface DPMenuProxy : NSObject
@end
@implementation DPMenuProxy
- (void)perform:(NSMenuItem *)sender {
    NSMenuItem *source = sender.representedObject;
    [NSApp sendAction:source.action to:source.target from:source];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item { return ((NSMenuItem *)item.representedObject).enabled; }
@end

static void DPAddReplaceURLItem(NSMenu *menu) {
    static DPMenuProxy *proxy;
    if (!DPOn[DPArcBookmarks]) return;
    NSMenuItem *edit = DPMenuItemTitled(menu, @"Edit Pinned Page");
    NSMenuItem *source = DPMenuItemTitled(edit.submenu, @"Replace Pinned URL");
    if (!source) return;
    for (NSMenuItem *item in menu.itemArray) if (item.representedObject == source) return;
    proxy = proxy ?: [DPMenuProxy new];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Replace Bookmark URL with Current" action:@selector(perform:) keyEquivalent:@""];
    item.target = proxy;
    item.representedObject = source;
    item.image = source.image ?: [NSImage imageWithSystemSymbolName:@"arrow.triangle.2.circlepath" accessibilityDescription:nil];
    [menu insertItem:item atIndex:[menu indexOfItem:edit]];
}

// Double-clicking a bookmark's name edits it in place, as in Arc. Dia only renames through its Rename… dialog, so
// committing opens that dialog hidden, types the name into its field and presses Save.
static NSString *const DPDialogPanelClass = @"_TtCC6Dialog27DialogPanelWindowControllerP33_BFC2D77BC81244121B5E5CD87796ED535Panel";
static NSString *DPPendingName;  // the name to type into the next Rename… dialog

static char DPDialogClosedKey, DPDialogHiddenKey;
static const NSPoint DPOffscreen = {-30000, -30000};

static BOOL DPDialogHidden(NSWindow *window) { return objc_getAssociatedObject(window, &DPDialogHiddenKey) != nil; }

// While a dialog is being filled in for an in-place rename, Dia's own fade-in and placement can't bring it on screen.
static void DPDialog_setAlphaValue(NSWindow *self, SEL _cmd, CGFloat alpha) {
    DPCallOriginal(void (*)(id, SEL, CGFloat), self, _cmd, DPDialogHidden(self) ? 0 : alpha);
}

static void DPDialog_setFrameDisplay(NSWindow *self, SEL _cmd, NSRect frame, BOOL display) {
    if (DPDialogHidden(self)) frame.origin = DPOffscreen;
    DPCallOriginal(void (*)(id, SEL, NSRect, BOOL), self, _cmd, frame, display);
}

static void DPDialog_setFrameDisplayAnimate(NSWindow *self, SEL _cmd, NSRect frame, BOOL display, BOOL animate) {
    if (DPDialogHidden(self)) frame.origin = DPOffscreen, animate = NO;
    DPCallOriginal(void (*)(id, SEL, NSRect, BOOL, BOOL), self, _cmd, frame, display, animate);
}

// Puts a hidden dialog back to normal, for whatever Dia shows in it next.
static void DPUnhideDialog(NSWindow *dialog) {
    NSArray *saved = objc_getAssociatedObject(dialog, &DPDialogHiddenKey);
    if (![saved isKindOfClass:NSArray.class]) return;
    objc_setAssociatedObject(dialog, &DPDialogHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dialog.animationBehavior = [saved[1] integerValue];
    [dialog setFrame:[saved[0] rectValue] display:NO];
    dialog.alphaValue = 1;
}

// Types `name` into the dialog's field and presses Save. YES if that closed it.
static BOOL DPFillRenameDialog(NSWindow *dialog, NSString *name) {
    NSTextField *field = (NSTextField *)DPFindView(dialog.contentView, ^BOOL(NSView *v) { return DPIsKind(v, @"ARCUI.MaskedTextField"); });
    NSButton *save = (NSButton *)DPFindView(dialog.contentView, ^BOOL(NSView *v) {
        return DPIsKind(v, @"Dialog.DialogButton") && [((NSButton *)v).title isEqualToString:@"Save"];
    });
    if (!field || !save || ![dialog makeFirstResponder:field]) return NO;
    NSTextView *editor = (NSTextView *)field.currentEditor;
    [editor selectAll:nil];
    [editor insertText:name replacementRange:editor.selectedRange];  // typed, so the dialog's delegate sees it
    [save performClick:nil];
    return [objc_getAssociatedObject(dialog, &DPDialogClosedKey) boolValue];
}

// The dialog for a pending name opens off screen and see-through, is filled in and saved, and closes unseen.
// Only if that doesn't close it does it come back where Dia put it, for the name to be saved by hand.
static void DPDialog_orderWindow(NSWindow *self, SEL _cmd, NSWindowOrderingMode place, NSInteger other) {
    if (place == NSWindowOut) {
        objc_setAssociatedObject(self, &DPDialogClosedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        DPCallOriginal(void (*)(id, SEL, NSWindowOrderingMode, NSInteger), self, _cmd, place, other);
        return DPUnhideDialog(self);
    }
    NSString *name = place != NSWindowOut ? DPPendingName : nil;
    if (!name) return DPCallOriginal(void (*)(id, SEL, NSWindowOrderingMode, NSInteger), self, _cmd, place, other);
    DPPendingName = nil;
    objc_setAssociatedObject(self, &DPDialogClosedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &DPDialogHiddenKey, @[[NSValue valueWithRect:self.frame], @(self.animationBehavior)], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.animationBehavior = NSWindowAnimationBehaviorNone;
    self.alphaValue = 0;
    [self setFrameOrigin:DPOffscreen];
    DPCallOriginal(void (*)(id, SEL, NSWindowOrderingMode, NSInteger), self, _cmd, place, other);
    BOOL saved = DPFillRenameDialog(self, name);
    // Dia may finish building the dialog on the next turn: try once more then, and show it if it's still open.
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL closed = saved || [objc_getAssociatedObject(self, &DPDialogClosedKey) boolValue] || DPFillRenameDialog(self, name);
        if (!closed) DPUnhideDialog(self);
    });
}

// A dialog that was never on screen may close without ordering out.
static void DPDialog_close(NSWindow *self, SEL _cmd) {
    objc_setAssociatedObject(self, &DPDialogClosedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
    DPUnhideDialog(self);
}

@interface DPRenameField : NSTextField <NSTextFieldDelegate>
@property (nonatomic, strong) NSMenuItem *rename;
@property (nonatomic, copy) NSString *original;
@property (nonatomic) BOOL done;
@property (nonatomic, strong) id monitor;  // a click anywhere else, or switching apps, leaves the name as it was
@end

@implementation DPRenameField
- (void)finish:(BOOL)commit {
    if (self.done) return;
    self.done = YES;
    NSString *name = [self.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSWindow *window = self.window;
    if (self.monitor) [NSEvent removeMonitor:self.monitor];
    self.monitor = nil;
    [self removeFromSuperview];
    [window makeFirstResponder:nil];
    if (!commit || !name.length || [name isEqualToString:self.original] || !self.rename.enabled) return;
    DPPendingName = name;
    [NSApp sendAction:self.rename.action to:self.rename.target from:self.rename];
    // If no dialog came, don't type into a later one.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ DPPendingName = nil; });
}
- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (sel == @selector(cancelOperation:)) { [self finish:NO]; return YES; }
    if (sel == @selector(insertNewline:)) { [self finish:YES]; return YES; }
    return NO;
}
- (void)controlTextDidEndEditing:(NSNotification *)n { [self finish:NO]; }  // only Return renames
@end

static void DPWatchBookmarkDoubleClicks(void) {
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent *(NSEvent *e) {
        if (!DPOn[DPArcBookmarks] || e.clickCount != 2) return e;
        NSView *root = e.window.contentView.superview;
        NSView *hit = [root hitTest:[root convertPoint:e.locationInWindow fromView:nil]];
        if ([hit isKindOfClass:NSControl.class] && ![hit isKindOfClass:NSTextField.class]) return e;  // its own buttons
        NSView *row = hit;
        while (row && !DPIsKind(row, @"TabUI.TabContentView")) row = row.superview;
        if (!row) return e;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMenu *menu = DPRowMenu(row);
            NSMenuItem *rename = DPMenuItemTitled(menu, @"Unpin") ? DPMenuItemTitled(menu, @"Rename") : nil;
            NSTextField *label = (NSTextField *)DPFindView(row, ^BOOL(NSView *v) {
                return [v isKindOfClass:NSTextField.class] && !v.hidden && ((NSTextField *)v).stringValue.length;
            });
            if (!rename.enabled || !label) return;
            NSRect frame = [row convertRect:label.frame fromView:label.superview];
            frame.size.width = MAX(NSWidth(frame), NSWidth(row.bounds) - NSMinX(frame) - 8);
            frame = NSInsetRect(frame, -3, 0);  // same height and position, so the text stays where it was
            DPRenameField *field = [[DPRenameField alloc] initWithFrame:frame];
            field.rename = rename;
            field.original = label.stringValue;
            field.stringValue = label.stringValue;
            field.font = label.font;
            field.textColor = NSColor.labelColor;
            field.bezeled = NO;
            field.drawsBackground = YES;
            field.backgroundColor = NSColor.textBackgroundColor;
            field.focusRingType = NSFocusRingTypeNone;
            field.wantsLayer = YES;
            field.layer.cornerRadius = 4;
            field.cell.scrollable = YES;
            field.cell.wraps = NO;
            field.delegate = field;
            [row addSubview:field];
            __weak DPRenameField *weakField = field;
            field.monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown
                                                                  handler:^NSEvent *(NSEvent *click) {
                DPRenameField *f = weakField;
                NSPoint p = click.window == f.window ? [f convertPoint:click.locationInWindow fromView:nil] : NSMakePoint(-1, -1);
                if (f && !NSPointInRect(p, f.bounds)) [f finish:NO];
                return click;
            }];
            [row.window makeFirstResponder:field];
            [field.currentEditor selectAll:nil];
        });
        return e;
    }];
}

#pragma mark - Tidy tabs

// Sort and Group text buttons on the line between bookmarks and tabs, left of Dia's Close All and shown with it
// while the pointer is over the line; and the same two in a tab's menu.
static NSHashTable<NSView *> *DPSeparators;
static void DPTidySort(NSWindow *window);
static void DPApplyPhoneAccess(void);
static void DPTidyGroup(NSWindow *window);
static char DPSeparatorToolsKey;

static NSWindow *DPBrowserWindow(NSWindow *window) {
    return DPIsKind((id)window, @"Window.PlatformWindow") ? window : nil;
}

@interface DPSeparatorTools : NSView
@property (nonatomic, strong) NSStackView *buttons;
@property (nonatomic) BOOL hovering;
@end

@implementation DPSeparatorTools
- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    NSMutableArray *views = [NSMutableArray array];
    for (NSString *title in @[@"Sort", @"Group"]) {
        NSButton *b = [NSButton buttonWithTitle:title target:self action:@selector(tap:)];
        b.bordered = NO;
        b.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: NSColor.tertiaryLabelColor}];
        b.toolTip = [title isEqualToString:@"Sort"] ? @"Sort tabs by site" : @"Group tabs from the same site";
        [views addObject:b];
    }
    _buttons = [NSStackView stackViewWithViews:views];
    _buttons.spacing = 10;
    _buttons.hidden = YES;
    [self addSubview:_buttons];
    return self;
}
- (NSView *)hitTest:(NSPoint)p {
    NSView *hit = [super hitTest:p];
    return hit && hit != self && !self.buttons.hidden ? hit : nil;  // clicks elsewhere reach Dia's line
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)e { self.hovering = YES; self.superview.needsLayout = YES; }
- (void)mouseExited:(NSEvent *)e { self.hovering = NO; self.superview.needsLayout = YES; }
- (void)tap:(NSButton *)sender {
    NSWindow *w = DPBrowserWindow(self.window);
    if (!w) return;
    if ([sender.title isEqualToString:@"Sort"]) DPTidySort(w);
    else DPTidyGroup(w);
}
@end

static void DPSeparator_layout(NSView *self, SEL _cmd) {
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
    [DPSeparators addObject:self];
    DPSeparatorTools *tools = objc_getAssociatedObject(self, &DPSeparatorToolsKey);
    if (!tools) {
        tools = [[DPSeparatorTools alloc] initWithFrame:self.bounds];
        objc_setAssociatedObject(self, &DPSeparatorToolsKey, tools, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (tools.superview != self) [self addSubview:tools positioned:NSWindowAbove relativeTo:nil];
    tools.frame = self.bounds;
    NSView *closeAll = nil;
    for (NSView *v in self.subviews) if ([NSStringFromClass(v.class) containsString:@"CloseAllButton"]) closeAll = v;
    BOOL show = DPOn[DPTidyTabs] && tools.hovering && closeAll && DPTabsAvailable();
    tools.buttons.hidden = !show;
    if (!show) return;
    NSSize size = tools.buttons.fittingSize;
    CGFloat right = NSMinX(closeAll.frame) - 10;
    tools.buttons.frame = NSMakeRect(right - size.width, NSMidY(closeAll.frame) - size.height / 2, size.width, size.height);
    // Dia's line (a 1pt layer) stops before Close All; make it stop before these too.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *l in self.layer.sublayers)
        if (NSHeight(l.frame) <= 2 && l.backgroundColor && NSMaxX(l.frame) > NSMinX(tools.buttons.frame) - 8)
            l.frame = NSMakeRect(NSMinX(l.frame), NSMinY(l.frame), MAX(0, NSMinX(tools.buttons.frame) - 8 - NSMinX(l.frame)), NSHeight(l.frame));
    [CATransaction commit];
}

static void DPRefreshSeparators(void) {
    for (NSView *v in DPSeparators.allObjects) v.needsLayout = YES;
}

// The tab list takes clicks on its line before they reach subviews, so the buttons' clicks are taken here.
static void DPWatchSeparatorClicks(void) {
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent *(NSEvent *e) {
        if (!DPOn[DPTidyTabs]) return e;
        for (NSView *separator in DPSeparators.allObjects) {
            DPSeparatorTools *tools = objc_getAssociatedObject(separator, &DPSeparatorToolsKey);
            if (separator.window != e.window || tools.buttons.hidden) continue;
            for (NSButton *b in tools.buttons.arrangedSubviews) {
                if (!NSPointInRect([b convertPoint:e.locationInWindow fromView:nil], b.bounds)) continue;
                [tools tap:b];
                return nil;
            }
        }
        return e;
    }];
}

@interface DPTidyAction : NSObject
@end
@implementation DPTidyAction
- (void)newFolder:(NSMenuItem *)sender { DPNewFolder(NSApp.keyWindow); }
- (void)sort:(id)sender { NSWindow *w = DPBrowserWindow(NSApp.mainWindow); if (w) DPTidySort(w); }
- (void)group:(id)sender { NSWindow *w = DPBrowserWindow(NSApp.mainWindow); if (w) DPTidyGroup(w); }
@end

static BOOL DPSidebarBackgroundClick;  // the menu about to open is for the sidebar's empty space

// A tab's menu (the one with Close Other Tabs) and the sidebar's empty space get Sort Tabs by Site and Group Tabs by Site.
static void DPAddTidyItems(NSMenu *menu) {
    static DPTidyAction *action;
    BOOL background = DPSidebarBackgroundClick;
    DPSidebarBackgroundClick = NO;
    if (!DPOn[DPTidyTabs] || !DPTabsAvailable() || menu.supermenu) return;
    NSMenuItem *closeOthers = DPMenuItemTitled(menu, @"Close Other Tabs");
    if (!closeOthers && !background) return;
    action = action ?: [DPTidyAction new];
    for (NSMenuItem *item in menu.itemArray) if (item.target == action) return;
    NSMenuItem *close = closeOthers ? DPMenuItemTitled(menu, @"Close") : nil;
    NSInteger at = close ? [menu indexOfItem:close] : menu.numberOfItems;
    if (menu.numberOfItems) [menu insertItem:NSMenuItem.separatorItem atIndex:close ? at : at++];
    NSArray *items = @[@[@"Sort Tabs by Site", @"sort:", @"arrow.up.arrow.down"], @[@"Group Tabs by Site", @"group:", @"folder.badge.plus"]];
    if (background) items = [@[@[@"New Folder", @"newFolder:", @"folder"]] arrayByAddingObjectsFromArray:items];
    for (NSArray *spec in items.reverseObjectEnumerator) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:spec[0] action:NSSelectorFromString(spec[1]) keyEquivalent:@""];
        item.target = action;
        item.image = [NSImage imageWithSystemSymbolName:spec[2] accessibilityDescription:nil];
        [menu insertItem:item atIndex:at];
    }
}

// New Tab in the sidebar: the command bar instead of Dia's new tab page.
static void DPWatchNewTabClicks(void) {
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent *(NSEvent *e) {
        if (!DPOn[DPNewTabBar] || !DPBrowserWindow(e.window)) return e;
        NSView *root = e.window.contentView.superview;
        for (NSView *v = [root hitTest:[root convertPoint:e.locationInWindow fromView:nil]]; v; v = v.superview)
            if ((DPIsKind(v, @"TabList.NewTabCellView") || DPIsKind(v, @"TabList.NewTabStickyView")) && DPArcBarOpenNewTab(e.window)) return nil;
        return e;
    }];
}

// Right-clicking the sidebar's empty space: Dia's menu for it gets the two items; with none, a menu of just them.
static void DPWatchSidebarBackgroundClicks(void) {
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskRightMouseDown handler:^NSEvent *(NSEvent *e) {
        if (!DPOn[DPTidyTabs] || !DPTabsAvailable() || !DPBrowserWindow(e.window)) return e;
        NSView *root = e.window.contentView.superview;
        NSView *hit = [root hitTest:[root convertPoint:e.locationInWindow fromView:nil]];
        NSView *list = nil;
        for (NSView *v = hit; v; v = v.superview) {
            if ([v isKindOfClass:NSControl.class] || DPIsKind(v, @"TabUI.TabView") || DPIsKind(v, @"TabUI.TabGroupCellView") ||
                DPIsKind(v, @"TabList.NewTabCellView") || DPIsKind(v, @"TabList.TabListSeparatorView"))
                return e;
            if (DPIsKind(v, @"TabList.TabListView")) { list = v; break; }
        }
        if (!list) return e;
        for (NSView *v = hit; v && v != list.superview; v = v.superview)
            if ([v menuForEvent:e].numberOfItems) { DPSidebarBackgroundClick = YES; return e; }
        NSMenu *menu = [NSMenu new];
        DPSidebarBackgroundClick = YES;
        DPAddTidyItems(menu);
        [NSMenu popUpContextMenu:menu withEvent:e forView:hit];
        return nil;
    }];
}

#pragma mark - Arc folders

// Dia imports Arc's folders flattened, one top-level folder per Arc folder in sidebar order. Restoring reads Arc's
// StorableSidebar.json and moves each imported folder back into its parent through Dia's own moveTabItems, reached
// from a TabListView: viewModel > delegate (TabListController) > its WindowTabUtilities and TabQueryUtilities.
typedef struct { uint64_t x0, x1; } DPPair;

// Calls a Swift closure or getter: x20 is its context, x0-x3 its arguments, x8 an indirect result.
__attribute__((naked)) static DPPair DPSwiftCall4(void *fn, void *context, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, void *result) {
    __asm__ volatile(
        "stp x29, x30, [sp, #-32]!\n"
        "mov x29, sp\n"
        "stp x20, x21, [sp, #16]\n"
        "mov x16, x0\n"
        "mov x20, x1\n"
        "mov x0, x2\n"
        "mov x1, x3\n"
        "mov x2, x4\n"
        "mov x3, x5\n"
        "mov x8, x6\n"
        "blr x16\n"
        "ldp x20, x21, [sp, #16]\n"
        "ldp x29, x30, [sp], #32\n"
        "ret\n");
}

static DPPair DPSwiftCall(void *fn, void *context, uint64_t a0, uint64_t a1, void *result) {
    return DPSwiftCall4(fn, context, a0, a1, 0, 0, result);
}

static uint64_t DPClassFieldOffset(const void *object, int index) {
    const uint8_t *metadata = *(const uint8_t *const *)object;
    const uint8_t *descriptor = *(const uint8_t *const *)(metadata + 0x40);
    return ((const uint64_t *)metadata)[*(const uint32_t *)(descriptor + 40) + index];
}

static NSString *DPStringFromSwift(DPString string) {
    uint8_t top = string.object >> 56;
    if (top & 0x20) {  // small: bytes inline, count in the low nibble
        char bytes[16];
        memcpy(bytes, &string.bits, 8);
        memcpy(bytes + 8, &string.object, 8);
        return [[NSString alloc] initWithBytes:bytes length:top & 0xf encoding:NSUTF8StringEncoding];
    }
    uintptr_t address = string.object & 0x0fffffffffffffff;
    if (!address) return nil;
    if (top & 0x40) return [(__bridge NSString *)(void *)address copy];  // bridged NSString
    return [[NSString alloc] initWithBytes:(const void *)(address + 0x20) length:string.bits & 0xffffffffffff encoding:NSUTF8StringEncoding];
}

typedef struct {
    void *controller;
    int spaceField;                       // the controller's spaceID field
    uint8_t tabs[0x340], queries[0x340];  // WindowTabUtilities and TabQueryUtilities: closures of 16 bytes each
} DPTabUtilities;

// The sidebar's TabListController, or in top tabs the TabStripController: view > viewModel > delegate.
// Fields: WindowTabUtilities, TabQueryUtilities and spaceID getters.
static const struct { const char *view, *controller; int delegateField, tabsField, queriesField, spaceField; } DPTabControllers[] = {
    {"TabList.TabListView", "TabList.TabListController", 5, 15, 11, 17},
    {"TabStrip.TabStripContainerView", "TabStrip.TabStripController", 3, 19, 13, 21},
};

static void *DPTabController(NSView *view, int *kind) {
    for (int k = 0; k < 2; k++) {
        if (![NSStringFromClass(view.class) isEqualToString:@(DPTabControllers[k].view)]) continue;
        if (view.hiddenOrHasHiddenAncestor || NSIsEmptyRect(view.visibleRect)) return NULL;
        Ivar ivar = class_getInstanceVariable(view.class, "viewModel");
        void *model = ivar ? (__bridge void *)object_getIvar(view, ivar) : NULL;
        void *(*loadWeak)(void *) = dlsym(RTLD_DEFAULT, "swift_weakLoadStrong");
        void *controller = model && loadWeak ? loadWeak((uint8_t *)model + DPClassFieldOffset(model, DPTabControllers[k].delegateField)) : NULL;
        if (controller && strcmp(class_getName(object_getClass((__bridge id)controller)), DPTabControllers[k].controller) == 0) {
            *kind = k;
            return controller;
        }
        if (controller) ((void (*)(void *))dlsym(RTLD_DEFAULT, "swift_release"))(controller);
        return NULL;
    }
    for (NSView *sub in view.subviews) {
        void *found = DPTabController(sub, kind);
        if (found) return found;
    }
    return NULL;
}

// From `window`, or else the frontmost window with a visible tab list or strip.
static BOOL DPLoadTabUtilitiesIn(DPTabUtilities *utilities, NSWindow *window) {
    if (!DPDependencyContext) return NO;
    int kind = 0;
    for (NSWindow *w in window ? @[window] : NSApp.orderedWindows)
        if (!utilities->controller) utilities->controller = DPTabController(w.contentView.superview ?: w.contentView, &kind);
    if (!utilities->controller) return NO;
    utilities->spaceField = DPTabControllers[kind].spaceField;
    for (int i = 0; i < 2; i++) {
        int field = i ? DPTabControllers[kind].queriesField : DPTabControllers[kind].tabsField;
        void **getter = (void **)((uint8_t *)utilities->controller + DPClassFieldOffset(utilities->controller, field));
        DPSwiftCall(getter[0], getter[1], (uint64_t)utilities->controller, DPDependencyContext, i ? utilities->queries : utilities->tabs);
    }
    return YES;
}

static BOOL DPLoadTabUtilities(DPTabUtilities *utilities) { return DPLoadTabUtilitiesIn(utilities, nil); }

static void DPReleaseTabUtilities(DPTabUtilities *utilities) {
    void (*release)(void *) = dlsym(RTLD_DEFAULT, "swift_release");
    for (int i = 0; i < 0x320 / 16; i++) release(((void **)utilities->tabs)[i * 2 + 1]);
    for (int i = 0; i < 0x340 / 16; i++) release(((void **)utilities->queries)[i * 2 + 1]);
    release(utilities->controller);
}

@interface DPDiaFolder : NSObject
@property (nonatomic) DPString groupID;
@property (nonatomic, copy) NSString *title;
@end
@implementation DPDiaFolder
@end

// The pinned folders at the top level of the controller's space, in sidebar order.
static NSArray<DPDiaFolder *> *DPPinnedFolders(DPTabUtilities *utilities, void **itemsStorage) {
    void **root = (void **)(utilities->queries + 35 * 16), **group = (void **)(utilities->queries + 20 * 16);
    uint8_t parent[0x30] = {0};  // TabItemParent .container(.pinned(spaceID)): the space's ID, tag 2
    *(DPString *)parent = *(const DPString *)((const uint8_t *)utilities->controller + DPClassFieldOffset(utilities->controller, utilities->spaceField));
    parent[0x20] = 2;
    DPPair items = DPSwiftCall(root[0], root[1], (uint64_t)parent, 0, NULL);  // OrderedSet: hash table, elements
    ((void (*)(void *))dlsym(RTLD_DEFAULT, "swift_release"))((void *)items.x0);
    *itemsStorage = (void *)items.x1;
    const void *(*typeByName)(const char *, size_t, const void *, const void *) = dlsym(RTLD_DEFAULT, "swift_getTypeByMangledNameInEnvironment");
    const uint8_t *groupType = typeByName ? typeByName("9TabModels0A5GroupV", 19, NULL, NULL) : NULL;
    if (!groupType || !items.x1) return nil;
    void *const *witnesses = ((void *const *const *)groupType)[-1];
    size_t size = ((const size_t *)witnesses)[8];
    unsigned (*emptyTag)(const void *, unsigned, const void *) = witnesses[6];
    void (*destroy)(void *, const void *) = witnesses[1];
    const uint8_t *descriptor = ((const uint8_t *const *)groupType)[1];
    uint32_t titleOffset = ((const uint32_t *)(groupType + 8 * *(const uint32_t *)(descriptor + 24)))[1];

    NSMutableArray<DPDiaFolder *> *folders = [NSMutableArray new];
    int64_t count = *(const int64_t *)((const uint8_t *)items.x1 + 0x10);
    const DPItemID *ids = (const void *)((const uint8_t *)items.x1 + 0x20);
    uint8_t *value = calloc(1, size + 16);
    for (int64_t i = 0; i < count; i++) {
        if (ids[i].tag != 1) continue;
        memset(value, 0, size);
        DPSwiftCall(group[0], group[1], ids[i].id.bits, ids[i].id.object, value);
        if (emptyTag(value, 1, groupType) != 0) continue;
        DPDiaFolder *folder = [DPDiaFolder new];
        folder.groupID = ids[i].id;
        DPString title = *(const DPString *)(value + titleOffset);
        folder.title = title.object ? DPStringFromSwift(title) : nil;
        destroy(value, groupType);
        [folders addObject:folder];
    }
    free(value);
    return folders;
}

// Moves a folder to the end of another, as dropping it there would.
static BOOL DPMoveFolder(DPTabUtilities *utilities, const void *itemsStorage, DPString folder, DPString into) {
    void *(*allocate)(const void *, size_t, size_t) = dlsym(RTLD_DEFAULT, "swift_allocObject");
    void (*release)(void *) = dlsym(RTLD_DEFAULT, "swift_release");
    void (*retainString)(uint64_t) = dlsym(RTLD_DEFAULT, "swift_bridgeObjectRetain");
    // A one-element ContiguousArray<TabItem.ID>, of the same type as the pinned items Dia returned.
    uint8_t *elements = allocate(*(void *const *)itemsStorage, 0x20 + sizeof(DPItemID) + 7, 7);
    *(int64_t *)(elements + 0x10) = 1;
    *(uint64_t *)(elements + 0x18) = 1 << 1;
    retainString(folder.object);
    *(DPItemID *)(elements + 0x20) = (DPItemID){folder, 1};

    // TabMoveRequest: itemIDs (no hash table under 16 items), location .group(into) at fromEnd(0), indexing, source.
    uint8_t request[0x48] = {0};
    *(void **)(request + 0x08) = elements;
    *(DPString *)(request + 0x10) = into;
    request[0x30] = 0x80;
    request[0x40] = 1;
    void **move = (void **)(utilities->tabs + 20 * 16);
    BOOL moved = DPSwiftCall(move[0], move[1], (uint64_t)request, 0, NULL).x0 & 1;
    release(elements);
    return moved;
}

// updateTabGroup(id) { $0.titleData = Title(text: title, source: .userGenerated) }, its non-escaping closure
// being a stub with the new title as its context.
__attribute__((used, visibility("hidden"))) void DPRenameBody(uint8_t *proxy, const DPString *title) {
    if (proxy[0x10] <= 2 && *(const uint64_t *)(proxy + 8))  // a title already set: release its text
        ((void (*)(uint64_t))dlsym(RTLD_DEFAULT, "swift_bridgeObjectRelease"))(*(const uint64_t *)(proxy + 8));
    *(DPString *)proxy = *title;
    proxy[0x10] = 2;
}

__attribute__((naked)) static void DPRenameStub(void) {
    __asm__ volatile("mov x1, x20\n b _DPRenameBody\n");
}

static void DPRenameFolder(DPTabUtilities *utilities, DPString folder, NSString *title) {
    DPPair (*fromCString)(const char *) = dlsym(RTLD_DEFAULT, "$sSS7cStringSSSPys4Int8VG_tcfC");
    if (!fromCString || !title.length) return;
    DPPair made = fromCString(title.UTF8String);
    DPString string = {made.x0, made.x1};
    void **update = (void **)(utilities->tabs + 25 * 16);
    DPSwiftCall4(update[0], update[1], folder.bits, folder.object, (uint64_t)DPRenameStub, (uint64_t)&string, NULL);
}

@interface DPArcFolder : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, weak) DPArcFolder *parent;
@property (nonatomic, strong) DPDiaFolder *match;
@end
@implementation DPArcFolder
@end

static NSString *DPArcSidebarPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"Arc/StorableSidebar.json"];
}

// Each Arc space's pinned folders in sidebar order.
static NSArray<NSArray<DPArcFolder *> *> *DPArcSpaces(void) {
    NSData *data = [NSData dataWithContentsOfFile:DPArcSidebarPath()];
    NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *containers = [root isKindOfClass:NSDictionary.class] ? root[@"sidebar"][@"containers"] : nil;
    NSDictionary *container = nil;
    for (id c in [containers isKindOfClass:NSArray.class] ? containers : @[])
        if ([c isKindOfClass:NSDictionary.class] && c[@"spaces"]) container = c;
    NSArray *spaces = container[@"spaces"], *list = container[@"items"];
    if (![spaces isKindOfClass:NSArray.class] || ![list isKindOfClass:NSArray.class]) return nil;
    NSMutableDictionary<NSString *, NSDictionary *> *items = [NSMutableDictionary new];
    for (NSUInteger i = 0; i + 1 < list.count; i += 2)
        if ([list[i] isKindOfClass:NSString.class] && [list[i + 1] isKindOfClass:NSDictionary.class]) items[list[i]] = list[i + 1];

    NSMutableArray *result = [NSMutableArray new];
    __block void (^walk)(NSString *, DPArcFolder *, NSMutableArray *);
    __block __weak void (^weakWalk)(NSString *, DPArcFolder *, NSMutableArray *);
    weakWalk = walk = ^(NSString *itemID, DPArcFolder *parent, NSMutableArray *folders) {
        NSDictionary *item = items[itemID];
        DPArcFolder *folder = parent;
        if ([item[@"data"] isKindOfClass:NSDictionary.class] && item[@"data"][@"list"]) {
            folder = [DPArcFolder new];
            folder.title = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : nil;
            folder.parent = parent;
            [folders addObject:folder];
        }
        for (id child in [item[@"childrenIds"] isKindOfClass:NSArray.class] ? item[@"childrenIds"] : @[])
            if ([child isKindOfClass:NSString.class]) weakWalk(child, folder, folders);
    };
    for (NSDictionary *space in spaces) {
        if (![space isKindOfClass:NSDictionary.class]) continue;
        NSArray *ids = space[@"containerIDs"];
        NSMutableArray *folders = [NSMutableArray new];
        for (NSUInteger i = 0; [ids isKindOfClass:NSArray.class] && i + 1 < ids.count; i++)
            if ([ids[i] isEqual:@"pinned"] && [ids[i + 1] isKindOfClass:NSString.class]) walk(ids[i + 1], nil, folders);
        if (folders.count) [result addObject:folders];
    }
    return result;
}

// Dia titles a folder whose name repeats with its Arc path, "Work › Work old › old".
static BOOL DPTitleMatches(DPArcFolder *folder, NSString *title) {
    if (!folder.title || !title) return NO;
    if ([title isEqualToString:folder.title]) return YES;
    if (![title hasSuffix:[@" › " stringByAppendingString:folder.title]]) return NO;
    NSString *path = folder.title;
    for (DPArcFolder *parent = folder.parent; parent; parent = parent.parent) {
        path = [NSString stringWithFormat:@"%@ › %@", parent.title ?: @"", path];
        if ([path isEqualToString:title]) return YES;
    }
    return NO;
}

// Matches a space's Arc folders, in order, to a run of Dia's folders with the same titles. Arc folders Dia
// skipped (empty ones) are left unmatched.
static void DPMatchSpace(NSArray<DPArcFolder *> *arc, NSArray<DPDiaFolder *> *dia, NSMutableSet<DPDiaFolder *> *used) {
    NSUInteger bestStart = NSNotFound, bestScore = 0;
    for (NSUInteger start = 0; start < dia.count; start++) {
        NSUInteger j = start, score = 0;
        for (DPArcFolder *folder in arc)
            if (j < dia.count && ![used containsObject:dia[j]] && DPTitleMatches(folder, dia[j].title)) j++, score++;
        if (score > bestScore) bestScore = score, bestStart = start;
    }
    if (bestStart == NSNotFound || bestScore < 2) return;
    NSUInteger j = bestStart;
    for (DPArcFolder *folder in arc)
        if (j < dia.count && ![used containsObject:dia[j]] && DPTitleMatches(folder, dia[j].title)) {
            folder.match = dia[j];
            [used addObject:dia[j++]];
        }
    // Folders reordered or made in Dia since the import: the same title elsewhere in the run, or anywhere if
    // only one folder has it.
    NSUInteger end = MIN(dia.count, j + arc.count);
    for (DPArcFolder *folder in arc) {
        if (folder.match) continue;
        for (NSUInteger k = bestStart; k < end && !folder.match; k++)
            if (![used containsObject:dia[k]] && DPTitleMatches(folder, dia[k].title)) {
                folder.match = dia[k];
                [used addObject:dia[k]];
            }
        if (folder.match) continue;
        NSIndexSet *same = [dia indexesOfObjectsPassingTest:^BOOL(DPDiaFolder *d, NSUInteger _, BOOL *__) {
            return ![used containsObject:d] && DPTitleMatches(folder, d.title);
        }];
        if (same.count == 1) {
            folder.match = dia[same.firstIndex];
            [used addObject:folder.match];
        }
    }
}

// Moves one item to the end of a location (a TabItemParent: 0x20 bytes of payload and its tag), as a drop there would.
static BOOL DPMoveItem(DPTabUtilities *utilities, const void *itemsStorage, DPItemID item, const uint8_t location[0x21]) {
    void *(*allocate)(const void *, size_t, size_t) = dlsym(RTLD_DEFAULT, "swift_allocObject");
    void (*release)(void *) = dlsym(RTLD_DEFAULT, "swift_release");
    void (*retainString)(uint64_t) = dlsym(RTLD_DEFAULT, "swift_bridgeObjectRetain");
    uint8_t *elements = allocate(*(void *const *)itemsStorage, 0x20 + sizeof(DPItemID) + 7, 7);
    *(int64_t *)(elements + 0x10) = 1;
    *(uint64_t *)(elements + 0x18) = 1 << 1;
    retainString(item.id.object);
    *(DPItemID *)(elements + 0x20) = item;
    uint8_t request[0x48] = {0};
    *(void **)(request + 0x08) = elements;
    memcpy(request + 0x10, location, 0x21);
    request[0x40] = 1;
    void **move = (void **)(utilities->tabs + 20 * 16);
    BOOL moved = DPSwiftCall(move[0], move[1], (uint64_t)request, 0, NULL).x0 & 1;
    release(elements);
    return moved;
}

// The site a tab is on: "help.github.com" and "github.com" are both "github.com", keeping one more label for
// two-letter country domains like "bbc.co.uk" (from daypatch's Tabs.m).
static NSString *DPSiteOf(NSString *url) {
    NSString *h = [NSURL URLWithString:url].host.lowercaseString ?: @"";
    if ([h hasSuffix:@"."]) h = [h substringToIndex:h.length - 1];
    NSArray *labels = [h componentsSeparatedByString:@"."];
    if (labels.count < 3 || [h rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location == NSNotFound) return h;
    NSUInteger keep = 2;
    NSString *tld = labels.lastObject, *second = labels[labels.count - 2];
    if (tld.length == 2 && [@[@"co", @"com", @"org", @"net", @"ac", @"gov", @"edu"] containsObject:second]) keep = 3;
    return [[labels subarrayWithRange:NSMakeRange(labels.count - keep, keep)] componentsJoinedByString:@"."];
}

// The window's tabs outside folders and bookmarks, in sidebar order, with their addresses from Dia's scripting
// (whose tab IDs are Dia's item IDs). `body` gets them, the window's tab location and the items' storage.
static void DPWithLooseTabs(NSWindow *window, void (^body)(DPTabUtilities *, const void *storage, const uint8_t *location,
                                                          NSArray<NSValue *> *ids, NSArray<NSString *> *urls)) {
    DPTabUtilities utilities = {0};
    if (!DPLoadTabUtilitiesIn(&utilities, window)) return;
    NSMutableDictionary<NSString *, NSString *> *urlByID = [NSMutableDictionary dictionary];
    @try {
        for (id sw in [NSApp valueForKey:@"appleScriptWindows"]) {
            if (![[sw valueForKey:@"windowId"] isEqual:window.identifier]) continue;
            for (id t in [sw valueForKey:@"appleScriptTabs"]) {
                NSString *tid = [t valueForKey:@"tabId"], *url = [t valueForKey:@"URL"];
                if ([tid isKindOfClass:NSString.class]) urlByID[tid] = [url isKindOfClass:NSString.class] ? url : @"";
            }
        }
    } @catch (__unused NSException *e) {}
    DPPair (*fromCString)(const char *) = dlsym(RTLD_DEFAULT, "$sSS7cStringSSSPys4Int8VG_tcfC");
    void (*release)(void *) = dlsym(RTLD_DEFAULT, "swift_release");
    if (!fromCString || !window.identifier) { DPReleaseTabUtilities(&utilities); return; }
    // TabItemParent for a window's tabs: (spaceID, windowID), tag 0.
    uint8_t location[0x30] = {0};
    *(DPString *)location = *(const DPString *)((const uint8_t *)utilities.controller + DPClassFieldOffset(utilities.controller, utilities.spaceField));
    DPPair wid = fromCString(window.identifier.UTF8String);
    *(DPString *)(location + 0x10) = (DPString){wid.x0, wid.x1};
    void **root = (void **)(utilities.queries + 35 * 16);
    DPPair items = DPSwiftCall(root[0], root[1], (uint64_t)location, 0, NULL);
    release((void *)items.x0);
    NSMutableArray<NSValue *> *ids = [NSMutableArray array];
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    int64_t count = items.x1 ? *(const int64_t *)((const uint8_t *)items.x1 + 0x10) : 0;
    const DPItemID *list = items.x1 ? (const void *)((const uint8_t *)items.x1 + 0x20) : NULL;
    for (int64_t i = 0; i < count; i++) {
        NSString *url = list[i].tag == 0 ? urlByID[DPStringFromSwift(list[i].id)] : nil;
        if (!url) continue;
        [ids addObject:[NSValue valueWithBytes:&list[i] objCType:@encode(DPItemID)]];
        [urls addObject:url];
    }
    if (items.x1) body(&utilities, (const void *)items.x1, location, ids, urls);
    if (items.x1) release((void *)items.x1);
    DPReleaseTabUtilities(&utilities);
}

static DPString DPSwiftStringFrom(NSString *string);
static void DPReleaseSwiftString(DPString string);
static void DPExpandFolder(NSWindow *window, NSString *folderID);

static void DPWithWindowRoot(NSWindow *window, void (^body)(DPTabUtilities *utilities, const void *storage, const DPItemID *list, int64_t count)) {
    DPTabUtilities utilities = {0};
    if (!window.identifier || !DPLoadTabUtilitiesIn(&utilities, window)) return;
    uint8_t location[0x30] = {0};
    *(DPString *)location = *(const DPString *)((const uint8_t *)utilities.controller + DPClassFieldOffset(utilities.controller, utilities.spaceField));
    DPString windowID = DPSwiftStringFrom(window.identifier);
    *(DPString *)(location + 0x10) = windowID;
    void (*release)(void *) = dlsym(RTLD_DEFAULT, "swift_release");
    void **root = (void **)(utilities.queries + 35 * 16);
    DPPair items = DPSwiftCall(root[0], root[1], (uint64_t)location, 0, NULL);
    release((void *)items.x0);
    if (items.x1) {
        body(&utilities, (const void *)items.x1, (const void *)((const uint8_t *)items.x1 + 0x20), *(const int64_t *)((const uint8_t *)items.x1 + 0x10));
        release((void *)items.x1);
    }
    DPReleaseSwiftString(windowID);
    DPReleaseTabUtilities(&utilities);
}

// `body` gets the window's tab utilities and, for DPMoveItem, the array storage of its items.
static void DPWithWindowItems(NSWindow *window, void (^body)(DPTabUtilities *utilities, const void *storage)) {
    DPWithWindowRoot(window, ^(DPTabUtilities *utilities, const void *storage, const DPItemID *list, int64_t count) { body(utilities, storage); });
}

// The folders among the window's own tabs. With `into`, the first not in `before` moves into that folder, once;
// `result` is then 1 if it moved and 0 if Dia refused.
static NSSet<NSString *> *DPWindowFolders(NSWindow *window, NSSet<NSString *> *before, NSString *into, int *result) {
    NSMutableSet<NSString *> *folders = [NSMutableSet set];
    DPWithWindowRoot(window, ^(DPTabUtilities *utilities, const void *storage, const DPItemID *list, int64_t count) {
        for (int64_t i = 0; i < count; i++) {
            if (list[i].tag != 1) continue;
            NSString *folder = DPStringFromSwift(list[i].id);
            if (folder) [folders addObject:folder];
            if (!into || *result >= 0 || !folder || [before containsObject:folder]) continue;
            uint8_t target[0x30] = {0};
            DPString targetID = DPSwiftStringFrom(into);
            *(DPString *)target = targetID;
            target[0x20] = 0x80;
            *result = DPMoveItem(utilities, storage, list[i], target);
            NSLog(@"[DiaPatches] new folder: moved into the folder %d", *result);
            DPReleaseSwiftString(targetID);
        }
    });
    return folders;
}

static void DPMoveNewFolderIn(NSWindow *window, NSSet<NSString *> *before, NSString *into, int tries) {
    int result = -1;
    DPWindowFolders(window, before, into, &result);
    if (result == 1) return DPExpandFolder(window, into);
    if (result == 0) return;
    if (tries >= 40) {
        NSLog(@"[DiaPatches] new folder: the new folder wasn't found to move");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ DPMoveNewFolderIn(window, before, into, tries + 1); });
}

static void DPNewSubfolder(NSWindow *window, NSString *folderID) {
    NSSet<NSString *> *before = DPWindowFolders(window, nil, nil, NULL);
    DPNewFolder(window);
    DPMoveNewFolderIn(window, before, folderID, 0);
}

// Sort: every loose tab, ordered by site then address, moved in turn to the end of the window's tabs.
static void DPTidySort(NSWindow *window) {
    DPWithLooseTabs(window, ^(DPTabUtilities *u, const void *storage, const uint8_t *location, NSArray<NSValue *> *ids, NSArray<NSString *> *urls) {
        NSMutableArray<NSNumber *> *order = [NSMutableArray array];
        for (NSUInteger i = 0; i < ids.count; i++) [order addObject:@(i)];
        [order sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            NSString *ua = urls[a.unsignedIntegerValue], *ub = urls[b.unsignedIntegerValue];
            NSComparisonResult r = [DPSiteOf(ua) localizedStandardCompare:DPSiteOf(ub)];
            return r != NSOrderedSame ? r : [ua localizedStandardCompare:ub];
        }];
        for (NSNumber *i in order) {
            DPItemID item;
            [ids[i.unsignedIntegerValue] getValue:&item];
            DPMoveItem(u, storage, item, location);
        }
    });
}

// Group: each site with two or more loose tabs gets a folder named after it, holding them.
static void DPTidyGroup(NSWindow *window) {
    NSMutableArray<NSString *> *sites = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *urlsBySite = [NSMutableDictionary dictionary];
    DPWithLooseTabs(window, ^(DPTabUtilities *u, const void *storage, const uint8_t *location, NSArray<NSValue *> *ids, NSArray<NSString *> *urls) {
        for (NSString *url in urls) {
            NSString *site = DPSiteOf(url);
            if (!site.length) continue;
            if (!urlsBySite[site]) { urlsBySite[site] = [NSMutableArray array]; [sites addObject:site]; }
            [urlsBySite[site] addObject:url];
        }
    });
    __block void (^next)(NSUInteger);
    void (^step)(NSUInteger) = ^(NSUInteger i) {
        while (i < sites.count && urlsBySite[sites[i]].count < 2) i++;
        if (i >= sites.count) { next = nil; return; }
        NSString *site = sites[i];
        DPTabsCreateFolder(window, urlsBySite[site], site, ^(NSString *groupId) {
            if (groupId) DPWithLooseTabs(window, ^(DPTabUtilities *u, const void *storage, const uint8_t *location, NSArray<NSValue *> *ids, NSArray<NSString *> *urls) {
                // Tabs of the site the folder didn't take (same address open twice, say) go in too; and its name.
                DPPair (*fromCString)(const char *) = dlsym(RTLD_DEFAULT, "$sSS7cStringSSSPys4Int8VG_tcfC");
                DPPair gid = fromCString(groupId.UTF8String);
                uint8_t into[0x30] = {0};
                *(DPString *)into = (DPString){gid.x0, gid.x1};
                into[0x20] = 0x80;
                for (NSUInteger k = 0; k < ids.count; k++) {
                    if (![DPSiteOf(urls[k]) isEqualToString:site]) continue;
                    DPItemID item;
                    [ids[k] getValue:&item];
                    DPMoveItem(u, storage, item, into);
                }
                DPRenameFolder(u, (DPString){gid.x0, gid.x1}, site);
            });
            next(i + 1);
        });
    };
    next = step;
    next(0);
}

static void DPRestoreArcFolders(void) {
    DPTabUtilities *utilities = calloc(1, sizeof *utilities);
    void *itemsStorage = NULL;
    NSArray<DPDiaFolder *> *dia = DPLoadTabUtilities(utilities) ? DPPinnedFolders(utilities, &itemsStorage) : nil;
    NSArray<NSArray<DPArcFolder *> *> *arc = DPArcSpaces();
    NSMutableArray<DPArcFolder *> *moves = [NSMutableArray new];
    NSMutableSet *used = [NSMutableSet new];
    for (NSArray<DPArcFolder *> *space in arc) {
        DPMatchSpace(space, dia, used);
        for (DPArcFolder *folder in space) {
            DPArcFolder *parent = folder.parent;
            while (parent && !parent.match) parent = parent.parent;
            if (folder.match && parent) [moves addObject:folder];
        }
    }

    NSAlert *alert = [NSAlert new];
    if (!dia || !arc) {
        alert.messageText = @"Couldn’t read the folders";
        alert.informativeText = arc ? @"Open a Dia window with its sidebar showing, then try again." : @"Arc’s sidebar file wasn’t found.";
    } else if (!moves.count) {
        alert.messageText = @"Nothing to restore";
        alert.informativeText = @"No folder imported from Arc in the space showing in the sidebar sits outside the folder it belongs in. Switch to another space and try again.";
    } else {
        alert.messageText = [NSString stringWithFormat:@"Move %lu folders back into their Arc folders?", (unsigned long)moves.count];
        alert.informativeText = @"In the space showing in the sidebar, folders imported from Arc go back inside the folders they were in, matched by name and order. Other folders aren’t touched.";
        [alert addButtonWithTitle:@"Move Folders"];
        [alert addButtonWithTitle:@"Cancel"];
    }
    if ([alert runModal] == NSAlertFirstButtonReturn && moves.count) {
        NSUInteger moved = 0;
        for (DPArcFolder *folder in moves) {
            DPArcFolder *parent = folder.parent;
            while (!parent.match) parent = parent.parent;
            if (!DPMoveFolder(utilities, itemsStorage, folder.match.groupID, parent.match.groupID)) continue;
            moved++;
            // Dia titled repeated names with their path; inside their parent again they take Arc's name back.
            if (![folder.match.title isEqualToString:folder.title]) DPRenameFolder(utilities, folder.match.groupID, folder.title);
        }
        NSAlert *done = [NSAlert new];
        done.messageText = [NSString stringWithFormat:@"Moved %lu of %lu folders", (unsigned long)moved, (unsigned long)moves.count];
        [done runModal];
    }
    if (itemsStorage) ((void (*)(void *))dlsym(RTLD_DEFAULT, "swift_release"))(itemsStorage);
    if (utilities->controller) DPReleaseTabUtilities(utilities);
    free(utilities);
}

#pragma mark - Folder icons

// Folders show Dia's own icon or one picked for them (Arc imports pick one), each in its own image view. Both
// views get a subclass that swaps whatever Dia sets for the chosen symbol; "" keeps Dia's.
static NSString *const DPFolderIconKey = @"folderIcon";
static NSString *const DPFolderIconDefault = @"folder.fill";
static NSHashTable<NSView *> *DPFolderCells;
static char DPOriginalImageKey;

static NSString *DPFolderSymbol(void) {
    NSString *symbol = [DPDefaults stringForKey:DPFolderIconKey];
    return symbol ?: DPFolderIconDefault;
}

static NSImage *DPFolderImage(void) {
    static NSImage *image;
    static NSString *imageSymbol;
    NSString *symbol = DPFolderSymbol();
    if (!symbol.length) return nil;
    if (![symbol isEqualToString:imageSymbol]) {
        NSImageSymbolConfiguration *config = [[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightMedium]
            configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.secondaryLabelColor]];
        image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] imageWithSymbolConfiguration:config];
        imageSymbol = symbol;
    }
    return image;
}

@interface DPFolderIconView : NSImageView
@end

@implementation DPFolderIconView
- (void)setImage:(NSImage *)image {
    objc_setAssociatedObject(self, &DPOriginalImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    super.image = image && DPFolderImage() ? DPFolderImage() : image;
}
@end

static void DPApplyFolderIcon(NSView *cell) {
    [DPFolderCells addObject:cell];
    for (NSString *name in @[@"$__lazy_storage_$_customIconView", @"$__lazy_storage_$_fallbackIconView"]) {
        Ivar ivar = class_getInstanceVariable(object_getClass(cell), name.UTF8String);
        NSImageView *view = ivar ? object_getIvar(cell, ivar) : nil;
        if (object_getClass(view) == NSImageView.class) {
            objc_setAssociatedObject(view, &DPOriginalImageKey, view.image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            object_setClass(view, DPFolderIconView.class);
        }
        if (object_getClass(view) != DPFolderIconView.class) continue;
        NSImage *original = objc_getAssociatedObject(view, &DPOriginalImageKey);
        if (view.image != (original && DPFolderImage() ? DPFolderImage() : original)) view.image = original;
    }
}

static void DPCollapseNestedStripFolder(NSView *view);

static void DPFolderCell_layout(NSView *self, SEL _cmd) {
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
    DPApplyFolderIcon(self);
    DPCollapseNestedStripFolder(self);
}

static void DPSetFolderSymbol(NSString *symbol) {
    [DPDefaults setObject:symbol forKey:DPFolderIconKey];
    for (NSView *cell in DPFolderCells.allObjects) DPApplyFolderIcon(cell);
}

#pragma mark - Tab glow

// The selected tab's shape view carries a layer with a wide shadow, masked to show only outside the tab, and a
// gradient masked to the tab's edge for its outline; a rim highlight view adds another edge in some states.
static NSHashTable *DPGlowLayers, *DPRimViews;
static char DPRequestedShadowKey, DPRequestedOpacityKey;

@interface DPGlowLayer : CAShapeLayer
@end

@implementation DPGlowLayer
- (void)setShadowOpacity:(float)opacity {
    objc_setAssociatedObject(self, &DPRequestedShadowKey, @(opacity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    super.shadowOpacity = DPOn[DPHideTabGlow] ? 0 : opacity;
}
@end

@interface DPOutlineLayer : CAGradientLayer
@end

@implementation DPOutlineLayer
- (void)setOpacity:(float)opacity {
    objc_setAssociatedObject(self, &DPRequestedOpacityKey, @(opacity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    super.opacity = DPOn[DPHideTabGlow] ? 0 : opacity;
}
@end

static void DPTabShape_layout(NSView *self, SEL _cmd) {
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
    for (CALayer *layer in self.layer.sublayers) {
        if (object_getClass(layer) != CAShapeLayer.class || layer.shadowRadius < 10) continue;
        float opacity = layer.shadowOpacity;
        object_setClass(layer, DPGlowLayer.class);
        [DPGlowLayers addObject:layer];
        layer.shadowOpacity = opacity;
    }
    for (NSView *sub in self.subviews) {
        if ([NSStringFromClass(sub.class) hasSuffix:@"RimHighlightView"]) {
            [DPRimViews addObject:sub];
            sub.alphaValue = DPOn[DPHideTabGlow] ? 0 : 1;
        }
        for (CALayer *layer in sub.layer.sublayers) {
            if (object_getClass(layer) != CAGradientLayer.class || ![layer.mask isKindOfClass:CAShapeLayer.class]
                || !NSEqualSizes(layer.bounds.size, self.bounds.size))
                continue;
            float opacity = layer.opacity;
            object_setClass(layer, DPOutlineLayer.class);
            [DPGlowLayers addObject:layer];
            layer.opacity = opacity;
        }
    }
}

static void DPRefreshTabGlow(void) {
    for (CALayer *layer in DPGlowLayers.allObjects) {
        if ([layer isKindOfClass:DPOutlineLayer.class]) layer.opacity = [objc_getAssociatedObject(layer, &DPRequestedOpacityKey) floatValue];
        else layer.shadowOpacity = [objc_getAssociatedObject(layer, &DPRequestedShadowKey) floatValue];
    }
    for (NSView *view in DPRimViews.allObjects) view.alphaValue = DPOn[DPHideTabGlow] ? 0 : 1;
}

#pragma mark - Sidebar spacing

// TabListCollectionViewLayout lays every sidebar row out at its tabHeight (34 by default); setting it before
// each layout pass spaces bookmarks, open tabs and folders closer together or further apart.
static NSString *const DPRowHeightKey = @"sidebarRowHeight";
static NSHashTable *DPTabListLayouts;
static char DPDefaultRowHeightKey;

static void DPTabListLayout_prepare(NSCollectionViewLayout *self, SEL _cmd) {
    [DPTabListLayouts addObject:self];
    Ivar ivar = class_getInstanceVariable(object_getClass(self), "tabHeight");
    double *height = ivar ? (double *)((uint8_t *)(__bridge void *)self + ivar_getOffset(ivar)) : NULL;
    if (height) {
        NSNumber *original = objc_getAssociatedObject(self, &DPDefaultRowHeightKey);
        if (!original) objc_setAssociatedObject(self, &DPDefaultRowHeightKey, original = @(*height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        double chosen = [DPDefaults doubleForKey:DPRowHeightKey];
        *height = chosen > 0 ? chosen : original.doubleValue;
    }
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
}

// Folders add their own 3pt on top of the row height: the layout's folder row extra, and the bottom of each
// expanded folder (two sites). Each is an fmov of 3.0, rewritten in place; the layout runs on the main thread.
static NSString *const DPFolderSpacingKey = @"folderSpacing";
static uint32_t *DPFolderSpacingSites[3];
static const uint32_t DPFolderSpacingOffsets[3] = {0xfe8, 0x141c, 0x1444};  // in the layout function
static const uint32_t DPFolderSpacingRegisters[3] = {1, 0, 0};

static uint32_t DPFolderSpacingWord(int site, NSInteger level) {
    uint32_t rd = DPFolderSpacingRegisters[site];
    return level == 2 ? 0x2f00e400 | rd                    // movi d, #0
         : level == 1 ? 0x1e601000 | (0x78 << 13) | rd     // fmov d, #1.5
                      : 0x1e601000 | (0x08 << 13) | rd;    // fmov d, #3.0
}

static void DPFindFolderSpacing(uint8_t *layout) {
    for (int i = 0; i < 3; i++)
        if (*(const uint32_t *)(layout + DPFolderSpacingOffsets[i]) != DPFolderSpacingWord(i, 0)) return;
    for (int i = 0; i < 3; i++) DPFolderSpacingSites[i] = (uint32_t *)(layout + DPFolderSpacingOffsets[i]);
}

static void DPApplyFolderSpacing(void) {
    if (!DPFolderSpacingSites[0]) return;
    NSInteger level = [DPDefaults integerForKey:DPFolderSpacingKey];
    for (int i = 0; i < 3; i++) {
        uint32_t *site = DPFolderSpacingSites[i], word = DPFolderSpacingWord(i, level);
        if (*site == word) continue;
        vm_address_t page = (vm_address_t)site & ~(vm_address_t)(vm_page_size - 1);
        if (vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return;
        *site = word;
        vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
        sys_icache_invalidate(site, 4);
    }
}

static void DPSetFolderSpacing(NSInteger level) {
    [DPDefaults setInteger:level forKey:DPFolderSpacingKey];
    DPApplyFolderSpacing();
    for (NSCollectionViewLayout *layout in DPTabListLayouts.allObjects) [layout invalidateLayout];
}

static void DPSetRowHeight(double height) {
    [DPDefaults setDouble:height forKey:DPRowHeightKey];
    for (NSCollectionViewLayout *layout in DPTabListLayouts.allObjects) [layout invalidateLayout];
}

#pragma mark - Animation

static void DPRelayout(void) {
    for (NSView *container in DPContainers) {
        NSValue *requested = objc_getAssociatedObject(container, &DPRequestedFrameKey);
        if (requested) container.frame = requested.rectValue;
        container.needsLayout = container.needsDisplay = YES;
        DPRestyleContainer(container);
    }
    for (NSView *pane in DPPanes) {
        pane.needsLayout = YES;
        [pane layoutSubtreeIfNeeded];
    }
}

static void DPAnimate(void) {
    static NSTimer *timer;
    static CFTimeInterval start;
    static CGFloat from[DPAnimatedCount];
    start = CACurrentMediaTime();
    for (int i = 0; i < DPAnimatedCount; i++) from[i] = DPProgress[i];
    if (timer) return;
    timer = [NSTimer timerWithTimeInterval:1.0 / 120 repeats:YES block:^(NSTimer *t) {
        CGFloat elapsed = CACurrentMediaTime() - start, omega = 22;
        BOOL done = elapsed >= DPAnimationDuration * 2;
        CGFloat eased = done ? 1 : 1 - (1 + omega * elapsed) * exp(-omega * elapsed);
        for (int i = 0; i < DPAnimatedCount; i++) DPProgress[i] = from[i] + (DPOn[i] - from[i]) * eased;
        DPRelayout();
        if (done) {
            [t invalidate];
            timer = nil;
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

#pragma mark - Keep windows active

@interface NSWindow (DPPrivate)
- (BOOL)_hasActiveAppearance;
- (void)_setShadowParameters;
@end

@interface NSView (DPPrivate)
- (void)_windowChangedKeyState;
@end

// Browser windows only: our panels and Dia's popovers keep AppKit's own behaviour.
static BOOL DPKeptActive(NSWindow *window) {
    return DPOn[DPKeepWindowsActive] && (window.styleMask & NSWindowStyleMaskTitled) && ![window isKindOfClass:NSPanel.class];
}

static BOOL DPWindow_hasActiveAppearance(NSWindow *self, SEL _cmd) {
    return DPKeptActive(self) || DPCallOriginal(BOOL (*)(id, SEL), self, _cmd);
}

// Dia's window buttons follow this. Claiming it also shows focus rings in windows without keyboard focus.
static BOOL DPWindow_hasKeyAppearance(NSWindow *self, SEL _cmd) {
    return DPKeptActive(self) || DPCallOriginal(BOOL (*)(id, SEL), self, _cmd);
}

static void DPRefreshKeyState(NSView *view) {
    if ([view respondsToSelector:@selector(_windowChangedKeyState)]) [view _windowChangedKeyState];
    view.needsDisplay = YES;
    for (NSView *subview in view.subviews) DPRefreshKeyState(subview);
}

static void DPApplyKeepWindowsActive(void) {
    for (NSWindow *window in NSApp.windows) {
        if (!(window.styleMask & NSWindowStyleMaskTitled) || [window isKindOfClass:NSPanel.class]) continue;
        if ([window respondsToSelector:@selector(_setShadowParameters)]) [window _setShadowParameters];
        DPRefreshKeyState(window.contentView.superview);
    }
}

// With the toolbar hidden, the ⋯ extensions button moves into the sidebar URL bar.
static void DPConfigureArcBar(void) {
    DPArcBarConfigure(DPOn[DPSidebarURLBar], DPOn[DPCommandBar], DPOn[DPExtensionsButton] && DPOn[DPHideToolbar], DPOn[DPDownloadsAtBottom]);
}

static void DPApplyTabMemory(void);

static void DPSetTweak(DPTweak tweak, BOOL on) {
    if (DPOn[tweak] == on) return;
    DPOn[tweak] = on;
    [DPDefaults setBool:on forKey:DPKeys[tweak]];
    if (tweak == DPSidebarURLBar || tweak == DPCommandBar || tweak == DPHideToolbar || tweak == DPExtensionsButton || tweak == DPDownloadsAtBottom) DPConfigureArcBar();
    if (tweak < DPAnimatedCount) DPAnimate();
    else if (tweak == DPHideTabGlow) DPRefreshTabGlow();
    else if (tweak == DPKeepWindowsActive) DPApplyKeepWindowsActive();
    else if (tweak == DPTidyTabs) DPRefreshSeparators();
    else if (tweak == DPPhoneAccess) DPApplyPhoneAccess();
    else if (tweak == DPTabMemory) DPApplyTabMemory();
    else if (tweak == DPPeekOnShiftClick) DPPeekSetOn(on);
    else if (tweak != DPNestedFolders && tweak != DPSidebarURLBar && tweak != DPCommandBar && tweak != DPFolderDropdowns && tweak != DPArcBookmarks && tweak != DPDownloadsAtBottom && tweak != DPLittleWindow && tweak != DPTabMemory && tweak != DPMoveToSpace && tweak != DPNewTabBar && tweak != DPPlainNewTab && tweak != DPPeekOnShiftClick) {
        if (on) for (NSView *bar in DPBars.allObjects) DPEnforceButtons(bar);
        else DPRestoreButtons(tweak);
        DPRelayoutBars();
    }
}

#pragma mark - Updates

static NSString *DPStagedPath(void) {
    return [DPCLI().stringByDeletingLastPathComponent.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"staged/Dia.app"];
}

static void DPCheckForUpdates(void (^completion)(NSDictionary *status)) {
    DPRunCLI(@[@"update"], ^(NSString *_) {
        DPRunCLI(@[@"status", @"--json"], ^(NSString *output) {
            id status = output ? [NSJSONSerialization JSONObjectWithData:[output dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
            completion([status isKindOfClass:NSDictionary.class] ? status : nil);
        });
    });
}

@interface DPUpdateMenuTarget : NSObject
@end

@implementation DPUpdateMenuTarget
- (void)checkForUpdates:(id)sender {
    DPCheckForUpdates(^(NSDictionary *status) {
        NSAlert *alert = [NSAlert new];
        id staged = status[@"staged"];
        if ([staged isKindOfClass:NSString.class]) {
            alert.messageText = [NSString stringWithFormat:@"Dia %@ is ready", staged];
            alert.informativeText = @"It will be installed with your patches when you quit Dia.";
            [alert addButtonWithTitle:@"Relaunch Now"];
            [alert addButtonWithTitle:@"Later"];
            if ([alert runModal] == NSAlertFirstButtonReturn) DPHandOffAndQuit(@"apply");
        } else {
            alert.messageText = status ? @"Dia is up to date" : @"Couldn’t check for updates";
            [alert runModal];
        }
    });
}
@end

static void DPInstallUpdateMenuItem(void) {
    static DPUpdateMenuTarget *target;
    target = target ?: [DPUpdateMenuTarget new];
    for (NSMenuItem *item in NSApp.mainMenu.itemArray.firstObject.submenu.itemArray) {
        if (![item.title hasPrefix:@"Check for Updates"]) continue;
        item.target = target;
        item.action = @selector(checkForUpdates:);
    }
}

static void DPApplyStagedOnQuit(void) {
    if (![NSFileManager.defaultManager fileExistsAtPath:DPStagedPath()]) return;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:DPCLI()];
    task.arguments = @[@"apply", @"--wait", @(getpid()).stringValue];
    [task launchAndReturnError:nil];
}

#pragma mark - Folders in top tabs

// In top tabs Dia lays a folder's contents out inline in the tab strip, folders inside it too. A folder inside
// another one stays a chip there instead: clicking it drops down its contents, where folders expand in place.
@interface DPStripNode : NSObject
@property (nonatomic, copy) NSString *itemID, *title, *url;
@property (nonatomic) BOOL isFolder;
@property (nonatomic) NSInteger depth;
@end
@implementation DPStripNode
@end

static DPString DPSwiftStringFrom(NSString *string) {
    DPPair (*fromCString)(const char *) = dlsym(RTLD_DEFAULT, "$sSS7cStringSSSPys4Int8VG_tcfC");
    DPPair made = fromCString ? fromCString(string.UTF8String) : (DPPair){0, 0};
    return (DPString){made.x0, made.x1};
}

static void DPReleaseSwiftString(DPString string) {
    ((void (*)(uint64_t))dlsym(RTLD_DEFAULT, "swift_bridgeObjectRelease"))(string.object);
}

// A folder's title and its children (tabs and folders) in order, read through TabQueryUtilities.group(id).
static BOOL DPReadFolder(DPTabUtilities *utilities, NSString *folderID, NSString **title, NSMutableArray<DPStripNode *> *children) {
    const void *(*typeByName)(const char *, size_t, const void *, const void *) = dlsym(RTLD_DEFAULT, "swift_getTypeByMangledNameInEnvironment");
    const uint8_t *groupType = typeByName ? typeByName("9TabModels0A5GroupV", 19, NULL, NULL) : NULL;
    if (!groupType) return NO;
    void *const *witnesses = ((void *const *const *)groupType)[-1];
    size_t size = ((const size_t *)witnesses)[8];
    unsigned (*emptyTag)(const void *, unsigned, const void *) = witnesses[6];
    void (*destroy)(void *, const void *) = witnesses[1];
    const uint8_t *descriptor = ((const uint8_t *const *)groupType)[1];
    const uint32_t *offsets = (const uint32_t *)(groupType + 8 * *(const uint32_t *)(descriptor + 24));
    void **group = (void **)(utilities->queries + 20 * 16);

    DPString key = DPSwiftStringFrom(folderID);
    uint8_t *value = calloc(1, size + 16);
    DPSwiftCall(group[0], group[1], key.bits, key.object, value);
    DPReleaseSwiftString(key);
    BOOL found = emptyTag(value, 1, groupType) == 0;
    if (found) {
        DPString text = *(const DPString *)(value + offsets[1]);
        if (title) *title = text.object ? DPStringFromSwift(text) : nil;
        const uint8_t *elements = *(const uint8_t *const *)(value + offsets[5] + 8);  // OrderedSet: hash table, elements
        int64_t count = elements ? *(const int64_t *)(elements + 0x10) : 0;
        const DPItemID *ids = elements ? (const void *)(elements + 0x20) : NULL;
        for (int64_t i = 0; i < count; i++) {
            DPStripNode *node = [DPStripNode new];
            node.itemID = DPStringFromSwift(ids[i].id);
            node.isFolder = ids[i].tag == 1;
            if (node.itemID) [children addObject:node];
        }
        destroy(value, groupType);
    }
    free(value);
    return found;
}

// Tab titles and URLs by tab ID, from Dia's scripting interface.
static NSDictionary<NSString *, NSArray<NSString *> *> *DPTabInfo(void) {
    NSMutableDictionary *info = [NSMutableDictionary new];
    @try {
        for (id window in [NSApp valueForKey:@"appleScriptWindows"])
            for (id tab in [window valueForKey:@"appleScriptTabs"]) {
                NSString *tabID = [[tab valueForKey:@"tabId"] description];
                id title = [tab valueForKey:@"title"], url = [tab valueForKey:@"URL"];
                if (tabID) info[tabID] = @[[title isKindOfClass:NSString.class] ? title : @"", [url isKindOfClass:NSString.class] ? url : @""];
            }
    } @catch (__unused NSException *e) {}
    return info;
}

#pragma mark - Drops into folders

// Dropped into a collapsed folder, an item used to leave its row for the top left corner: the collection view had
// nowhere to show it. Now the folder opens, WindowTabUtilities.expandTabGroup(id, animated) (field 33), and rows
// that disappear in the drop fade out where the folder is.
static CGRect DPDropFolderRect;  // set for a moment after a drop into a folder

static void DPExpandFolder(NSWindow *window, NSString *folderID) {
    DPTabUtilities utilities = {0};
    if (!DPLoadTabUtilitiesIn(&utilities, window)) return;
    DPString folder = DPSwiftStringFrom(folderID);
    void **expand = (void **)(utilities.tabs + 33 * 16);
    DPSwiftCall4(expand[0], expand[1], folder.bits, folder.object, YES, 0, NULL);
    DPReleaseSwiftString(folder);
    DPReleaseTabUtilities(&utilities);
}

static BOOL DPTabList_performDrag(NSView *self, SEL _cmd, id<NSDraggingInfo> info) {
    NSString *folder = DPDragFolderID;
    CGRect rect = DPDragFolderRect;
    BOOL dropped = DPCallOriginal(BOOL (*)(id, SEL, id), self, _cmd, info);
    if (dropped && folder) {
        DPDropFolderRect = rect;
        DPExpandFolder(self.window, folder);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ DPDropFolderRect = CGRectZero; });
    }
    return dropped;
}

static NSCollectionViewLayoutAttributes *DPTabListLayout_disappearing(NSCollectionViewLayout *self, SEL _cmd, NSIndexPath *path) {
    NSCollectionViewLayoutAttributes *attributes = DPCallOriginal(NSCollectionViewLayoutAttributes *(*)(id, SEL, NSIndexPath *), self, _cmd, path);
    if (CGRectIsEmpty(DPDropFolderRect)) return attributes;
    NSCollectionViewLayoutAttributes *into = [attributes copy] ?: [[self.class layoutAttributesClass] layoutAttributesForItemWithIndexPath:path];
    into.frame = (CGRect){DPDropFolderRect.origin, attributes ? attributes.frame.size : DPDropFolderRect.size};
    into.alpha = 0;
    return into;
}

// A folder can keep its highlight after a drag: as the drop target, or hovered with its exit waiting for a mouse
// up that the drag took. Once the drag is over, folders the pointer isn't on lose both.
static void DPCollectFolderCells(NSView *view, NSMutableArray<NSView *> *cells) {
    if (DPIsKind(view, @"_TtC5TabUI16TabGroupCellView")) [cells addObject:view];
    for (NSView *sub in view.subviews) DPCollectFolderCells(sub, cells);
}

static void DPClearFolderHighlights(NSView *list) {
    NSMutableArray<NSView *> *cells = [NSMutableArray array];
    DPCollectFolderCells(list, cells);
    NSPoint mouse = list.window ? [list.window convertPointFromScreen:NSEvent.mouseLocation] : NSZeroPoint;
    for (NSView *cell in cells) {
        if (NSPointInRect([cell convertPoint:mouse fromView:nil], cell.bounds)) continue;
        for (NSString *name in @[@"isDropTargetHighlighted", @"isGroupAreaHovered"]) {
            Ivar ivar = class_getInstanceVariable(object_getClass(cell), name.UTF8String);
            BOOL *flag = ivar ? (BOOL *)((uint8_t *)(__bridge void *)cell + ivar_getOffset(ivar)) : NULL;
            if (!flag || !*flag) continue;
            NSLog(@"[DiaPatches] cleared %@ on a folder after a drag", name);
            *flag = NO;
            cell.needsDisplay = YES;
            cell.needsLayout = YES;
        }
    }
}

static void DPClearFolderHighlightsSoon(NSView *list) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ DPClearFolderHighlights(list); });
}

static void DPTabList_draggingEnded(NSView *self, SEL _cmd, id<NSDraggingInfo> info) {
    DPCallOriginal(void (*)(id, SEL, id), self, _cmd, info);
    DPClearFolderHighlightsSoon(self);
}

static void DPTabList_sessionEnded(NSView *self, SEL _cmd, NSDraggingSession *session, NSPoint point, NSDragOperation operation) {
    DPCallOriginal(void (*)(id, SEL, id, NSPoint, NSDragOperation), self, _cmd, session, point, operation);
    DPClearFolderHighlightsSoon(self);
}

#pragma mark - Last tab

// ⌘W on a window's last tab closes the window, after Dia's "Warn before closing last tab" confirmation, and with
// the last window the app. Instead Dia's own New Tab (the ⌘T menu item) opens, then the old tab closes.
static NSString *DPActiveTabID(NSWindow *window) {
    @try {
        for (id sw in [NSApp valueForKey:@"appleScriptWindows"]) {
            if (![[sw valueForKey:@"windowId"] isEqual:window.identifier]) continue;
            NSString *tabID = [[sw valueForKey:@"activeTab"] valueForKey:@"tabId"];
            return [tabID isKindOfClass:NSString.class] ? tabID : nil;
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

// The window's own tabs (not bookmarks or favorites) by ID.
static NSArray<NSString *> *DPWindowTabIDs(NSWindow *window) {
    NSMutableArray<NSString *> *tabIDs = [NSMutableArray array];
    DPWithLooseTabs(window, ^(DPTabUtilities *u, const void *storage, const uint8_t *location, NSArray<NSValue *> *ids, NSArray<NSString *> *urls) {
        for (NSValue *value in ids) {
            DPItemID item;
            [value getValue:&item];
            NSString *tabID = DPStringFromSwift(item.id);
            if (tabID) [tabIDs addObject:tabID];
        }
    });
    return tabIDs;
}

// New Tab can take a moment to add the tab; the old one closes once it's there.
static void DPCloseReplacedTab(NSWindow *window, NSString *tabID, int tries) {
    NSArray<NSString *> *tabIDs = DPWindowTabIDs(window);
    if (tabIDs.count < 2 || ![tabIDs containsObject:tabID]) {
        if (tries < 50 && [tabIDs containsObject:tabID])
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ DPCloseReplacedTab(window, tabID, tries + 1); });
        return;
    }
    NSString *source = [NSString stringWithFormat:@"tell application \"%@\" to close (first tab of (first window whose id is \"%@\") whose id is \"%@\")",
                                                  NSBundle.mainBundle.bundlePath, window.identifier, tabID];
    NSDictionary *error = nil;
    [[[NSAppleScript alloc] initWithSource:source] executeAndReturnError:&error];
    if (error) NSLog(@"[DiaPatches] closing the replaced tab failed: %@", error[NSAppleScriptErrorMessage]);
}

static BOOL DPReplaceLastTab(NSWindow *window) {
    window = DPBrowserWindow(window);
    NSString *active = window.identifier ? DPActiveTabID(window) : nil;
    NSArray<NSString *> *tabIDs = active ? DPWindowTabIDs(window) : nil;
    if (tabIDs.count != 1 || ![tabIDs.firstObject isEqualToString:active]) return NO;
    NSMenuItem *newTab = DPItemWithShortcut(NSApp.mainMenu, @"t", NSEventModifierFlagCommand);
    if (!newTab.action || ![NSApp sendAction:newTab.action to:newTab.target from:newTab]) return NO;
    DPCloseReplacedTab(window, active, 0);
    return YES;
}

static BOOL DPMoveLittleWindow(NSWindow *window);
static BOOL DPCloseLittleWindow(NSWindow *window);

// Key codes, so it works with any input source; Chromium routes key equivalents before local event monitors see them.
static void DPApp_sendEvent(NSApplication *self, SEL _cmd, NSEvent *event) {
    NSEventModifierFlags modifiers = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl);
    if (event.type == NSEventTypeKeyDown && !event.isARepeat && event.keyCode == 13 && modifiers == NSEventModifierFlagCommand
        && DPCloseLittleWindow(event.window ?: self.keyWindow))  // ⌘W closes a little window, not just its tab
        return;
    if (event.type == NSEventTypeKeyDown && !event.isARepeat && event.keyCode == 13 && modifiers == NSEventModifierFlagCommand
        && !DPPeekShowingIn(event.window ?: self.keyWindow) && DPReplaceLastTab(event.window ?: self.keyWindow))
        return;
    if (event.type == NSEventTypeKeyDown && !event.isARepeat && event.keyCode == 31 && modifiers == NSEventModifierFlagCommand
        && DPMoveLittleWindow(event.window ?: self.keyWindow))  // ⌘O in a little window
        return;
    DPCallOriginal(void (*)(id, SEL, NSEvent *), self, _cmd, event);
}

#pragma mark - Little window

// Like Little Arc: a link opened from another app opens in a new, small Dia window without the sidebar, and
// Open in Window (⌘O) moves the page to a new tab in the window that was in front, closing the little one.
static NSHashTable<NSWindow *> *DPLittleWindows;
static void DPCollectTabRows(NSView *view, NSMutableArray<NSView *> *rows);
static NSString *DPTabIDOfRow(NSView *row);
static char DPLittleHomeKey;

static NSString *DPScriptString(NSString *string) {
    return [[string stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

// Runs AppleScript against Dia itself; returns the result's text, or nil (logged) on an error.
static NSString *DPRunScript(NSString *body, NSString *what) {
    NSString *source = [NSString stringWithFormat:@"tell application \"%@\"\n%@\nend tell", DPScriptString(NSBundle.mainBundle.bundlePath), body];
    NSDictionary *error = nil;
    NSAppleEventDescriptor *result = [[[NSAppleScript alloc] initWithSource:source] executeAndReturnError:&error];
    if (error) NSLog(@"[DiaPatches] little window: %@ failed: %@", what, error[NSAppleScriptErrorMessage]);
    return error ? nil : result.stringValue ?: @"";
}

// The active tab's scripting object. Going through it directly takes no time; a script of the same takes most of a second.
static id DPScriptActiveTab(NSWindow *window) {
    @try {
        for (id sw in [NSApp valueForKey:@"appleScriptWindows"])
            if ([[sw valueForKey:@"windowId"] isEqual:window.identifier]) return [sw valueForKey:@"activeTab"];
    } @catch (__unused NSException *e) {}
    return nil;
}

static NSString *DPWindowRef(NSWindow *window) {
    return [NSString stringWithFormat:@"(first window whose id is \"%@\")", DPScriptString(window.identifier)];
}

@interface DPLittleBar : NSVisualEffectView
@property (nonatomic, weak) NSWindow *little;
@end

@implementation DPLittleBar
- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.material = NSVisualEffectMaterialHUDWindow;
    self.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.state = NSVisualEffectStateActive;
    self.wantsLayer = YES;
    self.layer.cornerRadius = NSHeight(frame) / 2;
    self.layer.masksToBounds = YES;
    NSButton *button = [NSButton buttonWithTitle:@"Open in Window" image:[NSImage imageWithSystemSymbolName:@"arrow.up.forward.app" accessibilityDescription:nil]
                                          target:self action:@selector(move:)];
    button.bordered = NO;
    button.imagePosition = NSImageLeading;
    button.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    button.toolTip = @"Move this page to a tab in your main window (⌘O)";
    button.frame = NSInsetRect(self.bounds, 10, 0);
    button.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:button];
    return self;
}
- (void)move:(id)sender { DPMoveLittleWindow(self.little); }
@end

static BOOL DPCloseLittleWindow(NSWindow *window) {
    if (![DPLittleWindows containsObject:window]) return NO;
    [window performClose:nil];
    return YES;
}

// Until it's dressed, the new window is invisible and already small, so the big window never shows.
static char DPLittleSizeKey, DPLittleMovedKey;
static NSSet<NSWindow *> *DPLittlePending;  // windows from before New Window, while a little one is on its way

static void DPShrinkLittleWindow(NSWindow *window) {
    window.alphaValue = 0;
    NSScreen *screen = NSScreen.mainScreen;
    for (NSScreen *s in NSScreen.screens) if (NSMouseInRect(NSEvent.mouseLocation, s.frame, NO)) screen = s;
    NSRect visible = screen.visibleFrame;
    NSSize size = NSMakeSize(MIN(960, NSWidth(visible) - 80), MIN(720, NSHeight(visible) - 80));
    NSRect frame = NSMakeRect(NSMidX(visible) - size.width / 2, NSMidY(visible) - size.height / 2, size.width, size.height);
    if (!NSEqualRects(window.frame, frame)) [window setFrame:frame display:NO animate:NO];
    objc_setAssociatedObject(window, &DPLittleSizeKey, [NSValue valueWithSize:size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Shrunk before Dia first puts it on screen.
static void DPPlatformWindow_orderWindow(NSWindow *self, SEL _cmd, NSWindowOrderingMode place, NSInteger other) {
    if (DPLittlePending && place != NSWindowOut && ![DPLittlePending containsObject:self] && !self.isVisible) DPShrinkLittleWindow(self);
    DPCallOriginal(void (*)(id, SEL, NSWindowOrderingMode, NSInteger), self, _cmd, place, other);
}

static void DPPlatformWindow_makeKeyAndOrderFront(NSWindow *self, SEL _cmd, id sender) {
    if (DPLittlePending && ![DPLittlePending containsObject:self] && !self.isVisible) DPShrinkLittleWindow(self);
    DPCallOriginal(void (*)(id, SEL, id), self, _cmd, sender);
}

// Dia sizes a window up again when it moves to another display; a little window keeps its size.
static void DPWatchLittleWindows(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:NSWindowDidChangeScreenNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        if ([DPLittleWindows containsObject:note.object]) objc_setAssociatedObject(note.object, &DPLittleMovedKey, NSDate.date, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }];
    [center addObserverForName:NSWindowDidEndLiveResizeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        NSWindow *window = note.object;
        if ([DPLittleWindows containsObject:window])
            objc_setAssociatedObject(window, &DPLittleSizeKey, [NSValue valueWithSize:window.frame.size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }];
    [center addObserverForName:NSWindowDidResizeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        NSWindow *window = note.object;
        NSDate *moved = objc_getAssociatedObject(window, &DPLittleMovedKey);
        NSValue *size = objc_getAssociatedObject(window, &DPLittleSizeKey);
        if (![DPLittleWindows containsObject:window] || !moved || !size || window.inLiveResize
            || (window.styleMask & NSWindowStyleMaskFullScreen) || -moved.timeIntervalSinceNow > 3)
            return;
        if (NSEqualSizes(window.frame.size, size.sizeValue)) return;
        objc_setAssociatedObject(window, &DPLittleMovedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSRect frame = window.frame;
        NSRect kept = NSMakeRect(NSMinX(frame), NSMaxY(frame) - size.sizeValue.height, size.sizeValue.width, size.sizeValue.height);
        dispatch_async(dispatch_get_main_queue(), ^{ [window setFrame:kept display:YES animate:NO]; });
    }];
}

// Sent through the little window's own responders: the key window may not have changed yet.
static BOOL DPSendToWindow(NSWindow *window, SEL sel) {
    for (NSResponder *r = window.firstResponder; r; r = r.nextResponder)
        if ([r respondsToSelector:sel]) return [NSApp sendAction:sel to:r from:nil];
    for (id target in @[(id)window.delegate ?: NSNull.null, window.windowController ?: NSNull.null])
        if ([target respondsToSelector:sel]) return [NSApp sendAction:sel to:target from:nil];
    return NO;
}

static BOOL DPSidebarShowing(NSView *view) {
    if (DPIsKind(view, @"TabList.TabListView")) return !view.hiddenOrHasHiddenAncestor && !NSIsEmptyRect(view.visibleRect);
    for (NSView *sub in view.subviews) if (DPSidebarShowing(sub)) return YES;
    return NO;
}

// Shown once the sidebar has closed, or after 0.35s whatever it's doing.
static void DPShowWhenSidebarClosed(NSWindow *window, int tries) {
    if (!window) return;
    BOOL showing = DPSidebarShowing(window.contentView.superview);
    if (showing && tries < 22) {
        __weak NSWindow *weakWindow = window;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.016 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ DPShowWhenSidebarClosed(weakWindow, tries + 1); });
        return;
    }
    window.alphaValue = 1;
}

static void DPDressLittleWindow(NSWindow *window) {
    DPShrinkLittleWindow(window);
    [window makeKeyAndOrderFront:nil];
    if (!DPSendToWindow(window, NSSelectorFromString(@"toggleSidebar:"))) NSLog(@"[DiaPatches] little window: no sidebar toggle");
    DPShowWhenSidebarClosed(window, 0);
    NSView *frameView = window.contentView.superview;
    DPLittleBar *bar = [[DPLittleBar alloc] initWithFrame:NSMakeRect(0, 0, 150, 26)];
    bar.little = window;
    bar.frame = NSMakeRect(NSWidth(frameView.bounds) - 150 - 12, frameView.isFlipped ? 10 : NSHeight(frameView.bounds) - 26 - 10, 150, 26);
    bar.autoresizingMask = NSViewMinXMargin | (frameView.isFlipped ? NSViewMaxYMargin : NSViewMinYMargin);
    [frameView addSubview:bar positioned:NSWindowAbove relativeTo:nil];
}

// The new window and then its tab take a moment to appear.
static void DPAdoptLittleWindow(NSSet<NSWindow *> *before, NSString *url, NSWindow *home, int tries) {
    NSWindow *window = nil;
    for (NSWindow *w in NSApp.windows)
        if (![before containsObject:w] && DPBrowserWindow(w) && w.identifier) window = w;
    if (window) DPShrinkLittleWindow(window);
    id tab = window ? DPScriptActiveTab(window) : nil;
    if (tab) {
        @try { [tab setValue:url forKey:@"URL"]; }
        @catch (NSException *e) { NSLog(@"[DiaPatches] little window: opening the link failed: %s", e.reason.UTF8String); }
        [DPLittleWindows addObject:window];
        DPLittlePending = nil;
        objc_setAssociatedObject(window, &DPLittleHomeKey, home, OBJC_ASSOCIATION_ASSIGN);  // checked against NSApp.windows before use
        DPDressLittleWindow(window);
        return;
    }
    if (tries < 75) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ DPAdoptLittleWindow(before, url, home, tries + 1); });
        return;
    }
    window.alphaValue = 1;
    DPLittlePending = nil;
    NSLog(@"[DiaPatches] little window: the new window didn't appear");
}

// The tab takes a moment to reach the home window's list. Only then does the little window close: if it never does,
// the little window stays, so the page isn't lost.
static void DPFinishLittleMove(NSWindow *window, NSWindow *home, NSString *tabID, int tries) {
    NSMutableArray<NSView *> *rows = [NSMutableArray array];
    DPCollectTabRows(home.contentView.superview, rows);
    for (NSView *row in rows) {
        if (![DPTabIDOfRow(row) isEqual:tabID]) continue;
        [DPLittleWindows removeObject:window];
        [home makeKeyAndOrderFront:nil];
        [window performClose:nil];
        return;
    }
    if (tries >= 60) { NSLog(@"[DiaPatches] little window: the moved tab didn't arrive"); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ DPFinishLittleMove(window, home, tabID, tries + 1); });
}

// Moves the live tab through the Move to Window item of its row's menu, so there's no reload and the page stays as
// it was. The row is there even with the sidebar closed.
static BOOL DPMoveLittleTab(NSWindow *window, NSWindow *home) {
    NSString *tabID = DPActiveTabID(window);
    NSMutableArray<NSView *> *rows = [NSMutableArray array];
    DPCollectTabRows(window.contentView.superview, rows);
    NSView *row = nil;
    for (NSView *candidate in rows) if ([DPTabIDOfRow(candidate) isEqual:tabID]) row = candidate;
    NSMenuItem *moveTo = row ? DPMenuItemTitled(DPRowMenu(row), @"Move to Window") : nil;
    if ([moveTo.submenu.delegate respondsToSelector:@selector(menuNeedsUpdate:)]) [moveTo.submenu.delegate menuNeedsUpdate:moveTo.submenu];
    // Windows come first, as "Space — site & 3 Tabs", front to back and including this one, then a separator and
    // New Window. With more than one other window, nothing says for certain which is home: leave it to the script.
    NSMutableArray<NSMenuItem *> *windows = [NSMutableArray array];
    for (NSMenuItem *item in moveTo.submenu.itemArray) {
        if (item.separatorItem) break;
        [windows addObject:item];
    }
    if (windows.count != 2 || ![windows.firstObject.title hasSuffix:@" 1 Tab"]) return NO;
    NSMenuItem *target = windows.lastObject;
    if (![NSApp sendAction:target.action to:target.target from:target]) return NO;
    DPFinishLittleMove(window, home, tabID, 0);
    return YES;
}

static BOOL DPMoveLittleWindow(NSWindow *window) {
    if (!window || ![DPLittleWindows containsObject:window]) return NO;
    NSWindow *home = objc_getAssociatedObject(window, &DPLittleHomeKey);
    if (![NSApp.windows containsObject:home] || !home.isVisible) home = nil;
    for (NSWindow *w in NSApp.orderedWindows)
        if (!home && w != window && DPBrowserWindow(w) && w.identifier && w.isVisible && ![DPLittleWindows containsObject:w]) home = w;
    if (!home) return YES;
    if (DPMoveLittleTab(window, home)) return YES;
    NSString *url = nil;
    @try { url = [DPScriptActiveTab(window) valueForKey:@"URL"]; } @catch (__unused NSException *e) {}
    if (![url isKindOfClass:NSString.class] || !url.length) return YES;
    NSString *body = [NSString stringWithFormat:@"set newTab to make new tab at end of tabs of %@ with properties {URL:\"%@\"}\nfocus newTab",
                                                DPWindowRef(home), DPScriptString(url)];
    if (!DPRunScript(body, @"moving the page")) return YES;  // keep the little window, so the page isn't lost
    [DPLittleWindows removeObject:window];
    [home makeKeyAndOrderFront:nil];
    [window performClose:nil];
    return YES;
}

// Links from other apps arrive here. With no window open yet (Dia launching for the link), they open as usual.
// File > New Window, by its ⌘N, which doesn't depend on the menu's language.
static NSMenuItem *DPNewWindowItem(NSMenu *menu) {
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.keyEquivalent isEqualToString:@"n"] && (item.keyEquivalentModifierMask & NSEventModifierFlagDeviceIndependentFlagsMask) == NSEventModifierFlagCommand)
            return item;
        NSMenuItem *found = item.submenu ? DPNewWindowItem(item.submenu) : nil;
        if (found) return found;
    }
    return nil;
}

// A web link from another app opens in a new window dressed as a little window. NO leaves it to Dia.
static BOOL DPOpenLittle(NSURL *url) {
    NSWindow *home = nil;
    for (NSWindow *w in NSApp.orderedWindows)
        if (!home && DPBrowserWindow(w) && w.identifier && w.isVisible && ![DPLittleWindows containsObject:w]) home = w;
    BOOL web = [url.scheme.lowercaseString isEqualToString:@"http"] || [url.scheme.lowercaseString isEqualToString:@"https"];
    NSLog(@"[DiaPatches] little window: link from another app, tweak %s, main window %s", DPOn[DPLittleWindow] ? "on" : "off",
          home ? "found" : "not found");
    if (!home)
        for (NSWindow *w in NSApp.orderedWindows)
            NSLog(@"[DiaPatches] little window: window %s browser %d identifier %d visible %d", NSStringFromClass(w.class).UTF8String,
                  DPBrowserWindow(w) != nil, w.identifier != nil, w.isVisible);
    if (!DPOn[DPLittleWindow] || !home || !web) return NO;
    NSSet<NSWindow *> *before = [NSSet setWithArray:NSApp.windows];
    DPLittlePending = before;
    NSMenuItem *item = DPNewWindowItem(NSApp.mainMenu);
    if (!item || ![NSApp sendAction:item.action to:item.target from:item]) {
        DPLittlePending = nil;
        NSLog(@"[DiaPatches] little window: New Window didn't run (%s)", item ? NSStringFromSelector(item.action).UTF8String : "no ⌘N menu item");
        return NO;
    }
    for (NSWindow *w in NSApp.windows) if (![before containsObject:w] && DPBrowserWindow(w)) DPShrinkLittleWindow(w);
    DPAdoptLittleWindow(before, url.absoluteString, home, 0);
    return YES;
}

static void DPApp_openURLs(id self, SEL _cmd, NSApplication *app, NSArray<NSURL *> *urls) {
    NSMutableArray<NSURL *> *rest = [NSMutableArray array];
    for (NSURL *url in urls) if (!DPOpenLittle(url)) [rest addObject:url];
    if (rest.count) DPCallOriginal(void (*)(id, SEL, id, id), self, _cmd, app, rest);
}

// Dia takes links from other apps as Get URL Apple Events, so its handler for them is swapped for one that
// tries the little window first.
static id DPURLEventTarget;
static SEL DPURLEventSelector;

@interface DPURLEventHandler : NSObject
@end

@implementation DPURLEventHandler
- (void)handleURLEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)reply {
    NSString *string = [event paramDescriptorForKeyword:keyDirectObject].stringValue;
    NSURL *url = string ? [NSURL URLWithString:string] : nil;
    if (url && DPOpenLittle(url)) return;
    ((void (*)(id, SEL, id, id))objc_msgSend)(DPURLEventTarget, DPURLEventSelector, event, reply);
}
@end

static void DPAEManager_setEventHandler(NSAppleEventManager *self, SEL _cmd, id handler, SEL selector, AEEventClass eventClass, AEEventID eventID) {
    if (eventClass == kInternetEventClass && eventID == kAEGetURL && handler && ![handler isKindOfClass:DPURLEventHandler.class]) {
        static DPURLEventHandler *ours;
        ours = ours ?: [DPURLEventHandler new];
        DPURLEventTarget = handler;
        DPURLEventSelector = selector;
        NSLog(@"[DiaPatches] little window: took over Get URL events from %s", NSStringFromClass([handler class]).UTF8String);
        handler = ours;
        selector = @selector(handleURLEvent:withReplyEvent:);
    }
    DPCallOriginal(void (*)(id, SEL, id, SEL, AEEventClass, AEEventID), self, _cmd, handler, selector, eventClass, eventID);
}

#pragma mark - Move a folder to a space

// A folder with subfolders can't move to a space in another browser profile: Dia greys those out, while a folder
// without any goes anywhere. For those this makes the folder again in the target space, subfolders and all, with
// tabs at the same addresses. The window goes to that space and stays there, since a folder can only be made in the
// space it's showing. Its scripts run in a separate process, since one here would hold up the whole app. The original
// goes only once that worked.
@interface DPSpaceMoveAction : NSObject
@end

static NSDictionary *DPFolderTree(DPTabUtilities *utilities, NSDictionary<NSString *, NSArray<NSString *> *> *info, NSString *folderID, int depth) {
    NSString *title = nil;
    NSMutableArray<DPStripNode *> *children = [NSMutableArray new];
    if (depth > 8 || !DPReadFolder(utilities, folderID, &title, children)) return nil;
    NSMutableArray *tabs = [NSMutableArray new], *folders = [NSMutableArray new];
    for (DPStripNode *child in children) {
        NSDictionary *sub = child.isFolder ? DPFolderTree(utilities, info, child.itemID, depth + 1) : nil;
        if (sub) [folders addObject:sub];
        NSString *url = child.isFolder ? nil : info[child.itemID][1];
        if (url.length) [tabs addObject:url];
    }
    return [@{@"title" : title ?: @"", @"tabs" : tabs, @"folders" : folders} mutableCopy];
}

// `done` gets the result's text, or nil on an error.
static void DPRunScriptAside(NSString *body, void (^done)(NSString *result)) {
    NSString *source = [NSString stringWithFormat:@"tell application \"%@\"\n%@\nend tell", DPScriptString(NSBundle.mainBundle.bundlePath), body];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
        task.arguments = @[@"-e", source];
        NSPipe *output = [NSPipe pipe];
        task.standardOutput = output;
        task.standardError = NSFileHandle.fileHandleWithNullDevice;
        NSString *result = nil;
        if ([task launchAndReturnError:nil]) {
            NSData *data = [output.fileHandleForReading readDataToEndOfFile];
            [task waitUntilExit];
            if (task.terminationStatus == 0) result = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(result); });
    });
}

// All the tabs are made in one script, each folder's starting tab first: a folder begins from a tab. Their IDs go into
// the tree, and the starting tabs into `starters`.
static void DPMakeTreeTabs(NSWindow *window, NSDictionary *tree, NSMutableArray<NSString *> *starters, void (^done)(BOOL ok)) {
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    __block void (^collect)(NSDictionary *);
    void (^walk)(NSDictionary *) = ^(NSDictionary *node) {
        [urls addObject:@""];
        [urls addObjectsFromArray:node[@"tabs"]];
        for (NSDictionary *sub in node[@"folders"]) collect(sub);
    };
    collect = walk;
    walk(tree);
    collect = nil;
    NSMutableArray *quoted = [NSMutableArray array];
    for (NSString *url in urls) [quoted addObject:[NSString stringWithFormat:@"\"%@\"", DPScriptString(url)]];
    DPRunScriptAside([NSString stringWithFormat:
        @"set made to {}\nrepeat with u in {%@}\nif (u as text) is \"\" then\nset t to make new tab at end of tabs of %@\nelse\nset t to make new tab at end of tabs of %@ with properties {URL:(u as text)}\nend if\nset end of made to id of t\nend repeat\n"
         "set AppleScript's text item delimiters to \",\"\nreturn made as text", [quoted componentsJoinedByString:@","], DPWindowRef(window), DPWindowRef(window)], ^(NSString *list) {
        NSLog(@"[DiaPatches] move to space: script process gave ids %d", list.length > 0);
        NSArray<NSString *> *ids = [list componentsSeparatedByString:@","];
        if (ids.count != urls.count) return done(NO);
        __block NSUInteger next = 0;
        __block void (^assign)(NSMutableDictionary *);
        void (^fill)(NSMutableDictionary *) = ^(NSMutableDictionary *node) {
            NSString *starter = ids[next++];
            node[@"starter"] = starter;
            [starters addObject:starter];
            NSUInteger count = [node[@"tabs"] count];
            node[@"tabIDs"] = [ids subarrayWithRange:NSMakeRange(next, count)];
            next += count;
            for (NSMutableDictionary *sub in node[@"folders"]) assign(sub);
        };
        assign = fill;
        fill((NSMutableDictionary *)tree);
        assign = nil;
        done(YES);
    });
}

static void DPBuildFolders(NSWindow *window, NSArray<NSDictionary *> *nodes, NSUInteger index, NSString *parentID, NSString *pinnedSpace, void (^done)(BOOL ok));

// Names and places the new folder and fills it, then its subfolders.
static void DPFillFolder(NSWindow *window, NSDictionary *node, NSString *folderID, NSString *parentID, NSString *pinnedSpace, void (^done)(BOOL ok)) {
    __block BOOL placed = !parentID && !pinnedSpace;
    __block int moved = 0;
    NSArray<NSString *> *tabIDs = node[@"tabIDs"];
    DPWithWindowItems(window, ^(DPTabUtilities *utilities, const void *storage) {
        DPString swiftID = DPSwiftStringFrom(folderID);
        DPRenameFolder(utilities, swiftID, node[@"title"]);
        uint8_t into[0x30] = {0};
        *(DPString *)into = swiftID;
        into[0x20] = 0x80;
        for (NSString *tabID in tabIDs) {
            DPString swiftTab = DPSwiftStringFrom(tabID);
            if (DPMoveItem(utilities, storage, (DPItemID){swiftTab, 0}, into)) moved++;
            DPReleaseSwiftString(swiftTab);
        }
        if (!placed) {
            uint8_t parent[0x30] = {0};
            DPString swiftParent = DPSwiftStringFrom(parentID ?: pinnedSpace);
            *(DPString *)parent = swiftParent;
            parent[0x20] = parentID ? 0x80 : 2;
            placed = DPMoveItem(utilities, storage, (DPItemID){swiftID, 1}, parent);
            DPReleaseSwiftString(swiftParent);
        }
        DPReleaseSwiftString(swiftID);
    });
    NSLog(@"[DiaPatches] move to space: folder placed %d, tabs %d of %lu", placed, moved, (unsigned long)tabIDs.count);
    if (!placed || moved != (int)tabIDs.count) return done(NO);
    DPBuildFolders(window, node[@"folders"], 0, folderID, nil, done);
}

static void DPAwaitNewFolder(NSWindow *window, NSSet<NSString *> *before, int tries, void (^found)(NSString *folderID)) {
    NSMutableSet<NSString *> *now = [DPWindowFolders(window, nil, nil, NULL) mutableCopy];
    [now minusSet:before];
    if (now.count || tries >= 150) return found(now.anyObject);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ DPAwaitNewFolder(window, before, tries + 1, found); });
}

static void DPBuildFolders(NSWindow *window, NSArray<NSDictionary *> *nodes, NSUInteger index, NSString *parentID, NSString *pinnedSpace, void (^done)(BOOL ok)) {
    if (index >= nodes.count) return done(YES);
    NSSet<NSString *> *before = DPWindowFolders(window, nil, nil, NULL);
    NSString *starter = nodes[index][@"starter"];
    // Selected, so that its row is scrolled into view and can be asked for New Group with Tab.
    DPWithWindowItems(window, ^(DPTabUtilities *utilities, const void *storage) {
        DPString swiftTab = DPSwiftStringFrom(starter);
        void **select = (void **)(utilities->tabs + 14 * 16);
        DPSwiftCall(select[0], select[1], swiftTab.bits, swiftTab.object, NULL);
        DPReleaseSwiftString(swiftTab);
    });
    DPGroupNewTab(window, starter, 0);
    DPAwaitNewFolder(window, before, 0, ^(NSString *folderID) {
        if (!folderID) { NSLog(@"[DiaPatches] move to space: the new folder didn't appear"); return done(NO); }
        DPFillFolder(window, nodes[index], folderID, parentID, pinnedSpace, ^(BOOL ok) {
            if (!ok) return done(NO);
            DPBuildFolders(window, nodes, index + 1, parentID, pinnedSpace, done);
        });
    });
}

static NSString *DPSpaceIDNamed(NSString *name) {
    @try {
        for (id profile in [[NSApp valueForKey:@"appleScriptWindows"] valueForKey:@"appleScriptProfiles"][0]) {
            if (![[profile valueForKey:@"name"] isEqual:name]) continue;
            Ivar ivar = class_getInstanceVariable(object_getClass(profile), "spaceID");
            return ivar ? DPStringFromSwift(*(const DPString *)((const uint8_t *)(__bridge void *)profile + ivar_getOffset(ivar))) : nil;
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

static void DPAwaitSpace(NSWindow *window, NSString *spaceID, int tries, void (^arrived)(BOOL ok)) {
    __block BOOL there = NO;
    DPWithWindowItems(window, ^(DPTabUtilities *utilities, const void *storage) {
        DPString current = *(const DPString *)((const uint8_t *)utilities->controller + DPClassFieldOffset(utilities->controller, utilities->spaceField));
        there = [DPStringFromSwift(current) isEqual:spaceID];
    });
    if (there || tries >= 80) {
        // Give the space's sidebar a moment to settle.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ arrived(there); });
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ DPAwaitSpace(window, spaceID, tries + 1, arrived); });
}

static void DPMoveFolderToSpace(NSWindow *window, NSString *folderID, NSString *spaceName, BOOL pinned, NSMenuItem *deleteItem) {
    DPTabUtilities *utilities = calloc(1, sizeof *utilities);
    NSDictionary *tree = nil;
    if (DPLoadTabUtilitiesIn(utilities, window)) {
        tree = DPFolderTree(utilities, DPTabInfo(), folderID, 0);
        DPReleaseTabUtilities(utilities);
    }
    free(utilities);
    NSString *spaceID = DPSpaceIDNamed(spaceName);
    NSLog(@"[DiaPatches] move to space: tree %d, target %d, bookmarks %d", tree != nil, spaceID != nil, pinned);
    if (!tree || !spaceID) return;
    // The script can report an error even though the space changes; whether it did is checked next.
    DPRunScriptAside([NSString stringWithFormat:@"focus (first profile of %@ whose name is \"%@\")", DPWindowRef(window), DPScriptString(spaceName)], ^(NSString *ignored) {
        DPAwaitSpace(window, spaceID, 0, ^(BOOL arrived) {
            NSLog(@"[DiaPatches] move to space: arrived %d", arrived);
            if (!arrived) return;
            NSMutableArray<NSString *> *starters = [NSMutableArray array];
            DPMakeTreeTabs(window, tree, starters, ^(BOOL made) {
                NSLog(@"[DiaPatches] move to space: tabs made %d", made);
                if (!made) return;
                DPBuildFolders(window, @[tree], 0, nil, pinned ? spaceID : nil, ^(BOOL ok) {
                    void (^finish)(void) = ^{
                        BOOL sent = ok && deleteItem && [NSApp sendAction:deleteItem.action to:deleteItem.target from:deleteItem];
                        NSLog(@"[DiaPatches] move to space: built %d, delete item %d, sent %d", ok, deleteItem != nil, sent);
                    };
                    if (!ok) return finish();
                    NSMutableArray *closes = [NSMutableArray array];
                    for (NSString *starter in starters) [closes addObject:[NSString stringWithFormat:@"close (first tab of %@ whose id is \"%@\")", DPWindowRef(window), DPScriptString(starter)]];
                    DPRunScriptAside([closes componentsJoinedByString:@"\n"], ^(NSString *ignored2) { finish(); });
                });
            });
        });
    });
}

@implementation DPSpaceMoveAction
- (void)moveToSpace:(NSMenuItem *)sender {
    NSDictionary *move = sender.representedObject;
    DPMoveFolderToSpace(move[@"window"], move[@"folder"], sender.title, [move[@"pinned"] boolValue], move[@"delete"]);
}
@end

// Whether the folder's row is above the line between the bookmarks and the tabs.
static BOOL DPRowInBookmarks(NSView *row) {
    CGFloat y = [row convertPoint:NSMakePoint(NSMidX(row.bounds), NSMidY(row.bounds)) toView:nil].y;
    for (NSView *separator in DPSeparators.allObjects)
        if (separator.window == row.window && y > [separator convertPoint:NSMakePoint(NSMidX(separator.bounds), NSMidY(separator.bounds)) toView:nil].y) return YES;
    return NO;
}

static void DPTakeOverSpaceMoves(NSMenu *menu, NSMenu *spaces) {
    static DPSpaceMoveAction *action;
    NSEvent *click = NSApp.currentEvent;
    if (click.type != NSEventTypeRightMouseDown && click.type != NSEventTypeLeftMouseDown) return;
    NSView *root = click.window.contentView.superview;
    NSView *cell = root ? [root hitTest:[root convertPoint:click.locationInWindow fromView:nil]] : nil;
    while (cell && !DPIsKind(cell, @"TabUI.TabGroupCellView")) cell = cell.superview;
    NSString *folderID = cell ? DPStripFolderID(cell) : nil;
    if (!folderID) return;
    action = action ?: [DPSpaceMoveAction new];
    spaces.autoenablesItems = NO;
    // Delete where Dia offers it, otherwise Close, which also takes the folder out of the space.
    NSMenuItem *deleteItem = DPMenuItemTitled(menu, @"Delete") ?: DPMenuItemTitled(menu, @"Close");
    NSMutableDictionary *move = [@{@"window" : click.window, @"folder" : folderID, @"pinned" : @(DPRowInBookmarks(cell))} mutableCopy];
    move[@"delete"] = deleteItem;
    for (NSMenuItem *item in spaces.itemArray) {
        if (item.separatorItem || item.enabled || [item.title hasPrefix:@"New Profile"]) continue;
        item.target = action;
        item.action = @selector(moveToSpace:);
        item.representedObject = move;
        item.enabled = YES;
    }
}

#pragma mark - Plain new tab page

// Everything on Dia's new tab page besides its command bar. Dia shows these as it decides they apply, so they're
// hidden after each layout.
static void DPNewTabPage_viewDidLayout(NSViewController *self, SEL _cmd) {
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
    if (!DPOn[DPPlainNewTab]) return;
    static const char *const names[] = {"chatUsageCardHost", "tryForAWeekView", "defaultBrowserUpsellView", "skillsSuggestionsView", "connectAppsUpsellView",
                                        "appsUpsellBarView", "newSingleAppUpsellBarView", "creationGalleryView", "welcomePostcardTeaserView",
                                        "trialGuideStampCardView", "cliaOnboardingViewController"};
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) {
        Ivar ivar = class_getInstanceVariable(object_getClass(self), names[i]);
        id value = ivar ? object_getIvar(self, ivar) : nil;
        NSView *view = [value isKindOfClass:NSViewController.class] ? [(NSViewController *)value view] : value;
        if ([view isKindOfClass:NSView.class] && !view.hidden) view.hidden = YES;
    }
}

#pragma mark - Tab memory

// Each sidebar tab's memory, on the right of its row: the footprint of the renderer processes showing it, the figure
// Activity Monitor shows. Nothing in Dia says which process shows a tab, but a trace does: tracing a tab through its
// DevTools connection starts with an event listing its frames and their processes. A trace records the whole browser,
// so a tab is traced only when it navigates or a process goes away; the numbers come from the processes every tick.
// Dia switches those connections off at launch (ArcFeatureDevToolsProtocolConnectionsEnabled), so this keeps them on.
static const NSUInteger DPProtocolConnectionsFeature = 43;
static const NSTimeInterval DPTabMemoryTickInterval = 10, DPTabMemoryTraceGap = 2, DPTabMemoryRetryAfter = 60;

@protocol DPDevTools
- (NSNumber *)openProtocolConnection:(void (^)(NSString *, NSError *))handler error:(NSError **)error;
- (BOOL)sendProtocolMessage:(NSString *)message connectionID:(NSNumber *)connectionID error:(NSError **)error;
- (void)closeProtocolConnection:(NSNumber *)connectionID;
@end

@protocol DPWebContents
- (id<DPDevTools>)devTools;
- (NSURL *)url;
- (NSString *)title;
- (NSInteger)state;  // 0 is alive; a discarded or frozen tab has no figure worth showing
- (int32_t)navigationID;
@end

@protocol DPBrowserApplication
- (void)setFeatureEnabled:(NSUInteger)feature enabled:(BOOL)enabled;
@end

@interface DPTabMemoryLabel : NSTextField
@end

static void DPRelayOutTabTitles(NSView *view) {
    if (DPIsKind(view, @"TabUI.TabContentView")) { view.needsLayout = YES; return; }
    for (NSView *sub in view.subviews) DPRelayOutTabTitles(sub);
}

@implementation DPTabMemoryLabel
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)showFigure:(BOOL)show {
    if (self.alphaValue == (show ? 1 : 0)) return;
    self.alphaValue = show ? 1 : 0;
    if (self.superview) DPRelayOutTabTitles(self.superview);
}
- (void)setFigure:(NSString *)figure {
    if ([self.stringValue isEqual:figure]) return;
    self.stringValue = figure;
    if (self.superview) DPRelayOutTabTitles(self.superview);
}
- (void)mouseEntered:(NSEvent *)event { [self showFigure:NO]; }  // the row's close button goes here
- (void)mouseExited:(NSEvent *)event { [self showFigure:YES]; }
@end

static __weak id<DPBrowserApplication> DPBrowserApp;
static NSMapTable *DPTabMemoryEntries;  // web contents -> @{nav, pids, at}
static NSHashTable *DPTabMemoryNeeds, *DPTabMemoryLabels;
static BOOL DPTabMemoryBusy;
static char DPTabMemoryLabelKey;

// The title stops short of the figure. Dia lays it out again whenever the row changes, so this follows each layout.
static void DPTabContent_layout(NSView *self, SEL _cmd) {
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
    NSView *row = self.superview;
    while (row && !DPIsKind(row, @"TabUI.TabView")) row = row.superview;
    DPTabMemoryLabel *label = row ? objc_getAssociatedObject(row, &DPTabMemoryLabelKey) : nil;
    if (!label.stringValue.length || label.alphaValue == 0) return;
    Ivar ivar = class_getInstanceVariable(object_getClass(self), "$__lazy_storage_$_titleView");
    void *stored = ivar ? *(void **)((uint8_t *)(__bridge void *)self + ivar_getOffset(ivar)) : NULL;
    if ((uintptr_t)stored < 4096) return;  // not made yet
    NSView *title = (__bridge NSView *)stored;
    const CGFloat gap = 6;
    CGFloat figureWidth = ceil(label.attributedStringValue.size.width);
    CGFloat limit = [title.superview convertPoint:NSMakePoint(NSMaxX(label.frame) - figureWidth - gap, 0) fromView:row].x;
    NSRect frame = title.frame;
    if (NSMaxX(frame) > limit && limit > NSMinX(frame)) {
        frame.size.width = limit - NSMinX(frame);
        title.frame = frame;
    }
}

static void DPApp_setFeatureEnabled(id self, SEL _cmd, NSUInteger feature, BOOL on) {
    DPBrowserApp = self;
    DPCallOriginal(void (*)(id, SEL, NSUInteger, BOOL), self, _cmd, feature, on || (feature == DPProtocolConnectionsFeature && DPOn[DPTabMemory]));
}

// The processes in a trace's opening event.
static void DPCollectTracedProcesses(NSString *message, NSMutableSet<NSNumber *> *pids) {
    if (![message containsString:@"TracingStartedInBrowser"]) return;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[message dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSArray *events = [json isKindOfClass:NSDictionary.class] ? json[@"params"][@"value"] : nil;
    if (![events isKindOfClass:NSArray.class]) return;
    for (NSDictionary *event in events) {
        if (![event isKindOfClass:NSDictionary.class] || ![event[@"name"] isEqual:@"TracingStartedInBrowser"]) continue;
        NSArray *frames = event[@"args"][@"data"][@"frames"];
        if (![frames isKindOfClass:NSArray.class]) continue;
        for (NSDictionary *frame in frames) {
            NSNumber *pid = [frame isKindOfClass:NSDictionary.class] ? frame[@"processId"] : nil;
            if ([pid isKindOfClass:NSNumber.class] && pid.intValue > 0) [pids addObject:pid];
        }
    }
}

// Traces the tab for as short as Chromium allows; `done` gets its processes, empty if that failed.
static void DPTraceTab(id<DPWebContents> webContents, void (^done)(NSArray<NSNumber *> *pids)) {
    id<DPDevTools> tools = webContents.devTools;
    NSMutableSet<NSNumber *> *pids = [NSMutableSet set];
    __block NSNumber *connection = nil;
    __block BOOL finished = NO;
    void (^finish)(void) = ^{
        if (finished) return;
        finished = YES;
        if (connection) [tools closeProtocolConnection:connection];
        done(pids.allObjects);
    };
    connection = [tools openProtocolConnection:^(NSString *message, NSError *error) {
        if (!message) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (finished) return;
            DPCollectTracedProcesses(message, pids);
            if ([message hasPrefix:@"{\"id\":1,"]) {
                if ([message containsString:@"\"error\""]) finish();
                else [tools sendProtocolMessage:@"{\"id\":2,\"method\":\"Tracing.end\"}" connectionID:connection error:nil];
            } else if ([message containsString:@"Tracing.tracingComplete"]) finish();
        });
    } error:nil];
    if (!connection) return finish();
    NSString *start = @"{\"id\":1,\"method\":\"Tracing.start\",\"params\":{\"categories\":\"disabled-by-default-devtools.timeline\",\"transferMode\":\"ReportEvents\"}}";
    if (![tools sendProtocolMessage:start connectionID:connection error:nil]) return finish();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), finish);
}

static void DPTraceNextTab(void) {
    id<DPWebContents> webContents = DPTabMemoryNeeds.anyObject;
    if (DPTabMemoryBusy || !webContents || !DPOn[DPTabMemory]) return;
    [DPTabMemoryNeeds removeObject:webContents];
    DPTabMemoryBusy = YES;
    int32_t navigation = webContents.navigationID;
    __weak id weakContents = webContents;
    DPTraceTab(webContents, ^(NSArray<NSNumber *> *pids) {
        if (weakContents) [DPTabMemoryEntries setObject:@{@"nav" : @(navigation), @"pids" : pids, @"at" : NSDate.date} forKey:weakContents];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DPTabMemoryTraceGap * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            DPTabMemoryBusy = NO;
            DPTraceNextTab();
        });
    });
}

static void DPCollectTabRows(NSView *view, NSMutableArray<NSView *> *rows) {
    if (DPIsKind(view, @"TabUI.TabView")) { [rows addObject:view]; return; }
    for (NSView *sub in view.subviews) DPCollectTabRows(sub, rows);
}

static NSString *DPTabIDOfRow(NSView *row) {
    Ivar modelIvar = class_getInstanceVariable(object_getClass(row), "viewModel");
    id model = modelIvar ? object_getIvar(row, modelIvar) : nil;
    Ivar idIvar = model ? class_getInstanceVariable(object_getClass(model), "tabID") : NULL;
    return idIvar ? DPStringFromSwift(*(const DPString *)((const uint8_t *)(__bridge void *)model + ivar_getOffset(idIvar))) : nil;
}

// The tab's web contents, by address and then title (Dia's scripting names tabs by item ID, Chromium by session).
// It leaves the pool, so tabs open at the same address get one each.
static id<DPWebContents> DPTakeWebContents(NSMutableArray<id<DPWebContents>> *pool, NSString *url, NSString *title) {
    id<DPWebContents> match = nil;
    for (id<DPWebContents> webContents in pool) {
        if (![webContents.url.absoluteString isEqual:url]) continue;
        if (!match) match = webContents;
        if ([webContents.title isEqual:title]) { match = webContents; break; }
    }
    if (match) [pool removeObject:match];
    return match;
}

static DPTabMemoryLabel *DPTabMemoryLabelOfRow(NSView *row) {
    DPTabMemoryLabel *label = objc_getAssociatedObject(row, &DPTabMemoryLabelKey);
    if (label) return label;
    const CGFloat width = 60, height = 14, inset = 8;
    label = [DPTabMemoryLabel labelWithString:@""];
    label.font = [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular];
    label.textColor = NSColor.secondaryLabelColor;
    label.alignment = NSTextAlignmentRight;
    label.frame = NSMakeRect(NSWidth(row.bounds) - width - inset, (NSHeight(row.bounds) - height) / 2, width, height);
    label.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    [row addSubview:label];
    [row addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                      options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                        owner:label userInfo:nil]];
    objc_setAssociatedObject(row, &DPTabMemoryLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [DPTabMemoryLabels addObject:label];
    return label;
}

static void DPTabMemoryTick(void) {
    if (!DPOn[DPTabMemory]) {
        for (DPTabMemoryLabel *label in DPTabMemoryLabels.allObjects) [label setFigure:@""];
        return;
    }
    NSMutableArray<NSView *> *rows = [NSMutableArray array];
    for (NSWindow *window in NSApp.windows)
        if (DPBrowserWindow(window) && window.isVisible) DPCollectTabRows(window.contentView.superview, rows);
    NSMutableArray<id<DPWebContents>> *pool = [NSMutableArray array];
    for (id<DPWebContents> webContents in DPTabsWebContents()) if (webContents.state == 0) [pool addObject:webContents];
    NSDictionary<NSString *, NSArray<NSString *> *> *info = DPTabInfo();
    NSMapTable *contentsByRow = [NSMapTable strongToStrongObjectsMapTable];
    [DPTabMemoryNeeds removeAllObjects];
    for (NSView *row in rows) {
        const CGFloat smallestRow = 120;  // a favourite's icon has no room
        NSString *tabID = NSWidth(row.bounds) >= smallestRow ? DPTabIDOfRow(row) : nil;
        NSArray<NSString *> *tab = tabID ? info[tabID] : nil;
        id<DPWebContents> webContents = tab ? DPTakeWebContents(pool, tab[1], tab[0]) : nil;
        if (!webContents) continue;
        [contentsByRow setObject:webContents forKey:row];
        NSDictionary *entry = [DPTabMemoryEntries objectForKey:webContents];
        BOOL stale = !entry || [entry[@"nav"] intValue] != webContents.navigationID
            || (![entry[@"pids"] count] && -[entry[@"at"] timeIntervalSinceNow] > DPTabMemoryRetryAfter);
        if (stale) [DPTabMemoryNeeds addObject:webContents];
    }
    NSPoint mouse = NSEvent.mouseLocation;
    for (NSView *row in rows) {
        id<DPWebContents> webContents = [contentsByRow objectForKey:row];
        if (!webContents) {
            [(DPTabMemoryLabel *)objc_getAssociatedObject(row, &DPTabMemoryLabelKey) setFigure:@""];
            continue;
        }
        NSDictionary *entry = [DPTabMemoryEntries objectForKey:webContents];
        uint64_t bytes = 0;
        BOOL gone = NO;
        for (NSNumber *pid in entry[@"pids"]) {
            struct rusage_info_v4 usage;
            if (proc_pid_rusage(pid.intValue, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) { gone = YES; continue; }
            bytes += usage.ri_phys_footprint;
        }
        if (gone) [DPTabMemoryNeeds addObject:webContents];
        DPTabMemoryLabel *label = DPTabMemoryLabelOfRow(row);
        [label setFigure:bytes ? [NSString stringWithFormat:@"%llu MB", bytes / (1024 * 1024)] : @""];
        // The row may have been reused for another tab while the pointer sat on it.
        [label showFigure:!NSPointInRect([row.window convertPointFromScreen:mouse], [row convertRect:row.bounds toView:nil])];
    }
    DPTraceNextTab();
}

static void DPApplyTabMemory(void) {
    [DPBrowserApp setFeatureEnabled:DPProtocolConnectionsFeature enabled:DPOn[DPTabMemory]];
    DPTabMemoryTick();
}

static void DPStartTabMemory(void) {
    DPTabMemoryEntries = [NSMapTable weakToStrongObjectsMapTable];
    DPTabMemoryNeeds = [NSHashTable weakObjectsHashTable];
    DPTabMemoryLabels = [NSHashTable weakObjectsHashTable];
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:DPTabMemoryTickInterval repeats:YES block:^(NSTimer *_) { DPTabMemoryTick(); }];
    timer.tolerance = DPTabMemoryTickInterval / 5;
}

#pragma mark - Phone access

// While Phone access is on, every space (favorites, bookmarks with their folders, and open tabs) is written
// once a day to DiaPatches/mobile/sidebar.json, where diapatch-mobile, run by launchd, serves it to a phone.
static NSString *const DPPhoneAgent = @"com.diapatches.mobile";
static const int DPPhonePort = 7480;
static NSTimer *DPPhoneTimer;

static NSString *DPSupportPath(NSString *name) {
    return [DPCLI().stringByDeletingLastPathComponent.stringByDeletingLastPathComponent stringByAppendingPathComponent:name];
}

static id DPExportNode(DPTabUtilities *utilities, NSDictionary<NSString *, NSArray<NSString *> *> *info, NSString *itemID, BOOL isFolder, int depth) {
    if (isFolder) {
        NSString *title = nil;
        NSMutableArray<DPStripNode *> *children = [NSMutableArray new];
        if (depth > 8 || !DPReadFolder(utilities, itemID, &title, children)) return nil;
        NSMutableArray *out = [NSMutableArray new];
        for (DPStripNode *child in children) {
            id node = DPExportNode(utilities, info, child.itemID, child.isFolder, depth + 1);
            if (node) [out addObject:node];
        }
        return @{@"title": title ?: @"", @"children": out};
    }
    NSArray<NSString *> *tab = info[itemID];
    if (!tab[1].length) return nil;
    NSMutableDictionary *node = [@{@"title": tab[0], @"url": tab[1]} mutableCopy];
    node[@"icon"] = DPArcBarSiteKey(tab[1]);
    return node;
}

// The items under a TabItemParent, as for DPPinnedFolders.
static NSArray *DPExportRoot(DPTabUtilities *utilities, NSDictionary *info, const uint8_t parent[0x30]) {
    void (*release)(void *) = dlsym(RTLD_DEFAULT, "swift_release");
    void **root = (void **)(utilities->queries + 35 * 16);
    DPPair items = DPSwiftCall(root[0], root[1], (uint64_t)parent, 0, NULL);
    release((void *)items.x0);
    NSMutableArray *out = [NSMutableArray new];
    int64_t count = items.x1 ? *(const int64_t *)((const uint8_t *)items.x1 + 0x10) : 0;
    const DPItemID *ids = items.x1 ? (const void *)((const uint8_t *)items.x1 + 0x20) : NULL;
    for (int64_t i = 0; i < count; i++) {
        NSString *itemID = DPStringFromSwift(ids[i].id);
        id node = itemID ? DPExportNode(utilities, info, itemID, ids[i].tag == 1, 0) : nil;
        if (node) [out addObject:node];
    }
    if (items.x1) release((void *)items.x1);
    return out;
}

// Every space, open in a window or not: Dia's scripting lists them (as "profiles") with their tabs, and each one's
// spaceID ivar is what Dia's tab model takes, so their favorites, bookmarks and folders come from the model too.
// The model a window holds knows only its own browser profile's spaces, so each window's is tried. A space no
// window's model knows keeps what was read before, or else gets its tabs from scripting without folders.
static void DPExportSpaces(void) {
    enum { DPMaxModels = 8 };
    DPTabUtilities models[DPMaxModels] = {{0}};
    int modelCount = 0;
    for (NSWindow *window in NSApp.orderedWindows)
        if (window.visible && modelCount < DPMaxModels && DPLoadTabUtilitiesIn(&models[modelCount], window)) modelCount++;
    if (!modelCount) return;

    NSString *path = DPSupportPath(@"mobile/sidebar.json");
    NSData *old = [NSData dataWithContentsOfFile:path];
    id previous = old ? [NSJSONSerialization JSONObjectWithData:old options:0 error:nil] : nil;
    NSMutableDictionary<NSString *, NSDictionary *> *before = [NSMutableDictionary new];
    for (NSDictionary *s in [previous isKindOfClass:NSDictionary.class] ? previous[@"spaces"] : nil)
        if ([s isKindOfClass:NSDictionary.class] && [s[@"id"] isKindOfClass:NSString.class]) before[s[@"id"]] = s;

    NSMutableArray *spaces = [NSMutableArray new];
    NSNumber *now = @((long long)NSDate.date.timeIntervalSince1970);
    @try {
        NSArray *windows = [NSApp valueForKey:@"appleScriptWindows"];
        for (id profile in [windows.firstObject valueForKey:@"appleScriptProfiles"]) {
            Ivar ivar = class_getInstanceVariable(object_getClass(profile), "spaceID");
            if (!ivar) break;
            DPString spaceID = *(const DPString *)((const uint8_t *)(__bridge void *)profile + ivar_getOffset(ivar));
            NSString *spaceKey = DPStringFromSwift(spaceID);
            if (!spaceKey.length) continue;
            id name = [profile valueForKey:@"name"];
            name = [name isKindOfClass:NSString.class] ? name : @"";
            NSMutableDictionary<NSString *, NSArray<NSString *> *> *info = [NSMutableDictionary new];
            NSMutableArray *pinnedTabs = [NSMutableArray new], *otherTabs = [NSMutableArray new];
            for (id tab in [profile valueForKey:@"appleScriptTabs"]) {
                id tabID = [tab valueForKey:@"tabId"], title = [tab valueForKey:@"title"], url = [tab valueForKey:@"URL"];
                if (![tabID isKindOfClass:NSString.class] || ![url isKindOfClass:NSString.class] || ![url length]) continue;
                info[tabID] = @[[title isKindOfClass:NSString.class] ? title : @"", url];
                id node = DPExportNode(NULL, info, tabID, NO, 0);
                [[[tab valueForKey:@"isPinned"] boolValue] ? pinnedTabs : otherTabs addObject:node];
            }

            NSArray *favorites = nil, *bookmarks = nil;
            NSMutableArray *tabs = [NSMutableArray new];
            for (int m = 0; m < modelCount && !favorites.count && !bookmarks.count; m++) {
                uint8_t parent[0x30] = {0};
                *(DPString *)parent = spaceID;
                parent[0x20] = 1;  // favorites
                favorites = DPExportRoot(&models[m], info, parent);
                parent[0x20] = 2;  // pinned: the sidebar's bookmarks
                bookmarks = DPExportRoot(&models[m], info, parent);
                if (!favorites.count && !bookmarks.count) continue;
                for (id window in windows) {  // each window keeps its own tabs in each space
                    NSString *windowKey = [window valueForKey:@"windowId"];
                    if (![windowKey isKindOfClass:NSString.class]) continue;
                    DPString windowID = DPSwiftStringFrom(windowKey);
                    *(DPString *)(parent + 0x10) = windowID;
                    parent[0x20] = 0;
                    [tabs addObjectsFromArray:DPExportRoot(&models[m], info, parent)];
                    DPReleaseSwiftString(windowID);
                    memset(parent + 0x10, 0, 0x10);
                }
            }
            if (favorites.count || bookmarks.count)
                [spaces addObject:@{@"id": spaceKey, @"name": name, @"updated": now, @"favorites": favorites, @"bookmarks": bookmarks, @"tabs": tabs}];
            else if (before[spaceKey] && ![before[spaceKey][@"partial"] boolValue]) {
                NSMutableDictionary *kept = [before[spaceKey] mutableCopy];
                kept[@"name"] = name;
                [spaces addObject:kept];
            } else
                [spaces addObject:@{@"id": spaceKey, @"name": name, @"updated": now, @"partial": @YES,
                                    @"favorites": pinnedTabs, @"bookmarks": otherTabs, @"tabs": @[]}];
        }
    } @catch (__unused NSException *e) {}
    for (int m = 0; m < modelCount; m++) DPReleaseTabUtilities(&models[m]);
    if (!spaces.count) return;

    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"spaces": spaces} options:0 error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions: @0700} error:nil];
    [json writeToFile:path atomically:YES];
}

static void DPLaunchctl(NSArray<NSString *> *args) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    task.arguments = args;
    task.standardOutput = task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if ([task launchAndReturnError:nil]) [task waitUntilExit];
}

static NSString *DPPhoneAgentPath(void) {
    return [NSHomeDirectory() stringByAppendingFormat:@"/Library/LaunchAgents/%@.plist", DPPhoneAgent];
}

static void DPStartPhoneExport(void) {
    [DPPhoneTimer invalidate];
    // Once a day is enough. Reading every space takes the main thread for about 0.1 s, so unless there's nothing
    // written yet it waits for a pause in typing and pointing; the timer looks every ten minutes.
    DPPhoneTimer = [[NSTimer alloc] initWithFireDate:[NSDate dateWithTimeIntervalSinceNow:60] interval:600 repeats:YES block:^(NSTimer *_) {
        NSDate *written = [NSFileManager.defaultManager attributesOfItemAtPath:DPSupportPath(@"mobile/sidebar.json") error:nil].fileModificationDate;
        if (written && -written.timeIntervalSinceNow < 24 * 60 * 60) return;
        if (written && CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType) < 3) return;
        DPExportSpaces();
    }];
    [NSRunLoop.mainRunLoop addTimer:DPPhoneTimer forMode:NSRunLoopCommonModes];
}

// Turns the server on or off with the switch, and the export with it.
static void DPApplyPhoneAccess(void) {
    NSString *domain = [NSString stringWithFormat:@"gui/%d", getuid()];
    DPLaunchctl(@[@"bootout", [domain stringByAppendingFormat:@"/%@", DPPhoneAgent]]);
    if (!DPOn[DPPhoneAccess]) {
        [DPPhoneTimer invalidate];
        DPPhoneTimer = nil;
        [NSFileManager.defaultManager removeItemAtPath:DPPhoneAgentPath() error:nil];
        return;
    }
    NSString *tokenPath = DPSupportPath(@"mobile/token");
    [NSFileManager.defaultManager createDirectoryAtPath:tokenPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions: @0700} error:nil];
    if (![NSFileManager.defaultManager fileExistsAtPath:tokenPath]) {
        uint8_t bytes[16];
        arc4random_buf(bytes, sizeof bytes);
        NSMutableString *token = [NSMutableString new];
        for (size_t i = 0; i < sizeof bytes; i++) [token appendFormat:@"%02x", bytes[i]];
        [NSFileManager.defaultManager createFileAtPath:tokenPath contents:[token dataUsingEncoding:NSUTF8StringEncoding]
                                            attributes:@{NSFilePosixPermissions: @0600}];
    }
    NSDictionary *agent = @{
        @"Label": DPPhoneAgent,
        @"ProgramArguments": @[DPSupportPath(@"bin/diapatch-mobile")],
        @"EnvironmentVariables": @{@"DIAPATCH_HOME": DPSupportPath(@"")},
        @"RunAtLoad": @YES,
        @"KeepAlive": @YES,
        @"ProcessType": @"Background",
        @"StandardErrorPath": DPSupportPath(@"mobile/server.log"),
    };
    [NSFileManager.defaultManager createDirectoryAtPath:DPPhoneAgentPath().stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [agent writeToFile:DPPhoneAgentPath() atomically:YES];
    DPLaunchctl(@[@"bootstrap", domain, DPPhoneAgentPath()]);
    DPExportSpaces();
    DPStartPhoneExport();
}

// Where a phone reaches the page: the Mac's Tailscale address when it has one, else its local network address.
static NSString *DPPhoneURL(void) {
    NSString *token = [[NSString stringWithContentsOfFile:DPSupportPath(@"mobile/token") encoding:NSUTF8StringEncoding error:nil]
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!token.length) return nil;
    NSString *tailscale = nil, *local = nil;
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) == 0) {
        for (struct ifaddrs *i = list; i; i = i->ifa_next) {
            if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || (i->ifa_flags & IFF_LOOPBACK) || !(i->ifa_flags & IFF_UP)) continue;
            uint32_t ip = ntohl(((struct sockaddr_in *)i->ifa_addr)->sin_addr.s_addr);
            char text[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, text, sizeof text);
            if ((ip & 0xffc00000) == 0x64400000) tailscale = tailscale ?: @(text);  // 100.64.0.0/10
            else if ((ip >> 24) == 10 || (ip >> 20) == 0xac1 || (ip >> 16) == 0xc0a8) local = local ?: @(text);
        }
        freeifaddrs(list);
    }
    NSString *host = tailscale ?: local ?: NSProcessInfo.processInfo.hostName;
    return [NSString stringWithFormat:@"http://%@:%d/%@/", host, DPPhonePort, token];
}

@class DPStripMenu;

@interface DPStripMenuView : NSView
@property (nonatomic, weak) DPStripMenu *owner;
@property (nonatomic, copy) NSArray<DPStripNode *> *rows;
@property (nonatomic) NSInteger hovered;
@end

@interface DPStripMenu : NSObject <NSWindowDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) DPStripMenuView *list;
@property (nonatomic, weak) NSWindow *host;
@property (nonatomic, copy) NSString *rootID;
@property (nonatomic, strong) NSMutableSet<NSString *> *expanded;
@property (nonatomic, strong) NSDictionary<NSString *, NSArray<NSString *> *> *tabs;
@property (nonatomic, strong) id monitor;
@property (nonatomic) NSPoint topLeft;
@property (nonatomic, weak) NSView *anchor;
@property (nonatomic) BOOL hovering;
@property (nonatomic, strong) NSTimer *hoverTimer;
@property (nonatomic) NSInteger outsideTicks;
- (void)showFolder:(NSString *)folderID below:(NSView *)anchor hover:(BOOL)hover;
- (void)close;
- (void)activate:(DPStripNode *)node;
@end

static const CGFloat DPStripRowHeight = 28, DPStripMenuWidth = 300, DPStripIndent = 16;

@implementation DPStripMenuView

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}

- (NSInteger)rowAt:(NSPoint)point {
    NSInteger row = (NSInteger)floor((point.y - 6) / DPStripRowHeight);
    return row >= 0 && row < (NSInteger)self.rows.count ? row : -1;
}

- (void)mouseMoved:(NSEvent *)event {
    NSInteger row = [self rowAt:[self convertPoint:event.locationInWindow fromView:nil]];
    if (row != self.hovered) { self.hovered = row; self.needsDisplay = YES; }
}

- (void)mouseExited:(NSEvent *)event { self.hovered = -1; self.needsDisplay = YES; }

- (void)mouseDown:(NSEvent *)event {
    NSInteger row = [self rowAt:[self convertPoint:event.locationInWindow fromView:nil]];
    if (row >= 0) [self.owner activate:self.rows[row]];
}

- (void)drawRect:(NSRect)dirty {
    NSDictionary *font = @{NSFontAttributeName: [NSFont systemFontOfSize:13], NSForegroundColorAttributeName: NSColor.labelColor};
    NSMutableParagraphStyle *truncate = [NSMutableParagraphStyle new];
    truncate.lineBreakMode = NSLineBreakByTruncatingTail;
    NSMutableDictionary *titleFont = [font mutableCopy];
    titleFont[NSParagraphStyleAttributeName] = truncate;
    for (NSInteger i = 0; i < (NSInteger)self.rows.count; i++) {
        DPStripNode *node = self.rows[i];
        NSRect row = NSMakeRect(6, 6 + i * DPStripRowHeight, NSWidth(self.bounds) - 12, DPStripRowHeight);
        if (i == self.hovered) {
            [[NSColor.labelColor colorWithAlphaComponent:0.08] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:row xRadius:6 yRadius:6] fill];
        }
        CGFloat x = NSMinX(row) + 8 + node.depth * DPStripIndent;
        NSImage *icon = nil;
        if (node.isFolder) {
            BOOL open = [self.owner.expanded containsObject:node.itemID];
            NSImage *chevron = [[NSImage imageWithSystemSymbolName:open ? @"chevron.down" : @"chevron.right" accessibilityDescription:nil]
                                imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:9 weight:NSFontWeightSemibold]];
            chevron = [chevron imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.secondaryLabelColor]]];
            [chevron drawInRect:NSMakeRect(x, NSMidY(row) - chevron.size.height / 2, chevron.size.width, chevron.size.height)];
            icon = [[NSImage imageWithSystemSymbolName:@"folder.fill" accessibilityDescription:nil]
                    imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular]];
            icon = [icon imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.secondaryLabelColor]]];
        } else {
            icon = DPArcBarFavicon(node.url) ?: [NSImage imageWithSystemSymbolName:@"globe" accessibilityDescription:nil];
        }
        x += 14;
        if (icon) [icon drawInRect:NSMakeRect(x, NSMidY(row) - 8, 16, 16) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
        x += 24;
        NSString *title = node.title.length ? node.title : node.isFolder ? @"Folder" : @"Untitled";
        CGFloat height = [title sizeWithAttributes:font].height;
        [title drawInRect:NSMakeRect(x, NSMidY(row) - height / 2, NSMaxX(row) - x - 8, height) withAttributes:titleFont];
    }
}

@end

@implementation DPStripMenu

+ (instancetype)shared {
    static DPStripMenu *menu;
    menu = menu ?: [DPStripMenu new];
    return menu;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _expanded = [NSMutableSet new];
    _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, DPStripMenuWidth, 100)
                                        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:YES];
    _panel.opaque = NO;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.hasShadow = YES;
    _panel.level = NSPopUpMenuWindowLevel;
    _panel.releasedWhenClosed = NO;
    _panel.hidesOnDeactivate = YES;
    _panel.delegate = self;
    NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:_panel.contentView.bounds];
    background.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    background.material = NSVisualEffectMaterialMenu;
    background.state = NSVisualEffectStateActive;
    background.wantsLayer = YES;
    background.layer.cornerRadius = 10;
    background.layer.masksToBounds = YES;
    _panel.contentView = background;
    _scroll = [[NSScrollView alloc] initWithFrame:background.bounds];
    _scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _list = [DPStripMenuView new];
    _list.owner = self;
    _list.hovered = -1;
    _scroll.documentView = _list;
    [background addSubview:_scroll];
    return self;
}

- (void)appendFolder:(NSString *)folderID depth:(NSInteger)depth utilities:(DPTabUtilities *)utilities into:(NSMutableArray *)rows {
    NSMutableArray<DPStripNode *> *children = [NSMutableArray new];
    if (!DPReadFolder(utilities, folderID, NULL, children)) return;
    for (DPStripNode *node in children) {
        node.depth = depth;
        if (node.isFolder) {
            NSString *title = nil;
            DPReadFolder(utilities, node.itemID, &title, [NSMutableArray new]);
            node.title = title;
        } else {
            NSArray<NSString *> *tab = self.tabs[node.itemID];
            node.title = tab[0];
            node.url = tab[1];
        }
        [rows addObject:node];
        if (node.isFolder && [self.expanded containsObject:node.itemID] && depth < 12)
            [self appendFolder:node.itemID depth:depth + 1 utilities:utilities into:rows];
    }
}

- (void)reload {
    DPTabUtilities *utilities = calloc(1, sizeof *utilities);
    NSMutableArray *rows = [NSMutableArray new];
    if (DPLoadTabUtilitiesIn(utilities, self.host)) {
        [self appendFolder:self.rootID depth:0 utilities:utilities into:rows];
        DPReleaseTabUtilities(utilities);
    }
    free(utilities);
    self.list.rows = rows;
    CGFloat contentHeight = rows.count * DPStripRowHeight + 12;
    // Stays where it opened while folders in it expand, even if the strip moves the chip.
    CGFloat height = MIN(contentHeight, MAX(120, self.topLeft.y - NSMinY(self.host.screen.visibleFrame) - 8));
    [self.panel setFrame:NSMakeRect(self.topLeft.x, self.topLeft.y - height, DPStripMenuWidth, height) display:YES];
    self.list.frame = NSMakeRect(0, 0, DPStripMenuWidth, contentHeight);
    self.list.needsDisplay = YES;
}

- (NSRect)anchorRect {
    NSView *anchor = self.anchor;
    return anchor.window ? [anchor.window convertRectToScreen:[anchor convertRect:anchor.bounds toView:nil]] : NSZeroRect;
}

// Opened by pointing, it closes once the pointer has left both the folder and the menu for a moment.
// Opened by clicking, or once used, it stays until a click elsewhere or Esc.
- (void)showFolder:(NSString *)folderID below:(NSView *)anchor hover:(BOOL)hover {
    if (self.panel.isVisible) [self close];
    self.anchor = anchor;
    self.hovering = hover;
    self.outsideTicks = 0;
    self.host = anchor.window;
    self.rootID = folderID;
    self.tabs = DPTabInfo();
    self.panel.appearance = self.host.effectiveAppearance;
    NSRect frame = [anchor.window convertRectToScreen:[anchor convertRect:anchor.bounds toView:nil]];
    self.topLeft = NSMakePoint(MIN(NSMinX(frame), NSMaxX(self.host.screen.visibleFrame) - DPStripMenuWidth - 8), NSMinY(frame) - 4);
    [self reload];
    [self.host addChildWindow:self.panel ordered:NSWindowAbove];
    [self.panel orderFront:nil];
    __weak typeof(self) weakSelf = self;
    self.hoverTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        DPStripMenu *me = weakSelf;
        if (!me.hovering) return;
        NSRect area = NSInsetRect(NSUnionRect(me.anchorRect, me.panel.frame), -4, -4);
        me.outsideTicks = NSPointInRect(NSEvent.mouseLocation, area) ? 0 : me.outsideTicks + 1;
        if (me.outsideTicks >= 3) [me close];
    }];
    // Clicks elsewhere, and Esc, close it like a menu.
    self.monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        DPStripMenu *me = weakSelf;
        if (event.type == NSEventTypeKeyDown) {
            if (event.keyCode == 53) { [me close]; return nil; }
            return event;
        }
        // A click on the folder itself is left to its own handler, which toggles the menu.
        if (event.window != me.panel && !(event.window && NSPointInRect(NSEvent.mouseLocation, me.anchorRect))) [me close];
        return event;
    }];
}

- (void)close {
    if (self.monitor) [NSEvent removeMonitor:self.monitor];
    self.monitor = nil;
    [self.hoverTimer invalidate];
    self.hoverTimer = nil;
    [self.host removeChildWindow:self.panel];
    [self.panel orderOut:nil];
}

- (void)activate:(DPStripNode *)node {
    self.hovering = NO;
    if (node.isFolder) {
        if ([self.expanded containsObject:node.itemID]) [self.expanded removeObject:node.itemID];
        else [self.expanded addObject:node.itemID];
        [self reload];
        return;
    }
    DPTabUtilities *utilities = calloc(1, sizeof *utilities);
    if (DPLoadTabUtilitiesIn(utilities, self.host)) {
        DPString tabID = DPSwiftStringFrom(node.itemID);
        void **select = (void **)(utilities->tabs + 14 * 16);
        DPSwiftCall(select[0], select[1], tabID.bits, tabID.object, NULL);
        DPReleaseSwiftString(tabID);
        DPReleaseTabUtilities(utilities);
    }
    free(utilities);
    [self close];
}

@end

static NSString *DPStripFolderID(NSView *view) {
    Ivar ivar = class_getInstanceVariable(view.class, "viewModel");
    void *model = ivar ? *(void **)((uint8_t *)(__bridge void *)view + ivar_getOffset(ivar)) : NULL;
    if (!model || strcmp(class_getName(object_getClass((__bridge id)model)), "TabUI.TabGroupViewModel") != 0) return nil;
    return DPStringFromSwift(*(const DPString *)((const uint8_t *)model + DPClassFieldOffset(model, 0)));
}

// A folder chip in the tab strip lying inside another folder's expanded area.
static BOOL DPIsNestedStripFolder(NSView *view) {
    if (!DPIsKind(view.superview, @"TabStrip.TabStripContainerView")) return NO;
    for (NSView *other in view.superview.subviews)
        if (other != view && [other isKindOfClass:view.class] && !other.hidden && NSWidth(other.frame) > NSWidth(view.frame)
            && NSContainsRect(NSInsetRect(other.frame, -1, -1), view.frame))
            return YES;
    return NO;
}

// The folder at a point of the tab strip. An expanded folder's view lies above the chips of the folders inside it,
// so the smallest folder there is the one meant.
static NSView *DPStripChipAt(NSView *strip, NSPoint point) {
    Class groupView = NSClassFromString(@"_TtC5TabUI12TabGroupView");
    NSView *chip = nil;
    for (NSView *other in strip.subviews)
        if ([other isKindOfClass:groupView] && !other.hidden && NSPointInRect(point, other.frame) && (!chip || NSWidth(other.frame) < NSWidth(chip.frame)))
            chip = other;
    return chip;
}

// Whether a folder in the tab strip drops down instead of opening in the bar.
static BOOL DPStripFolderDropsDown(NSView *chip) {
    if (!DPDependencyContext || !DPIsKind(chip.superview, @"TabStrip.TabStripContainerView")) return NO;
    return DPOn[DPFolderDropdowns] || (DPOn[DPNestedFolders] && DPIsNestedStripFolder(chip));
}

static void DPStripGroup_mouseDown(NSView *self, SEL _cmd, NSEvent *event) {
    NSView *chip = DPIsKind(self.superview, @"TabStrip.TabStripContainerView")
        ? DPStripChipAt(self.superview, [self.superview convertPoint:event.locationInWindow fromView:nil]) : nil;
    NSString *folderID = chip && DPStripFolderDropsDown(chip) ? DPStripFolderID(chip) : nil;
    if (!folderID) return DPCallOriginal(void (*)(id, SEL, NSEvent *), self, _cmd, event);
    // The strip opens the folder in place when the click ends, so that mouse up is dropped.
    static id monitor;
    if (!monitor) monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp handler:^NSEvent *(NSEvent *up) {
        [NSEvent removeMonitor:monitor];
        monitor = nil;
        return nil;
    }];
    DPStripMenu *menu = [DPStripMenu shared];
    if (menu.panel.isVisible && [menu.rootID isEqualToString:folderID]) {
        if (menu.hovering) menu.hovering = NO;
        else [menu close];
        return;
    }
    [menu showFolder:folderID below:chip hover:NO];
}

// Folders that drop down are closed in the strip, once each.
static void DPCollapseNestedStripFolder(NSView *view) {
    static NSMutableSet<NSString *> *collapsed;
    collapsed = collapsed ?: [NSMutableSet new];
    if (!DPStripFolderDropsDown(view)) return;
    NSString *folderID = DPStripFolderID(view);
    if (!folderID || [collapsed containsObject:folderID]) return;
    [collapsed addObject:folderID];
    NSWindow *window = view.window;
    dispatch_async(dispatch_get_main_queue(), ^{
        DPTabUtilities *utilities = calloc(1, sizeof *utilities);
        if (DPLoadTabUtilitiesIn(utilities, window)) {
            DPString key = DPSwiftStringFrom(folderID);
            void **collapse = (void **)(utilities->tabs + 34 * 16);
            DPSwiftCall4(collapse[0], collapse[1], key.bits, key.object, 1, 0, NULL);
            DPReleaseSwiftString(key);
            DPReleaseTabUtilities(utilities);
        }
        free(utilities);
    });
}

// The folder in the tab strip under the pointer, if the pointer is on a folder rather than a tab.
static NSView *DPStripChipUnderMouse(void) {
    NSPoint mouse = NSEvent.mouseLocation;
    NSWindow *window = [NSApp windowWithWindowNumber:[NSWindow windowNumberAtPoint:mouse belowWindowWithWindowNumber:0]];
    NSView *frame = window.contentView.superview;
    NSView *hit = [frame hitTest:[window convertPointFromScreen:mouse]];
    while (hit && !DPIsKind(hit.superview, @"TabStrip.TabStripContainerView")) hit = hit.superview;
    if (![hit isKindOfClass:NSClassFromString(@"_TtC5TabUI12TabGroupView")]) return nil;
    return DPStripChipAt(hit.superview, [hit.superview convertPoint:[window convertPointFromScreen:mouse] fromView:nil]);
}

// Whether a window of Dia's hover menu shows a folder: it lists folders with the sidebar's list view.
static BOOL DPShowsFolderList(NSView *view, int depth) {
    if (DPIsKind(view, @"TabList.TabListView")) return YES;
    if (depth > 8) return NO;
    for (NSView *subview in view.subviews)
        if (DPShowsFolderList(subview, depth + 1)) return YES;
    return NO;
}

// Dia's hover menu for a folder in the tab strip lists it with the sidebar's list, where folders inside don't open.
// It's replaced by the dropdown, or with dropdowns off, not shown. Tab previews and Dia's other menus still show.
static BOOL DPSuppressFolderHoverMenu(NSWindow *window, NSView *chip) {
    return chip || ([DPStripMenu shared].panel.isVisible && DPShowsFolderList(window.contentView, 0));
}

static void DPShowHoverDropdown(NSView *chip) {
    NSString *folderID = chip && DPOn[DPFolderDropdowns] && DPStripFolderDropsDown(chip) ? DPStripFolderID(chip) : nil;
    DPStripMenu *menu = [DPStripMenu shared];
    if (folderID && !(menu.panel.isVisible && [menu.rootID isEqualToString:folderID]))
        [menu showFolder:folderID below:chip hover:YES];
}

static void DPHoverMenuWindow_orderWindow(NSWindow *self, SEL _cmd, NSWindowOrderingMode place, NSInteger other) {
    NSView *chip = place != NSWindowOut ? DPStripChipUnderMouse() : nil;
    if (place == NSWindowOut || !DPSuppressFolderHoverMenu(self, chip))
        return DPCallOriginal(void (*)(id, SEL, NSWindowOrderingMode, NSInteger), self, _cmd, place, other);
    DPShowHoverDropdown(chip);
}

static void DPHoverMenuWindow_orderFrontRegardless(NSWindow *self, SEL _cmd) {
    DPHoverMenuWindow_orderWindow(self, @selector(orderWindow:relativeTo:), NSWindowAbove, 0);
}

// Dia can also bring its menu back when the pointer moves on to another folder, so visible folder menus are put
// away, and with the dropdown open, pointing at another folder switches it there, like a menu bar.
static void DPWatchFolderHoverMenus(Class hoverMenuWindow) {
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        if (!NSApp.isActive) return;
        NSView *chip = nil;
        BOOL looked = NO;
        for (NSWindow *window in NSApp.windows) {
            if (![window isKindOfClass:hoverMenuWindow] || !window.isVisible) continue;
            if (!looked) { chip = DPStripChipUnderMouse(); looked = YES; }
            if (DPShowsFolderList(window.contentView, 0) && DPSuppressFolderHoverMenu(window, chip)) [window orderOut:nil];
        }
        if ([DPStripMenu shared].panel.isVisible) DPShowHoverDropdown(looked ? chip : DPStripChipUnderMouse());
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

#pragma mark - Settings pane

@interface DPSolidLabel : NSTextField
@end
@implementation DPSolidLabel
- (BOOL)allowsVibrancy { return NO; }
@end

@interface DPSolidImageView : NSImageView
@end
@implementation DPSolidImageView
- (BOOL)allowsVibrancy { return NO; }
@end

static NSView *DPGroup(NSArray<NSView *> *rows) {
    NSStackView *stack = [NSStackView new];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 0;
    [rows enumerateObjectsUsingBlock:^(NSView *row, NSUInteger i, BOOL *_) {
        if (i > 0) {
            NSBox *line = [NSBox new];
            line.boxType = NSBoxSeparator;
            [stack addArrangedSubview:line];
            [line.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-24].active = YES;
        }
        [stack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    }];
    NSBox *box = [NSBox new];
    box.boxType = NSBoxCustom;
    box.borderWidth = 0;
    box.cornerRadius = 10;
    box.fillColor = [NSColor.labelColor colorWithAlphaComponent:0.04];
    box.contentViewMargins = NSZeroSize;
    box.contentView = stack;
    return box;
}

static NSView *DPRow(NSView *leading, NSView *trailing) {
    NSView *row = [NSView new];
    for (NSView *v in @[leading, trailing]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:v];
    }
    [trailing setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [leading.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12],
        [leading.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],
        [leading.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10],
        [trailing.leadingAnchor constraintGreaterThanOrEqualToAnchor:leading.trailingAnchor constant:12],
        [trailing.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12],
        [trailing.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];
    return row;
}

static NSTextField *DPLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    return label;
}

static NSView *DPIconTile(NSString *symbol, NSColor *color) {
    NSView *tile = [NSView new];
    tile.wantsLayer = YES;
    tile.layer.backgroundColor = color.CGColor;
    tile.layer.cornerRadius = 5;
    tile.layer.cornerCurve = kCACornerCurveContinuous;
    NSImageView *glyph = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]];
    glyph.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightSemibold];
    glyph.contentTintColor = NSColor.whiteColor;
    glyph.translatesAutoresizingMaskIntoConstraints = NO;
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    [tile addSubview:glyph];
    [NSLayoutConstraint activateConstraints:@[
        [tile.widthAnchor constraintEqualToConstant:20],
        [tile.heightAnchor constraintEqualToConstant:20],
        [glyph.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [glyph.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor],
    ]];
    return tile;
}

static NSToolbarItemIdentifier const DPSearchItemIdentifier = @"DiaPatchesSearch";

@interface DPFlippedView : NSView
@end
@implementation DPFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface DPPaneView : NSView <NSSearchFieldDelegate>
@property (nonatomic, strong) NSArray<NSSwitch *> *toggles;
@property (nonatomic, strong) NSArray<NSArray *> *sections;  // header, group, rows
@property (nonatomic, strong) NSMapTable<NSView *, NSString *> *searchText;
@property (nonatomic, strong) NSSearchToolbarItem *searchItem;
@property (nonatomic, strong) NSTextField *noResults, *notice;
@property (nonatomic, weak) NSView *squareRow;
@property (nonatomic, weak) NSView *phoneURLRow;
@property (nonatomic, strong) NSTextField *phoneURL;
@property (nonatomic, strong) NSTextField *status;
@property (nonatomic, strong) NSButton *checkButton;
@property (nonatomic, strong) NSButton *relaunchButton;
- (void)updateRows;
@end

@implementation DPPaneView

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    static const struct { DPTweak tweak; __unsafe_unretained NSString *symbol, *title, *detail; } rows[] = {
        {DPEdgeToEdge, @"squareshape.squareshape.dotted", @"Edge-to-edge web content", @"Remove the padding between web pages and the window edge."},
        {DPSquareSidebarCorners, @"square", @"Square corners by the sidebar", @"Let web pages meet the sidebar with straight edges."},
        {DPHideToolbar, @"menubar.rectangle", @"Hide toolbar", @"Remove the bar with the address, navigation buttons and extensions. Experimental."},
        {DPHideSidebarButton, @"sidebar.left", @"Hide sidebar button", @"Hide the sidebar toggle at the top left of the toolbar."},
        {DPHideChatButton, @"bubble.fill", @"Hide Chat button", @"Hide the Chat button at the top right of the toolbar."},
        {DPHideChatsButton, @"doc.plaintext", @"Hide Chats button", @"Hide the Chats button in the tab bar or sidebar."},
        {DPHideRecentTabsButton, @"clock.arrow.circlepath", @"Hide recent tabs button", @"Hide the recent tabs button in the tab bar or sidebar."},
        {DPNestedFolders, @"folder.fill", @"Folders in folders", @"Drag a folder into another folder to nest it. With tabs at the top, a folder inside another drops down its contents. Experimental."},
        {DPFolderDropdowns, @"list.bullet.indent", @"Folder dropdowns in top tabs", @"With tabs at the top, folders stay closed and drop down their contents when you point at or click them, folders inside expanding in place. Off, they open in the tab bar and pointing at them shows nothing."},
        {DPHideTabGlow, @"sparkles", @"Plain active tab", @"Remove the glow and outline around the selected tab in the sidebar."},
        {DPSidebarURLBar, @"link", @"Sidebar URL bar", @"Show the page's address at the top of the sidebar, with back, forward and reload by the window buttons. Pairs with Hide toolbar."},
        {DPCommandBar, @"command", @"Command bar", @"⌘T and ⌘L open an Arc-style bar that finds open tabs, history, bookmarks, Dia's commands and chrome:// pages."},
        {DPExtensionsButton, @"ellipsis", @"Extensions menu button", @"Show a ⋯ button after your pinned extensions that lists all of them. Choose which stay in the toolbar with Pin Extensions…."},
        {DPTidyTabs, @"line.3.horizontal.decrease", @"Tidy tabs", @"Sort or Group the profile's tabs by site from the line above them (point at it, next to Close All) or a tab's menu. Bookmarks and folders stay put."},
        {DPDownloadsAtBottom, @"arrow.down.circle", @"Downloads at the bottom", @"Put the downloads button at the bottom left of the sidebar instead of at the top, and keep it showing even with no downloads."},
        {DPLittleWindow, @"macwindow.on.rectangle", @"Little window for links", @"Links opened from other apps open in a small window without the sidebar, like Little Arc. Open in Window (⌘O) moves the page to a tab in your main window. Experimental."},
        {DPTabMemory, @"memorychip", @"Tab memory", @"Show how much memory each tab uses, in MB, on the right of its row in the sidebar. Tabs sharing a process each count all of it. Experimental."},
        {DPMoveToSpace, @"folder", @"Move folders to any space", @"A folder's Move to Space can also pick the spaces Dia greys out for a folder with subfolders. The folder is made again there, so its tabs reload and may be logged out."},
        {DPNewTabBar, @"plus.magnifyingglass", @"New Tab opens the command bar", @"New Tab in the sidebar opens the bar ⌘T does, with suggestions as you type, instead of Dia's new tab page. Needs Command bar."},
        {DPPlainNewTab, @"rectangle", @"Plain new tab page", @"Dia's new tab page keeps only its address box: no AI suggestions, upsells or template gallery. New tab pages opened after turning it off are back to normal."},
        {DPPeekOnShiftClick, @"eye", @"Peek on Shift-Click", @"Shift-click a link to preview it in a card over the page, like Arc. Click outside, press Escape or ⌘W to close it, ⌘O to open it as a tab, or use the buttons beside it."},
        {DPArcBookmarks, @"bookmark", @"Arc-style bookmarks", @"Double-click a bookmark's name in the sidebar to rename it. Its menu also offers Replace Bookmark URL with Current."},
        {DPKeepWindowsActive, @"macwindow", @"Keep windows active", @"Keep a window's deep shadow, sidebar colour and window buttons after you click into another app. Experimental."},
    };
    NSArray<NSColor *> *tints = @[NSColor.systemBlueColor, NSColor.systemIndigoColor, NSColor.systemGrayColor, NSColor.systemOrangeColor,
                                  NSColor.systemPurpleColor, NSColor.systemTealColor, NSColor.systemPinkColor, NSColor.systemBrownColor,
                                  NSColor.systemCyanColor, NSColor.systemRedColor, NSColor.systemYellowColor, NSColor.systemGreenColor, NSColor.systemMintColor,
                                  NSColor.systemBlueColor, NSColor.systemOrangeColor, NSColor.systemTealColor, NSColor.systemPurpleColor, NSColor.systemIndigoColor];
    _searchText = [NSMapTable strongToStrongObjectsMapTable];
    NSMutableArray<NSView *> *tweakRows = [NSMutableArray new];
    NSMutableArray<NSSwitch *> *toggles = [NSMutableArray new];
    for (size_t i = 0; i < sizeof rows / sizeof *rows; i++) {
        NSStackView *text = [NSStackView stackViewWithViews:@[
            DPLabel(rows[i].title, 13, NSFontWeightRegular, NSColor.labelColor),
            DPLabel(rows[i].detail, 11, NSFontWeightRegular, NSColor.secondaryLabelColor),
        ]];
        text.orientation = NSUserInterfaceLayoutOrientationVertical;
        text.alignment = NSLayoutAttributeLeading;
        text.spacing = 2;
        NSStackView *leading = [NSStackView stackViewWithViews:@[DPIconTile(rows[i].symbol, tints[i % tints.count]), text]];
        leading.spacing = 10;
        leading.alignment = NSLayoutAttributeCenterY;
        NSSwitch *toggle = [NSSwitch new];
        toggle.controlSize = NSControlSizeSmall;
        toggle.state = DPOn[rows[i].tweak];
        toggle.tag = rows[i].tweak;
        toggle.target = self;
        toggle.action = @selector(toggle:);
        [toggles addObject:toggle];
        NSView *row = DPRow(leading, toggle);
        [_searchText setObject:[NSString stringWithFormat:@"%@ %@", rows[i].title, rows[i].detail] forKey:row];
        if (rows[i].tweak == DPSquareSidebarCorners) _squareRow = row;
        [tweakRows addObject:row];
    }
    _toggles = toggles;

    NSPopUpButton *icons = [NSPopUpButton new];
    icons.controlSize = NSControlSizeSmall;
    static const struct { __unsafe_unretained NSString *symbol, *title; } choices[] = {
        {@"", @"Dia default"}, {@"folder.fill", @"Folder"}, {@"folder", @"Folder outline"}, {@"tray.fill", @"Tray"},
        {@"archivebox.fill", @"Archive box"}, {@"square.stack.fill", @"Stack"}, {@"circle.fill", @"Dot"},
    };
    for (size_t i = 0; i < sizeof choices / sizeof *choices; i++) {
        [icons addItemWithTitle:choices[i].title];
        icons.lastItem.representedObject = choices[i].symbol;
        if (choices[i].symbol.length) icons.lastItem.image = [NSImage imageWithSystemSymbolName:choices[i].symbol accessibilityDescription:nil];
        if ([choices[i].symbol isEqualToString:DPFolderSymbol()]) [icons selectItem:icons.lastItem];
    }
    icons.target = self;
    icons.action = @selector(chooseFolderIcon:);
    NSStackView *iconText = [NSStackView stackViewWithViews:@[
        DPLabel(@"Folder icon", 13, NSFontWeightRegular, NSColor.labelColor),
        DPLabel(@"Show the same icon on every folder, in place of Dia's and imported ones.", 11, NSFontWeightRegular, NSColor.secondaryLabelColor),
    ]];
    iconText.orientation = NSUserInterfaceLayoutOrientationVertical;
    iconText.alignment = NSLayoutAttributeLeading;
    iconText.spacing = 2;
    NSStackView *iconLeading = [NSStackView stackViewWithViews:@[DPIconTile(@"folder.fill", NSColor.systemYellowColor), iconText]];
    iconLeading.spacing = 10;
    iconLeading.alignment = NSLayoutAttributeCenterY;
    NSView *iconRow = DPRow(iconLeading, icons);
    [_searchText setObject:@"Folder icon Show the same icon on every folder symbol" forKey:iconRow];
    [tweakRows addObject:iconRow];

    NSPopUpButton *spacing = [NSPopUpButton new];
    spacing.controlSize = NSControlSizeSmall;
    static const struct { double height; __unsafe_unretained NSString *title; } heights[] = {
        {0, @"Dia default"}, {31, @"Comfortable"}, {28, @"Compact"}, {25, @"Dense"},
    };
    double chosenHeight = [DPDefaults doubleForKey:DPRowHeightKey];
    for (size_t i = 0; i < sizeof heights / sizeof *heights; i++) {
        [spacing addItemWithTitle:heights[i].title];
        spacing.lastItem.tag = (NSInteger)heights[i].height;
        if (heights[i].height == chosenHeight) [spacing selectItem:spacing.lastItem];
    }
    spacing.target = self;
    spacing.action = @selector(chooseRowHeight:);
    NSStackView *spacingText = [NSStackView stackViewWithViews:@[
        DPLabel(@"Sidebar spacing", 13, NSFontWeightRegular, NSColor.labelColor),
        DPLabel(@"Space pinned tabs, open tabs and folders in the sidebar closer together.", 11, NSFontWeightRegular, NSColor.secondaryLabelColor),
    ]];
    spacingText.orientation = NSUserInterfaceLayoutOrientationVertical;
    spacingText.alignment = NSLayoutAttributeLeading;
    spacingText.spacing = 2;
    NSStackView *spacingLeading = [NSStackView stackViewWithViews:@[DPIconTile(@"arrow.up.and.down.text.horizontal", NSColor.systemMintColor), spacingText]];
    spacingLeading.spacing = 10;
    spacingLeading.alignment = NSLayoutAttributeCenterY;
    NSView *spacingRow = DPRow(spacingLeading, spacing);
    [_searchText setObject:@"Sidebar spacing row height compact dense tabs folders bookmarks" forKey:spacingRow];
    [tweakRows addObject:spacingRow];

    NSPopUpButton *folderSpacing = [NSPopUpButton new];
    folderSpacing.controlSize = NSControlSizeSmall;
    for (NSString *title in @[@"Dia default", @"Tighter", @"Same as tabs"]) [folderSpacing addItemWithTitle:title];
    [folderSpacing selectItemAtIndex:MIN(2, MAX(0, [DPDefaults integerForKey:DPFolderSpacingKey]))];
    folderSpacing.enabled = DPFolderSpacingSites[0] != NULL;
    folderSpacing.target = self;
    folderSpacing.action = @selector(chooseFolderSpacing:);
    NSStackView *folderSpacingText = [NSStackView stackViewWithViews:@[
        DPLabel(@"Folder spacing", 13, NSFontWeightRegular, NSColor.labelColor),
        DPLabel(@"Remove the extra space folders get above, below and around their contents.", 11, NSFontWeightRegular, NSColor.secondaryLabelColor),
    ]];
    folderSpacingText.orientation = NSUserInterfaceLayoutOrientationVertical;
    folderSpacingText.alignment = NSLayoutAttributeLeading;
    folderSpacingText.spacing = 2;
    NSStackView *folderSpacingLeading = [NSStackView stackViewWithViews:@[DPIconTile(@"folder", NSColor.systemTealColor), folderSpacingText]];
    folderSpacingLeading.spacing = 10;
    folderSpacingLeading.alignment = NSLayoutAttributeCenterY;
    NSView *folderSpacingRow = DPRow(folderSpacingLeading, folderSpacing);
    [_searchText setObject:@"Folder spacing sidebar folders gap padding compact" forKey:folderSpacingRow];
    [tweakRows addObject:folderSpacingRow];

    _status = DPLabel(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _checkButton = [NSButton buttonWithTitle:@"Check for Updates" target:self action:@selector(checkForUpdates:)];
    _relaunchButton = [NSButton buttonWithTitle:@"Relaunch to Update" target:self action:@selector(relaunchToUpdate:)];
    _relaunchButton.bezelColor = NSColor.controlAccentColor;
    _relaunchButton.hidden = YES;
    NSView *updateRow = DPRow(_status, [NSStackView stackViewWithViews:@[_relaunchButton, _checkButton]]);
    NSView *restoreRow = DPRow(DPLabel(@"Restore the original Dia without patches.", 13, NSFontWeightRegular, NSColor.labelColor),
                               [NSButton buttonWithTitle:@"Restore…" target:self action:@selector(restore:)]);
    NSButton *arcButton = [NSButton buttonWithTitle:@"Restore…" target:self action:@selector(restoreArcFolders:)];
    arcButton.enabled = DPNestedFoldersAvailable && DPDependencyContext && [NSFileManager.defaultManager fileExistsAtPath:DPArcSidebarPath()];
    NSStackView *arcText = [NSStackView stackViewWithViews:@[
        DPLabel(@"Restore Arc folders", 13, NSFontWeightRegular, NSColor.labelColor),
        DPLabel(@"Put folders imported from Arc back inside the folders they were in.", 11, NSFontWeightRegular, NSColor.secondaryLabelColor),
    ]];
    arcText.orientation = NSUserInterfaceLayoutOrientationVertical;
    arcText.alignment = NSLayoutAttributeLeading;
    arcText.spacing = 2;
    NSView *arcRow = DPRow(arcText, arcButton);
    [_searchText setObject:@"Restore Arc folders import subfolders nested" forKey:arcRow];

    NSStackView *phoneText = [NSStackView stackViewWithViews:@[
        DPLabel(@"Phone access", 13, NSFontWeightRegular, NSColor.labelColor),
        DPLabel(@"See this Mac's spaces, bookmarks and tabs on your phone, over your network or Tailscale. In Safari, add the page to your Home Screen.", 11, NSFontWeightRegular, NSColor.secondaryLabelColor),
    ]];
    phoneText.orientation = NSUserInterfaceLayoutOrientationVertical;
    phoneText.alignment = NSLayoutAttributeLeading;
    phoneText.spacing = 2;
    NSStackView *phoneLeading = [NSStackView stackViewWithViews:@[DPIconTile(@"iphone", NSColor.systemBlueColor), phoneText]];
    phoneLeading.spacing = 10;
    phoneLeading.alignment = NSLayoutAttributeCenterY;
    NSSwitch *phoneToggle = [NSSwitch new];
    phoneToggle.controlSize = NSControlSizeSmall;
    phoneToggle.state = DPOn[DPPhoneAccess];
    phoneToggle.tag = DPPhoneAccess;
    phoneToggle.target = self;
    phoneToggle.action = @selector(toggle:);
    NSView *phoneRow = DPRow(phoneLeading, phoneToggle);
    _phoneURL = DPLabel(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _phoneURL.selectable = YES;
    _phoneURL.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_phoneURL setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSView *phoneURLRow = DPRow(_phoneURL, [NSStackView stackViewWithViews:@[
        [NSButton buttonWithTitle:@"Copy" target:self action:@selector(copyPhoneURL:)],
        [NSButton buttonWithTitle:@"QR Code" target:self action:@selector(showPhoneQR:)],
    ]]);
    _phoneURLRow = phoneURLRow;
    [_searchText setObject:@"Phone access iPhone mobile web app Home Screen Tailscale bookmarks tabs" forKey:phoneRow];
    [_searchText setObject:@"Phone access address URL QR code copy" forKey:phoneURLRow];
    [_searchText setObject:@"Check for updates version" forKey:updateRow];
    [_searchText setObject:@"Restore the original Dia without patches uninstall" forKey:restoreRow];

    _searchItem = [[NSSearchToolbarItem alloc] initWithItemIdentifier:DPSearchItemIdentifier];
    _searchItem.searchField.delegate = self;
    _noResults = DPLabel(@"No results", 13, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _notice = DPLabel(@"DiaPatches is unofficial and not affiliated with The Browser Company.", 11, NSFontWeightRegular, NSColor.tertiaryLabelColor);
    NSMutableArray<NSView *> *views = [NSMutableArray new];
    NSMutableArray<NSArray *> *sections = [NSMutableArray new];
    NSMutableArray<NSArray *> *groups = [NSMutableArray arrayWithArray:@[@[@"Interface", tweakRows], @[@"Arc", @[arcRow]], @[@"Phone", @[phoneRow, phoneURLRow]], @[@"Updates", @[updateRow, restoreRow]]]];
    if (DPSafeMode) {
        NSView *safeModeRow = DPRow(DPLabel(@"Patches are off because Dia quit unexpectedly twice right after opening.", 13, NSFontWeightRegular, NSColor.labelColor),
                                    [NSButton buttonWithTitle:@"Turn Patches Back On" target:self action:@selector(leaveSafeMode:)]);
        [_searchText setObject:@"Safe mode patches off crashed quit unexpectedly turn back on" forKey:safeModeRow];
        [groups insertObject:@[@"Safe Mode", @[safeModeRow]] atIndex:0];
    }
    for (NSArray *section in groups) {
        NSTextField *header = DPLabel(section[0], 12, NSFontWeightSemibold, NSColor.secondaryLabelColor);
        NSView *group = DPGroup(section[1]);
        [views addObjectsFromArray:@[header, group]];
        [sections addObject:@[header, group, section[1]]];
    }
    [views addObjectsFromArray:@[_noResults, _notice]];
    _sections = sections;

    NSStackView *content = [NSStackView stackViewWithViews:views];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeLeading;
    content.spacing = 8;
    for (NSView *v in content.arrangedSubviews) [v.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;

    // Dia's Settings window doesn't grow, so the pane scrolls below the window's title.
    DPFlippedView *document = [DPFlippedView new];
    NSScrollView *scroll = [NSScrollView new];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.automaticallyAdjustsContentInsets = NO;
    scroll.documentView = document;
    [document addSubview:content];
    [self addSubview:scroll];
    for (NSView *v in @[content, document, scroll]) v.translatesAutoresizingMaskIntoConstraints = NO;
    NSLayoutConstraint *fill = [content.widthAnchor constraintEqualToAnchor:document.widthAnchor constant:-48];
    fill.priority = NSLayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.topAnchor constant:52],
        [scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [document.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [document.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [content.topAnchor constraintEqualToAnchor:document.topAnchor constant:20],
        [content.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-20],
        [content.centerXAnchor constraintEqualToAnchor:document.centerXAnchor],
        [content.widthAnchor constraintLessThanOrEqualToConstant:560],
        fill,
    ]];
    [self updateRows];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer { self.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor; }

// Unhandled events would reach Dia's pane underneath via the responder chain.
- (void)mouseDown:(NSEvent *)event {}
- (void)mouseDragged:(NSEvent *)event {}
- (void)mouseUp:(NSEvent *)event {}
- (void)rightMouseDown:(NSEvent *)event {}
- (void)rightMouseUp:(NSEvent *)event {}
- (void)otherMouseDown:(NSEvent *)event {}
- (void)otherMouseUp:(NSEvent *)event {}
- (void)scrollWheel:(NSEvent *)event {}
- (NSMenu *)menuForEvent:(NSEvent *)event { return nil; }

- (BOOL)matches:(NSView *)row words:(NSArray<NSString *> *)words {
    NSString *text = [self.searchText objectForKey:row];
    for (NSString *word in words) if (word.length && ![text localizedStandardContainsString:word]) return NO;
    return YES;
}

- (void)updateRows {
    NSString *query = self.searchItem.searchField.stringValue;
    NSArray<NSString *> *words = [query componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    BOOL searching = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length > 0;
    for (NSSwitch *toggle in self.toggles) {
        if (toggle.tag == DPHideSidebarButton || toggle.tag == DPHideChatButton) toggle.enabled = !DPOn[DPHideToolbar];
        if (toggle.tag == DPNestedFolders) toggle.enabled = DPNestedFoldersAvailable;
    }
    BOOL anything = NO;
    for (NSArray *section in self.sections) {
        BOOL any = NO;
        for (NSView *row in section[2]) {
            BOOL visible = (row != self.squareRow || DPOn[DPEdgeToEdge]) && (row != self.phoneURLRow || DPOn[DPPhoneAccess])
                        && [self matches:row words:words];
            NSArray<NSView *> *arranged = ((NSStackView *)row.superview).arrangedSubviews;
            NSUInteger index = [arranged indexOfObject:row];
            row.hidden = !visible;
            if (index > 0) arranged[index - 1].hidden = !visible || !any;
            any |= visible;
        }
        for (NSView *view in @[section[0], section[1]]) view.hidden = !any;
        anything |= any;
    }
    self.phoneURL.stringValue = DPOn[DPPhoneAccess] ? DPPhoneURL() ?: @"" : @"";
    self.noResults.hidden = anything;
    self.notice.hidden = searching;
}

- (void)controlTextDidChange:(NSNotification *)notification {
    [self updateRows];
}

- (void)copyPhoneURL:(id)sender {
    NSString *url = DPPhoneURL();
    if (!url) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:url forType:NSPasteboardTypeString];
}

- (void)showPhoneQR:(id)sender {
    NSString *url = DPPhoneURL();
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:[url dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    CIImage *code = [filter.outputImage imageByApplyingTransform:CGAffineTransformMakeScale(8, 8)];
    if (!code) return;
    NSCIImageRep *rep = [NSCIImageRep imageRepWithCIImage:code];
    NSImage *image = [[NSImage alloc] initWithSize:rep.size];
    [image addRepresentation:rep];
    NSImageView *view = [NSImageView imageViewWithImage:image];
    view.frame = NSMakeRect(0, 0, 240, 240);
    view.imageScaling = NSImageScaleProportionallyUpOrDown;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Scan with your phone's camera";
    alert.informativeText = [url stringByAppendingString:@"\n\nOpen it in Safari, then Share → Add to Home Screen."];
    alert.accessoryView = view;
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)toggle:(NSSwitch *)sender {
    DPSetTweak(sender.tag, sender.state == NSControlStateValueOn);
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.allowsImplicitAnimation = YES;
        [self updateRows];
        [self layoutSubtreeIfNeeded];
    }];
}

- (void)restoreArcFolders:(id)sender {
    DPRestoreArcFolders();
}

- (void)chooseFolderSpacing:(NSPopUpButton *)sender {
    DPSetFolderSpacing(sender.indexOfSelectedItem);
}

- (void)chooseRowHeight:(NSPopUpButton *)sender {
    DPSetRowHeight(sender.selectedTag);
}

- (void)chooseFolderIcon:(NSPopUpButton *)sender {
    DPSetFolderSymbol(sender.selectedItem.representedObject);
}

- (void)showStatus:(NSDictionary *)status {
    NSString *running = [NSString stringWithFormat:@"Dia %@ (%@)",
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]];
    id staged = status[@"staged"];
    BOOL ready = [staged isKindOfClass:NSString.class];
    self.status.stringValue = !status ? [running stringByAppendingString:@" · couldn’t check for updates"]
                            : ready   ? [NSString stringWithFormat:@"Dia %@ installs when you quit", staged]
                                      : [running stringByAppendingString:@" · up to date"];
    self.relaunchButton.hidden = !ready;
    self.checkButton.enabled = YES;
}

- (void)checkForUpdates:(NSButton *)sender {
    sender.enabled = NO;
    self.status.stringValue = @"Checking for updates…";
    __weak DPPaneView *weakSelf = self;
    DPCheckForUpdates(^(NSDictionary *status) { [weakSelf showStatus:status]; });
}

- (void)refresh {
    __weak DPPaneView *weakSelf = self;
    DPRunCLI(@[@"status", @"--json"], ^(NSString *output) {
        id status = output ? [NSJSONSerialization JSONObjectWithData:[output dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        [weakSelf showStatus:[status isKindOfClass:NSDictionary.class] ? status : nil];
    });
}

- (void)leaveSafeMode:(id)sender {
    DPLeaveSafeMode();
    DPHandOffAndQuit(@"apply");
}

- (void)relaunchToUpdate:(id)sender {
    DPHandOffAndQuit(@"apply");
}

- (void)restore:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Restore the original Dia?";
    alert.informativeText = @"Dia will relaunch without patches, and its own updater takes over again. Run the installer to patch it again later.";
    [alert addButtonWithTitle:@"Restore and Relaunch"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) DPHandOffAndQuit(@"uninstall");
    }];
}
@end

@interface DPSidebarRow : NSControl
@property (nonatomic) BOOL selected;
@property (nonatomic, strong) NSImageView *icon;
@property (nonatomic, strong) NSTextField *label;
@property (nonatomic) NSRect iconFrame, labelFrame, pillFrame;
@property (nonatomic, strong) NSFont *labelFont;
@property (nonatomic) CGFloat pillRadius;
@end

@implementation DPSidebarRow {
    NSVisualEffectView *_selection;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _selection = [NSVisualEffectView new];
    _selection.material = NSVisualEffectMaterialSelection;
    _selection.state = NSVisualEffectStateFollowsWindowActiveState;
    _selection.wantsLayer = YES;
    _selection.hidden = YES;
    _icon = [DPSolidImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"wand.and.stars" accessibilityDescription:nil]];
    _label = [DPSolidLabel labelWithString:@"Patches"];
    for (NSView *v in @[_selection, _icon, _label]) [self addSubview:v];
    self.accessibilityRole = NSAccessibilityButtonRole;
    self.accessibilityLabel = @"Patches";
    return self;
}

- (BOOL)allowsVibrancy { return NO; }
- (BOOL)isFlipped { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification]) {
        [center removeObserver:self name:name object:nil];
        if (self.window) [center addObserver:self selector:@selector(redraw) name:name object:self.window];
    }
}

- (void)redraw { self.needsDisplay = YES; }

// Dia's sidebar labels get their dark ink from vibrancy, which this row can't get outside Dia's table, so it draws solid text in the plain appearance.
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.label.appearance = [NSAppearance appearanceNamed:[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]];
}

- (void)layout {
    [super layout];
    _selection.frame = self.pillFrame;
    _selection.layer.cornerRadius = self.pillRadius;
    _selection.layer.masksToBounds = YES;
    self.icon.frame = self.iconFrame;
    [self.label sizeToFit];
    NSRect labelFrame = self.labelFrame;
    labelFrame.size.width = MAX(labelFrame.size.width, NSWidth(self.label.frame));
    self.label.frame = labelFrame;
}

- (void)setSelected:(BOOL)selected { _selected = selected; [self redraw]; }

- (void)updateLayer {
    BOOL key = self.window.isKeyWindow, emphasized = self.selected && key;
    _selection.hidden = !self.selected;
    _selection.emphasized = emphasized;
    self.label.textColor = emphasized ? NSColor.alternateSelectedControlTextColor : NSColor.textColor;
    NSFont *font = self.labelFont ?: self.label.font;
    NSFont *face = self.selected ? [NSFont systemFontOfSize:font.pointSize weight:NSFontWeightSemibold] : font;
    if (![self.label.font isEqual:face]) {
        self.label.font = face;
        self.needsLayout = YES;
    }
    self.icon.contentTintColor = emphasized ? NSColor.alternateSelectedControlTextColor : key ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor;
}
@end

static NSString *const DPSettingsControllerClass = @"_TtC11Preferences38SidebarPreferencesWindowViewController";

@interface DPSettings : NSObject
@property (nonatomic, weak) NSWindow *window;
@property (nonatomic, weak) NSView *sidebar, *detail;
@property (nonatomic, weak) NSTableView *table;
@property (nonatomic, weak) NSTextField *title;
@property (nonatomic) NSInteger deselectedIndex;
@property (nonatomic, copy) NSString *originalTitle;
@property (nonatomic, strong) DPSidebarRow *row;
@property (nonatomic, strong) DPPaneView *pane;
@property (nonatomic, strong) id monitor;
@end

@implementation DPSettings

+ (void)attachTo:(NSWindow *)window {
    static NSMapTable<NSWindow *, DPSettings *> *attached;
    attached = attached ?: [NSMapTable weakToStrongObjectsMapTable];
    DPSettings *settings = [attached objectForKey:window];
    if (settings) return [settings reposition];
    settings = [DPSettings new];
    if ([settings attachTo:window]) [attached setObject:settings forKey:window];
}

- (BOOL)attachTo:(NSWindow *)window {
    NSSplitViewController *split = (NSSplitViewController *)window.contentViewController;
    if (split.splitViewItems.count < 2) return NO;
    NSView *sidebar = split.splitViewItems.firstObject.viewController.view;
    NSTableView *table = (NSTableView *)DPFindView(sidebar, ^BOOL(NSView *v) { return [v isKindOfClass:NSTableView.class]; });
    if (table.numberOfRows == 0) return NO;

    self.window = window;
    self.sidebar = sidebar;
    self.detail = split.splitViewItems.lastObject.viewController.view;
    self.table = table;
    self.row = [DPSidebarRow new];
    [sidebar addSubview:self.row];
    [self reposition];
    for (NSView *v in @[table, sidebar]) {
        v.postsFrameChangedNotifications = YES;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reposition) name:NSViewFrameDidChangeNotification object:v];
    }
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(diaSelectionChanged) name:NSTableViewSelectionDidChangeNotification object:table];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keepDiaRowDeselected) name:NSWindowDidBecomeKeyNotification object:window];

    // Dia's sidebar handles clicks above the table view, so the row's clicks are consumed before it selects a row.
    __weak DPSettings *weakSelf = self;
    NSEventMask mask = NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp;
    self.monitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *event) {
        DPSettings *me = weakSelf;
        if (!me || event.window != me.window) return event;
        NSView *hit = [me.window.contentView.superview hitTest:event.locationInWindow];
        if ([hit isDescendantOf:me.row]) {
            if (event.type == NSEventTypeLeftMouseDown) {
                [NSApp activate];
                [me.window makeKeyAndOrderFront:nil];
                [me showPane];
            }
            return nil;
        }
        if (!me.pane.superview || [hit isDescendantOf:me.pane]) return event;
        if ([hit isDescendantOf:me.detail]) return nil;
        BOOL onDiaRow = [me.table rowAtPoint:[me.table convertPoint:event.locationInWindow fromView:nil]] >= 0;
        if (event.type == NSEventTypeLeftMouseDown && onDiaRow) [me hidePane];
        return event;
    }];
    return YES;
}

- (void)dealloc {
    [NSEvent removeMonitor:_monitor];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)reposition {
    NSTableView *table = self.table;
    NSInteger count = table.numberOfRows;
    if (count < 2 || !self.sidebar) return;
    NSRect last = [self.sidebar convertRect:[table rectOfRow:count - 1] fromView:table];
    NSRect previous = [self.sidebar convertRect:[table rectOfRow:count - 2] fromView:table];
    self.row.frame = NSOffsetRect(last, 0, NSMinY(last) - NSMinY(previous));

    NSTableRowView *rowView = [table rowViewAtRow:count - 1 makeIfNecessary:NO];
    NSTableCellView *cell = [table viewAtColumn:0 row:count - 1 makeIfNecessary:NO];
    if (!rowView || !cell) return;
    NSRect (^inRow)(NSView *) = ^NSRect(NSView *v) {
        NSRect r = [rowView convertRect:v.bounds fromView:v];
        if (!rowView.isFlipped) r.origin.y = NSHeight(rowView.bounds) - NSMaxY(r);
        return r;
    };
    self.row.iconFrame = inRow(cell.imageView);
    self.row.labelFrame = inRow(cell.textField);
    NSInteger plain = table.selectedRow == count - 1 ? 0 : count - 1;
    self.row.labelFont = [[table viewAtColumn:0 row:plain makeIfNecessary:NO] textField].font ?: self.row.labelFont;
    self.row.icon.symbolConfiguration = cell.imageView.image.symbolConfiguration;

    NSTableRowView *selected = table.selectedRow >= 0 ? [table rowViewAtRow:table.selectedRow makeIfNecessary:NO] : nil;
    NSVisualEffectView *pill = (NSVisualEffectView *)DPFindView(selected, ^BOOL(NSView *v) { return [v isKindOfClass:NSVisualEffectView.class]; });
    if (selected && pill.superview == selected) {
        NSRect r = pill.frame;
        if (!selected.isFlipped) r.origin.y = NSHeight(selected.bounds) - NSMaxY(r);
        self.row.pillFrame = r;
        self.row.pillRadius = pill.maskImage.capInsets.top ?: pill.layer.cornerRadius;
    } else if (NSIsEmptyRect(self.row.pillFrame)) {
        self.row.pillFrame = NSInsetRect(rowView.bounds, 10, 0);
    }
    if (self.row.pillRadius <= 0) self.row.pillRadius = 6;
    self.row.needsLayout = YES;
}

- (void)showPane {
    if (self.pane.superview || !self.detail) return;
    self.pane = self.pane ?: [[DPPaneView alloc] initWithFrame:self.detail.bounds];
    self.pane.frame = self.detail.bounds;
    self.pane.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.detail addSubview:self.pane positioned:NSWindowAbove relativeTo:nil];
    [self.pane refresh];
    NSToolbar *toolbar = self.window.toolbar;
    if (toolbar && ![toolbar.items containsObject:self.pane.searchItem]) {
        objc_setAssociatedObject(toolbar, &DPSearchItemKey, self.pane.searchItem, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [toolbar insertItemWithItemIdentifier:NSToolbarFlexibleSpaceItemIdentifier atIndex:toolbar.items.count];
        [toolbar insertItemWithItemIdentifier:DPSearchItemIdentifier atIndex:toolbar.items.count];
    }

    NSInteger selected = self.table.selectedRow;
    if (selected < 0) return;
    NSString *name = [[self.table viewAtColumn:0 row:selected makeIfNecessary:NO] textField].stringValue;
    NSView *content = self.window.contentView;
    self.title = (NSTextField *)DPFindView(content.superview, ^BOOL(NSView *v) {
        return [v isKindOfClass:NSTextField.class] && !v.hiddenOrHasHiddenAncestor && ![v isDescendantOf:content]
            && [((NSTextField *)v).stringValue isEqualToString:name];
    });
    self.originalTitle = self.title.stringValue;
    self.title.stringValue = @"Patches";
    self.deselectedIndex = selected;
    [self.table rowViewAtRow:selected makeIfNecessary:NO].selected = NO;
    self.row.selected = YES;
}

- (void)keepDiaRowDeselected {
    if (!self.pane.superview) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.pane.superview) return;
        [self.detail addSubview:self.pane positioned:NSWindowAbove relativeTo:nil];
        [self.table rowViewAtRow:self.deselectedIndex makeIfNecessary:NO].selected = NO;
        self.row.selected = YES;
    });
}

- (void)diaSelectionChanged {
    NSInteger selected = self.table.selectedRow;
    if (self.pane.superview && selected >= 0 && selected != self.deselectedIndex) [self hidePane];
    else [self keepDiaRowDeselected];
}

- (void)hidePane {
    [self.pane removeFromSuperview];
    NSToolbar *toolbar = self.window.toolbar;
    NSUInteger index = [toolbar.items indexOfObject:self.pane.searchItem];
    if (index != NSNotFound) {
        [toolbar removeItemAtIndex:index];
        if (index > 0 && [toolbar.items[index - 1].itemIdentifier isEqualToString:NSToolbarFlexibleSpaceItemIdentifier]) [toolbar removeItemAtIndex:index - 1];
    }
    self.pane.searchItem.searchField.stringValue = @"";
    [self.pane updateRows];
    if ([self.title.stringValue isEqualToString:@"Patches"]) self.title.stringValue = self.originalTitle;
    if (self.table.selectedRow == self.deselectedIndex) [self.table rowViewAtRow:self.deselectedIndex makeIfNecessary:NO].selected = YES;
    self.row.selected = NO;
}
@end

static NSToolbarItem *DPSettings_toolbarItem(id self, SEL _cmd, NSToolbar *toolbar, NSToolbarItemIdentifier identifier, BOOL willInsert) {
    if ([identifier isEqualToString:DPSearchItemIdentifier]) return objc_getAssociatedObject(toolbar, &DPSearchItemKey);
    return DPCallOriginal(NSToolbarItem *(*)(id, SEL, NSToolbar *, NSToolbarItemIdentifier, BOOL), self, _cmd, toolbar, identifier, willInsert);
}

static void DPSettings_viewDidAppear(NSViewController *self, SEL _cmd) {
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
    NSWindow *window = self.view.window;
    dispatch_async(dispatch_get_main_queue(), ^{ if (window) [DPSettings attachTo:window]; });
}

#pragma mark - Bootstrap

__attribute__((constructor)) static void DPInit(void) {
    DPBeginLaunch();
    if (DPSafeMode == 2) return;
    DPDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.diapatches"];
    for (int i = 0; i < DPTweakCount; i++) {
        id value = [DPDefaults objectForKey:DPKeys[i]];
        DPOn[i] = value ? [value boolValue] : DPDefaultsOn[i];
    }
    for (int i = 0; i < DPAnimatedCount; i++) DPProgress[i] = DPOn[i];
    // Dia 1.56 has nested groups of its own behind a feature flag, and its moves refuse them while that's off.
    if (DPOn[DPNestedFolders]) [NSUserDefaults.standardUserDefaults registerDefaults:@{@"transientFeatureFlagOverrides" : @"nested-groups-enabled=true"}];
    DPContainers = [NSHashTable weakObjectsHashTable];
    DPPanes = [NSHashTable weakObjectsHashTable];
    DPBars = [NSHashTable weakObjectsHashTable];
    DPSuppressed = [NSHashTable weakObjectsHashTable];
    DPFolderCells = [NSHashTable weakObjectsHashTable];
    DPTabListLayouts = [NSHashTable weakObjectsHashTable];
    DPSeparators = [NSHashTable weakObjectsHashTable];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    DPHook(NSClassFromString(DPSettingsControllerClass), @selector(viewDidAppear), DPSettings_viewDidAppear);
    DPHook(NSClassFromString(DPSettingsControllerClass), @selector(toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:), DPSettings_toolbarItem);
    [center addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification *_) {
        DPApplyStagedOnQuit();
    }];
    if (DPSafeMode) {
        [center addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *_) {
            DPInstallUpdateMenuItem();
            DPRunCLI(@[@"update"], nil);
        }];
        return;
    }

    DPHook(NSClassFromString(@"ArcBrowserApplication"), @selector(setFeatureEnabled:enabled:), DPApp_setFeatureEnabled);
    DPPeekSetOn(DPOn[DPPeekOnShiftClick]);
    DPPeekInstall();
    DPHook(NSClassFromString(@"NewTabPage.NewTabPageViewController"), @selector(viewDidLayout), DPNewTabPage_viewDidLayout);
    DPHook(NSClassFromString(@"TabUI.TabContentView"), @selector(layout), DPTabContent_layout);
    DPHook(NSClassFromString(@"TabList.TabListCollectionViewLayout"), @selector(prepareLayout), DPTabListLayout_prepare);
    DPHook(NSClassFromString(@"TabList.TabListCollectionViewLayout"), @selector(finalLayoutAttributesForDisappearingItemAtIndexPath:), DPTabListLayout_disappearing);
    DPHook(NSClassFromString(@"TabList.TabListView"), @selector(performDragOperation:), DPTabList_performDrag);
    DPHook(NSClassFromString(@"TabList.TabListView"), @selector(draggingEnded:), DPTabList_draggingEnded);
    DPHook(NSClassFromString(@"TabList.TabListView"), @selector(draggingSession:endedAtPoint:operation:), DPTabList_sessionEnded);
    DPGlowLayers = [NSHashTable weakObjectsHashTable];
    DPRimViews = [NSHashTable weakObjectsHashTable];
    DPNestedFoldersAvailable = DPInstallNestedFolders();
    DPApplyFolderSpacing();

    DPTabsInstall();
    DPHook(NSClassFromString(@"TabList.TabListSeparatorView"), @selector(layout), DPSeparator_layout);
    DPHook(NSWindow.class, @selector(_hasActiveAppearance), DPWindow_hasActiveAppearance);
    DPHook(NSWindow.class, @selector(hasKeyAppearance), DPWindow_hasKeyAppearance);
    DPHook(DPContainerClass(), @selector(setFrame:), DPContainer_setFrame);
    // Full screen squares the page's corners, but a window already the screen's size doesn't lay out on the way in
    // or out. AppKit flips the style mask just after each will notification, so restyle then, and again once done.
    for (NSNotificationName name in @[NSWindowWillEnterFullScreenNotification, NSWindowDidEnterFullScreenNotification,
                                      NSWindowWillExitFullScreenNotification, NSWindowDidExitFullScreenNotification])
        [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *_) {
            dispatch_async(dispatch_get_main_queue(), ^{
                for (NSView *container in DPContainers.allObjects) DPRestyleContainer(container);
            });
        }];
    for (NSString *selector in @[@"layout", @"updateLayer"])
        DPHook(DPContainerClass(), NSSelectorFromString(selector), DPContainer_layoutOrUpdateLayer);
    DPHook(NSClassFromString(@"_TtC5ARCUI10ShadowView"), @selector(layout), DPShadow_layout);
    DPHook(NSClassFromString(@"_TtC11ContentPane15ContentPaneView"), @selector(layout), DPPane_layout);
    for (NSString *bar in @[@"_TtC13NavigationBar17NavigationBarView", @"_TtC10TabSidebar17SidebarHeaderView", @"_TtC10TabSidebar26SidebarContainerFooterView"])
        DPHook(NSClassFromString(bar), @selector(layout), DPBar_layout);
    DPHook(NSClassFromString(@"_TtC10TabSidebar30SidebarContainerViewController"), @selector(viewDidLayout), DPSidebar_viewDidLayout);
    DPHook(NSClassFromString(@"_TtC8TabStrip31TabStripContainerViewController"), @selector(viewWillLayout), DPTabStrip_viewWillLayout);
    DPHook(DPToolbarClass(), @selector(hitTest:), DPToolbar_hitTest);
    DPHook(NSClassFromString(@"_TtC5TabUIP33_903BE4B7F5DFD8B21A7A465D1A9EF8E412TabShapeView"), @selector(layout), DPTabShape_layout);
    DPHook(NSClassFromString(@"_TtC5TabUI12TabGroupView"), @selector(mouseDown:), DPStripGroup_mouseDown);
    DPHook(NSAppleEventManager.class, @selector(setEventHandler:andSelector:forEventClass:andEventID:), DPAEManager_setEventHandler);
    DPHook(NSClassFromString(@"_TtC6Window14PlatformWindow"), @selector(orderWindow:relativeTo:), DPPlatformWindow_orderWindow);
    DPHook(NSClassFromString(@"_TtC6Window14PlatformWindow"), @selector(makeKeyAndOrderFront:), DPPlatformWindow_makeKeyAndOrderFront);
    DPHook(NSClassFromString(DPDialogPanelClass), @selector(orderWindow:relativeTo:), DPDialog_orderWindow);
    DPHook(NSClassFromString(DPDialogPanelClass), @selector(close), DPDialog_close);
    DPHook(NSClassFromString(DPDialogPanelClass), @selector(setAlphaValue:), DPDialog_setAlphaValue);
    DPHook(NSClassFromString(DPDialogPanelClass), @selector(setFrame:display:), DPDialog_setFrameDisplay);
    DPHook(NSClassFromString(DPDialogPanelClass), @selector(setFrame:display:animate:), DPDialog_setFrameDisplayAnimate);
    Class hoverMenuWindow = NSClassFromString(@"_TtC12TabPreviewUIP33_0170D9E3E5C7E28EB9CF80A3A0FFD69325TabHoverMenuPopoverWindow");
    DPHook(hoverMenuWindow, @selector(orderWindow:relativeTo:), DPHoverMenuWindow_orderWindow);
    DPHook(hoverMenuWindow, @selector(orderFrontRegardless), DPHoverMenuWindow_orderFrontRegardless);
    if (hoverMenuWindow) DPWatchFolderHoverMenus(hoverMenuWindow);
    for (NSString *cell in @[@"_TtC5TabUI16TabGroupCellView", @"_TtC5TabUI12TabGroupView"])
        DPHook(NSClassFromString(cell), @selector(layout), DPFolderCell_layout);

    [center addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *_) {
        DPArcBarInstall();  // needs NSApp for its key monitor
        DPConfigureArcBar();
        DPWatchBookmarkDoubleClicks();
        DPWatchSidebarBackgroundClicks();
        DPWatchNewTabClicks();
        DPWatchSeparatorClicks();
        DPHook(object_getClass(NSApp), @selector(sendEvent:), DPApp_sendEvent);  // after DPArcBarInstall's ⌘T and ⌘L
        DPLittleWindows = [NSHashTable weakObjectsHashTable];
        DPWatchLittleWindows();
        DPStartTabMemory();
        NSLog(@"[DiaPatches] little window: app delegate %@ %s application:openURLs:", NSStringFromClass(object_getClass(NSApp.delegate)),
              [NSApp.delegate respondsToSelector:@selector(application:openURLs:)] ? "has" : "lacks");
        DPHook(object_getClass(NSApp.delegate), @selector(application:openURLs:), DPApp_openURLs);
        // Phone access on but its server not set up (the setting came from elsewhere): set it up now.
        if (DPOn[DPPhoneAccess] && ![NSFileManager.defaultManager fileExistsAtPath:DPPhoneAgentPath()]) DPApplyPhoneAccess();
        else if (DPOn[DPPhoneAccess]) DPStartPhoneExport();
        DPInstallUpdateMenuItem();
        DPRunCLI(@[@"update"], nil);
    }];
    [center addObserverForName:NSMenuDidBeginTrackingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        DPAddSubfolderItem(note.object);
        for (NSMenuItem *item in [note.object itemArray]) {  // Dia calls its spaces profiles
            if (!DPOn[DPMoveToSpace] || ![item.title isEqualToString:@"Move to Profile"] || !item.submenu) continue;
            item.title = @"Move to Space";
            DPTakeOverSpaceMoves(note.object, item.submenu);
        }
        DPAddReplaceURLItem(note.object);
        DPAddTidyItems(note.object);
    }];
}
