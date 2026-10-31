#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <libkern/OSCacheControl.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach/mach.h>
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, DPTweak) {
    DPEdgeToEdge, DPHideToolbar, DPSquareSidebarCorners, DPAnimatedCount,
    DPHideChatButton = DPAnimatedCount, DPHideSidebarButton, DPHideChatsButton, DPHideRecentTabsButton, DPNestedFolders,
    DPExtensionsButton, DPHideTabGlow, DPTweakCount
};

static NSString *const DPKeys[DPTweakCount] = {@"edgeToEdge", @"hideToolbar", @"squareSidebarCorners", @"hideChatButton", @"hideSidebarButton", @"hideChatsButton", @"hideRecentTabsButton", @"nestedFolders", @"extensionsButton", @"hideTabGlow"};
static const BOOL DPDefaultsOn[DPTweakCount] = {YES, NO, YES, NO, NO, NO, NO, NO, YES, YES};
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

typedef struct { Class cls; SEL sel; IMP imp; } DPOriginal;
static DPOriginal DPOriginals[32];
static int DPOriginalCount;

static void DPHook(Class cls, SEL sel, IMP replacement) {
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!method || method_getImplementation(method) == replacement || DPOriginalCount == 32) return;
    IMP original = method_getImplementation(method);
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method))) method_setImplementation(method, replacement);
    DPOriginals[DPOriginalCount++] = (DPOriginal){cls, sel, original};
}

static IMP DPOriginalIMP(id object, SEL sel) {
    for (Class c = object_getClass(object); c; c = class_getSuperclass(c))
        for (int i = 0; i < DPOriginalCount; i++)
            if (DPOriginals[i].cls == c && DPOriginals[i].sel == sel) return DPOriginals[i].imp;
    abort();
}

#define DPCallOriginal(type, object, sel, ...) ((type)DPOriginalIMP(object, sel))(object, sel, ##__VA_ARGS__)

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

static void DPEnforceButton(NSView *view) {
    NSInteger tweak = DPButtonTweak(view);
    if (tweak < 0) return;
    DPHook(view.class, @selector(setHidden:), (IMP)DPButton_setHidden);
    if (!DPOn[tweak] || view.hidden) return;
    [DPSuppressed addObject:view];
    DPCallOriginal(void (*)(id, SEL, BOOL), view, @selector(setHidden:), YES);
}

static void DPButton_viewDidMoveToWindow(NSView *self, SEL _cmd) {
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
    DPEnforceButton(self);
}

static BOOL DPEnforceButtons(NSView *view) {
    if (DPButtonTweak(view) >= 0) {
        DPHook(view.class, @selector(viewDidMoveToWindow), (IMP)DPButton_viewDidMoveToWindow);
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
- (void)showExtensions:(NSButton *)sender {
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
    CGFloat below = sender.isFlipped ? NSHeight(sender.bounds) + 4 : -4;
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(NSWidth(sender.bounds) - width, below) inView:sender];
}

- (void)runOriginal:(NSMenuItem *)sender {
    NSMenuItem *original = sender.representedObject;
    NSInteger index = [original.menu indexOfItem:original];
    if (index >= 0) [original.menu performActionForItemAtIndex:index];
}
@end

static void DPApplyExtensionsButton(NSView *bar);

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
    CGFloat square = NSMinX(container.frame) > DPWindowPadding + 1 && !DPChatCard(container)
        ? DPProgress[DPSquareSidebarCorners] * DPProgress[DPEdgeToEdge] : 0;
    CACornerMask left = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner, right = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (square == 0 || square == 1) {
        layer.mask = nil;
        layer.maskedCorners = square == 1 ? right : left | right;
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
        mask.sublayers[1].cornerRadius = layer.cornerRadius;
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
            CGPathRef path = DPReshapeCorners((__bridge CGPathRef)objc_getAssociatedObject(shape, &DPOriginalPathKey), base * 1.6, grow, grow * (1 - square));
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
    CGFloat room = DPOn[DPExtensionsButton] ? 30 : 0;
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
    CGFloat shift = NSHeight(bar.frame) * progress, edge = bottom(bar.frame);
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
    0xa9ba6ffc, 0xa90167fa, 0xa9025ff8, 0xa90357f6, 0xa9044ff4, 0xa9057bfd, 0x910143fd, 0xaa0403f7, 0xaa0203f5,
    0xaa0103f3, 0xaa0003f6, 0xf940085b, 0xb400021b, 0xaa0303f8, 0x52800308, 0x9b085768, 0xa940e919, 0xaa1a03e0,
};
// From the payload scan to the refusal: x21 is the target's group ancestry, x23 the dragged item IDs.
static const uint32_t DPValidateCheck[] = {
    0xb7f802f7, 0xf9400ae9, 0x9100c2e8, 0x9100052a, 0xaa0803eb, 0xf100054a, 0x540000c0, 0x3841856c, 0x7100059f, 0x54ffff81,
    0x72001edf, 0x54000100, 0xb400017b, 0x91000529, 0xf1000529, 0x54000100, 0x3841850a, 0x7100055f, 0x54ffff81, 0xd2800000,
};
enum { DPCheckOffset = 112, DPRedirectOffset = 160, DPRejectOffset = 188, DPAcceptOffset = 204 };

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
        "mov x0, x21\n"
        "mov x1, x23\n"
        "bl _DPNestDestination\n"
        "mov x16, x0\n"
        "ldp x29, x30, [sp], #16\n"
        "br x16\n");
}

// TabListCollectionViewLayout only lays out drop targets inside a group when the dragged items hold no group.
// Both checks open with the same scan of the dragged items; the shims skip it while the tweak is on.
static const uint32_t DPLayoutPrologue[] = {
    0x6db63bef, 0x6d0133ed, 0x6d022beb, 0x6d0323e9, 0xa9046ffc, 0xa90567fa, 0xa9065ff8, 0xa90757f6,
    0xa9084ff4, 0xa9097bfd, 0x910243fd, 0xd10943ff, 0xaa1403fb, 0xaa0503f3, 0xaa0403f6, 0xaa0303f5,
};
static const uint32_t DPLayoutScan[] = {0xf940090a, 0x9100c109, 0x91000548, 0xf1000508};  // after cbz x8
static const uint32_t DPLayoutSites[] = {0xff8, 0x14e0};

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
    0x910143fd, 0xd12903ff, 0x910003f3, 0xaa1403fc, 0xaa0103f9, 0xaa0003f7, 0xaa0803f8,
};
static const uint32_t DPLocationSite[] = {0x395ec268, 0x7100091f, 0, 0xf9402a60, 0xaa1c03e1, 0xaa1503e2, 0xaa1703e3, 0xf9403264};
enum { DPLocationOffset = 0x524 };

__attribute__((used, visibility("hidden"))) uintptr_t DPLocationSame, DPLocationCopied, DPLocationAncestor, DPLocationCopyParent;
static BOOL DPSubfolderMenuAvailable;

// x19 is the frame: the shared parent at 0x790 (tag at 0x7b0), its first word also at 0x50 and its tag at 0x60.
// The parent copy only retains a group's ID as a single-payload case, so it's handed tag 2.
__attribute__((naked)) static void DPLocationShim(void) {
    __asm__ volatile(
        "ldrb w8, [x19, #0x7b0]\n"
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

__attribute__((used, visibility("hidden"))) void DPHitTest(void *layout, double x, double y, uint64_t *result) {
    result[0] = result[1] = result[2] = 0;
    Ivar ivar = class_getInstanceVariable(object_getClass((__bridge id)layout), "dropTargets");
    const uint8_t *array = ivar ? *(const uint8_t *const *)((const uint8_t *)layout + ivar_getOffset(ivar)) : NULL;
    if (!array) return;
    // Clicks find the folder under the pointer through here too; only a drag gets the indent-aware pick.
    Ivar dragState = class_getInstanceVariable(object_getClass((__bridge id)layout), "dragDropState");
    BOOL dragging = dragState && ((const uint64_t *)((const uint8_t *)layout + ivar_getOffset(dragState)))[1] != 0;
    const DPDropTarget *t = DPPickDropTarget((const void *)(array + 0x20), *(const int64_t *)(array + 0x10), x, y, dragging);
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

// What Dia passes alongside each DynamicDependency getter; read from the validator's helper, which fetches one.
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
    if ((*(const uint32_t *)(validate + 0x5c) & 0xfc000000) == 0x94000000) {
        const uint8_t *helper = (const uint8_t *)DPBlTarget(validate + 0x5c);
        if (helper > text && helper + 0x48 < text + size) DPDependencyContext = DPAdrpAddTarget(helper + 0x40);
    }
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

// "New Subfolder" in a folder's menu runs the folder's own New Tab in Group (⌥⌘T), then Tabs > New Group with
// Tab (⌃⌘N) on that tab, which the location shim keeps inside the folder. Both are found by shortcut, not title.
static NSMenuItem *DPItemWithShortcut(NSMenu *menu, NSString *key, NSEventModifierFlags modifiers) {
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.keyEquivalent isEqualToString:key] && (item.keyEquivalentModifierMask & NSEventModifierFlagDeviceIndependentFlagsMask) == modifiers)
            return item;
        NSMenuItem *found = item.submenu ? DPItemWithShortcut(item.submenu, key, modifiers) : nil;
        if (found) return found;
    }
    return nil;
}

@interface DPSubfolderAction : NSObject
@end

@implementation DPSubfolderAction
- (void)newSubfolder:(NSMenuItem *)sender {
    NSMenuItem *newTab = sender.representedObject;
    if (![NSApp sendAction:newTab.action to:newTab.target from:newTab]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSMenuItem *group = DPItemWithShortcut(NSApp.mainMenu, @"n", NSEventModifierFlagControl | NSEventModifierFlagCommand);
        if (group) [group.menu performActionForItemAtIndex:[group.menu indexOfItem:group]];
    });
}
@end

static void DPAddSubfolderItem(NSMenu *menu) {
    static DPSubfolderAction *action;
    if (!DPOn[DPNestedFolders] || !DPSubfolderMenuAvailable) return;
    NSMenuItem *newTab = nil;
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.representedObject isKindOfClass:NSMenuItem.class] && item.action == @selector(newSubfolder:)) return;
        if ([item.keyEquivalent isEqualToString:@"t"] && (item.keyEquivalentModifierMask & NSEventModifierFlagDeviceIndependentFlagsMask) == (NSEventModifierFlagOption | NSEventModifierFlagCommand)
            && DPIsKind((id)item.target, @"ARCUI.CallbackMenuItem"))
            newTab = item;
    }
    if (!newTab || !DPItemWithShortcut(NSApp.mainMenu, @"n", NSEventModifierFlagControl | NSEventModifierFlagCommand)) return;
    action = action ?: [DPSubfolderAction new];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"New Subfolder" action:@selector(newSubfolder:) keyEquivalent:@""];
    item.target = action;
    item.representedObject = newTab;
    item.image = [NSImage imageWithSystemSymbolName:@"folder.badge.plus" accessibilityDescription:nil];
    [menu insertItem:item atIndex:[menu indexOfItem:newTab] + 1];
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
    uint8_t tabs[0x340], queries[0x340];  // WindowTabUtilities and TabQueryUtilities: closures of 16 bytes each
} DPTabUtilities;

static void *DPTabListController(NSView *view) {
    if ([NSStringFromClass(view.class) isEqualToString:@"TabList.TabListView"]) {
        if (view.hiddenOrHasHiddenAncestor || NSIsEmptyRect(view.visibleRect)) return NULL;
        Ivar ivar = class_getInstanceVariable(view.class, "viewModel");
        void *model = ivar ? (__bridge void *)object_getIvar(view, ivar) : NULL;
        void *(*loadWeak)(void *) = dlsym(RTLD_DEFAULT, "swift_weakLoadStrong");
        void *controller = model && loadWeak ? loadWeak((uint8_t *)model + DPClassFieldOffset(model, 5)) : NULL;
        if (controller && strcmp(class_getName(object_getClass((__bridge id)controller)), "TabList.TabListController") == 0) return controller;
        if (controller) ((void (*)(void *))dlsym(RTLD_DEFAULT, "swift_release"))(controller);
        return NULL;
    }
    for (NSView *sub in view.subviews) {
        void *found = DPTabListController(sub);
        if (found) return found;
    }
    return NULL;
}

static BOOL DPLoadTabUtilities(DPTabUtilities *utilities) {
    if (!DPDependencyContext) return NO;
    for (NSWindow *window in NSApp.orderedWindows)
        if (!utilities->controller) utilities->controller = DPTabListController(window.contentView.superview ?: window.contentView);
    if (!utilities->controller) return NO;
    for (int i = 0; i < 2; i++) {
        void **getter = (void **)((uint8_t *)utilities->controller + DPClassFieldOffset(utilities->controller, i ? 11 : 15));
        DPSwiftCall(getter[0], getter[1], (uint64_t)utilities->controller, DPDependencyContext, i ? utilities->queries : utilities->tabs);
    }
    return YES;
}

static void DPReleaseTabUtilities(DPTabUtilities *utilities) {
    void (*release)(void *) = dlsym(RTLD_DEFAULT, "swift_release");
    for (int i = 0; i < 0x330 / 16; i++) release(((void **)utilities->tabs)[i * 2 + 1]);
    for (int i = 0; i < 0x320 / 16; i++) release(((void **)utilities->queries)[i * 2 + 1]);
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
    void **root = (void **)(utilities->queries + 33 * 16), **group = (void **)(utilities->queries + 20 * 16);
    uint8_t parent[0x30] = {0};  // TabItemParent .container(.pinned(spaceID)): the space's ID, tag 2
    *(DPString *)parent = *(const DPString *)((const uint8_t *)utilities->controller + DPClassFieldOffset(utilities->controller, 17));
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

// Dia titles a folder whose name repeats with its Arc path, "pxd › pxd old › old".
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

static void DPFolderCell_layout(NSView *self, SEL _cmd) {
    DPCallOriginal(void (*)(id, SEL), self, _cmd);
    DPApplyFolderIcon(self);
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
static const uint32_t DPFolderSpacingOffsets[3] = {0xfd8, 0x1408, 0x1430};  // in the layout function
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

static void DPSetTweak(DPTweak tweak, BOOL on) {
    if (DPOn[tweak] == on) return;
    DPOn[tweak] = on;
    [DPDefaults setBool:on forKey:DPKeys[tweak]];
    if (tweak < DPAnimatedCount) DPAnimate();
    else if (tweak == DPHideTabGlow) DPRefreshTabGlow();
    else if (tweak != DPNestedFolders) {
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
        {DPNestedFolders, @"folder.fill", @"Folders in folders", @"Drag a folder into another folder to nest it. Experimental."},
        {DPHideTabGlow, @"sparkles", @"Plain active tab", @"Remove the glow and outline around the selected tab in the sidebar."},
        {DPExtensionsButton, @"ellipsis", @"Extensions menu button", @"Show a ⋯ button after your pinned extensions that lists all of them. Choose which stay in the toolbar with Pin Extensions…."},
    };
    NSArray<NSColor *> *tints = @[NSColor.systemBlueColor, NSColor.systemIndigoColor, NSColor.systemGrayColor, NSColor.systemOrangeColor,
                                  NSColor.systemPurpleColor, NSColor.systemTealColor, NSColor.systemPinkColor, NSColor.systemBrownColor,
                                  NSColor.systemCyanColor, NSColor.systemGreenColor];
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
        NSStackView *leading = [NSStackView stackViewWithViews:@[DPIconTile(rows[i].symbol, tints[i]), text]];
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
    [_searchText setObject:@"Check for updates version" forKey:updateRow];
    [_searchText setObject:@"Restore the original Dia without patches uninstall" forKey:restoreRow];

    _searchItem = [[NSSearchToolbarItem alloc] initWithItemIdentifier:DPSearchItemIdentifier];
    _searchItem.searchField.delegate = self;
    _noResults = DPLabel(@"No results", 13, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _notice = DPLabel(@"DiaPatches is unofficial and not affiliated with The Browser Company.", 11, NSFontWeightRegular, NSColor.tertiaryLabelColor);
    NSMutableArray<NSView *> *views = [NSMutableArray new];
    NSMutableArray<NSArray *> *sections = [NSMutableArray new];
    for (NSArray *section in @[@[@"Interface", tweakRows], @[@"Arc", @[arcRow]], @[@"Updates", @[updateRow, restoreRow]]]) {
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
            BOOL visible = (row != self.squareRow || DPOn[DPEdgeToEdge]) && [self matches:row words:words];
            NSArray<NSView *> *arranged = ((NSStackView *)row.superview).arrangedSubviews;
            NSUInteger index = [arranged indexOfObject:row];
            row.hidden = !visible;
            if (index > 0) arranged[index - 1].hidden = !visible || !any;
            any |= visible;
        }
        for (NSView *view in @[section[0], section[1]]) view.hidden = !any;
        anything |= any;
    }
    self.noResults.hidden = anything;
    self.notice.hidden = searching;
}

- (void)controlTextDidChange:(NSNotification *)notification {
    [self updateRows];
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
    DPDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.diapatches"];
    for (int i = 0; i < DPTweakCount; i++) {
        id value = [DPDefaults objectForKey:DPKeys[i]];
        DPOn[i] = value ? [value boolValue] : DPDefaultsOn[i];
    }
    for (int i = 0; i < DPAnimatedCount; i++) DPProgress[i] = DPOn[i];
    DPContainers = [NSHashTable weakObjectsHashTable];
    DPPanes = [NSHashTable weakObjectsHashTable];
    DPBars = [NSHashTable weakObjectsHashTable];
    DPSuppressed = [NSHashTable weakObjectsHashTable];
    DPFolderCells = [NSHashTable weakObjectsHashTable];
    DPTabListLayouts = [NSHashTable weakObjectsHashTable];
    DPHook(NSClassFromString(@"TabList.TabListCollectionViewLayout"), @selector(prepareLayout), (IMP)DPTabListLayout_prepare);
    DPGlowLayers = [NSHashTable weakObjectsHashTable];
    DPRimViews = [NSHashTable weakObjectsHashTable];
    DPNestedFoldersAvailable = DPInstallNestedFolders();
    DPApplyFolderSpacing();

    DPHook(DPContainerClass(), @selector(setFrame:), (IMP)DPContainer_setFrame);
    for (NSString *selector in @[@"layout", @"updateLayer"])
        DPHook(DPContainerClass(), NSSelectorFromString(selector), (IMP)DPContainer_layoutOrUpdateLayer);
    DPHook(NSClassFromString(@"_TtC5ARCUI10ShadowView"), @selector(layout), (IMP)DPShadow_layout);
    DPHook(NSClassFromString(@"_TtC11ContentPane15ContentPaneView"), @selector(layout), (IMP)DPPane_layout);
    for (NSString *bar in @[@"_TtC13NavigationBar17NavigationBarView", @"_TtC10TabSidebar17SidebarHeaderView", @"_TtC10TabSidebar26SidebarContainerFooterView"])
        DPHook(NSClassFromString(bar), @selector(layout), (IMP)DPBar_layout);
    DPHook(NSClassFromString(@"_TtC10TabSidebar30SidebarContainerViewController"), @selector(viewDidLayout), (IMP)DPSidebar_viewDidLayout);
    DPHook(NSClassFromString(@"_TtC8TabStrip31TabStripContainerViewController"), @selector(viewWillLayout), (IMP)DPTabStrip_viewWillLayout);
    DPHook(DPToolbarClass(), @selector(hitTest:), (IMP)DPToolbar_hitTest);
    DPHook(NSClassFromString(@"_TtC5TabUIP33_903BE4B7F5DFD8B21A7A465D1A9EF8E412TabShapeView"), @selector(layout), (IMP)DPTabShape_layout);
    for (NSString *cell in @[@"_TtC5TabUI16TabGroupCellView", @"_TtC5TabUI12TabGroupView"])
        DPHook(NSClassFromString(cell), @selector(layout), (IMP)DPFolderCell_layout);
    DPHook(NSClassFromString(DPSettingsControllerClass), @selector(viewDidAppear), (IMP)DPSettings_viewDidAppear);
    DPHook(NSClassFromString(DPSettingsControllerClass), @selector(toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:), (IMP)DPSettings_toolbarItem);

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *_) {
        DPInstallUpdateMenuItem();
        DPRunCLI(@[@"update"], nil);
    }];
    [center addObserverForName:NSMenuDidBeginTrackingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        DPAddSubfolderItem(note.object);
    }];
    [center addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification *_) {
        DPApplyStagedOnQuit();
    }];
}
