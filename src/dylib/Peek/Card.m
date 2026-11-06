#import "Peek.h"
#import <Carbon/Carbon.h>

static const CGFloat DPPeekShadowRoom = 48;

static NSRect DPPeekCardRect(NSRect area) { return NSInsetRect(area, NSWidth(area) * 0.09, MAX(10, NSHeight(area) * 0.012)); }

@implementation DPPeekCard

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (NSRect)cardFrame {
    NSRect card = DPPeekCardRect(self.bounds), page = self.bounds;
    CGFloat g = self.grown;
    NSRect frame = NSMakeRect(NSMinX(card) + (NSMinX(page) - NSMinX(card)) * g, NSMinY(card) + (NSMinY(page) - NSMinY(card)) * g,
                              NSWidth(card) + (NSWidth(page) - NSWidth(card)) * g, NSHeight(card) + (NSHeight(page) - NSHeight(card)) * g);
    // Keep the settled Chromium surface on physical pixels; fractional placement filters its text.
    return [self backingAlignedRect:frame options:NSAlignAllEdgesNearest];
}

- (void)layout {
    [super layout];
    NSRect card = self.cardFrame;
    self.dim.frame = self.bounds;
    self.card.frame = NSInsetRect(card, -DPPeekShadowRoom, -DPPeekShadowRoom);
    self.clip.frame = self.shade.frame = NSInsetRect(self.card.bounds, DPPeekShadowRoom, DPPeekShadowRoom);
    self.controls.frame = (NSRect){{NSMaxX(card) + 12, NSMinY(card) + 4}, self.controls.frame.size};
    // Outside the sidebar slide's animation. The page redraws at its new size at once, so while the pane moves it covers
    // both the old and new card and is cropped, rather than leaving a blank strip. And the rebuilt hints would fade in.
    NSSize page = self.clip.bounds.size;
    if (self.paneMoves) page = NSMakeSize(MAX(page.width, NSWidth(self.host.frame)), MAX(page.height, NSHeight(self.host.frame)));
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0;
        context.allowsImplicitAnimation = NO;
        self.host.frame = (NSRect){{0, self.clip.isFlipped ? 0 : NSHeight(self.clip.bounds) - page.height}, page};
        DPPeekLayoutHints(self.controls, NSWidth(self.bounds) - NSMaxX(self.controls.frame) - 8);
    }];
}

- (void)followPane {
    NSView *pane = self.pane, *root = self.superview;
    if (!pane.window || !root) return;
    NSRect frame = [root convertRect:pane.bounds fromView:pane];
    if (NSEqualRects(frame, self.frame)) return;
    NSAnimationContext *dia = NSAnimationContext.currentContext;
    if (!dia.timingFunction) return (void)(self.frame = frame);
    self.paneMoves++;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = dia.duration;
        context.timingFunction = dia.timingFunction;
        context.allowsImplicitAnimation = YES;
        self.animator.frame = frame;
        [self layoutSubtreeIfNeeded];
    } completionHandler:^{
        if (!--self.paneMoves) self.needsLayout = YES;
    }];
}

- (void)mouseDown:(NSEvent *)event { [self close:DPPeekClose]; }
- (void)rightMouseDown:(NSEvent *)event {}
- (void)scrollWheel:(NSEvent *)event {}
- (void)control:(NSButton *)sender { [self close:sender.tag]; }

- (BOOL)stopWatching {
    if (self.closing) return NO;
    self.closing = YES;
    if (self.monitor) [NSEvent removeMonitor:self.monitor];
    if (self.paneObserver) [NSNotificationCenter.defaultCenter removeObserver:self.paneObserver];
    self.monitor = self.paneObserver = nil;
    self.controls.alphaValue = 0;
    return YES;
}

- (void)close:(DPPeekExit)exit {
    if (![self stopWatching]) return;
    if (exit == DPPeekClose) [self animateOut:^{ [self finish:exit]; }];
    else if (exit == DPPeekTab) [self animateExpand:^{ [self finish:exit]; }];
    else [self finish:exit];
}

- (void)handOver {
    [self stopWatching];
    [self removeFromSuperview];
    // Off screen before the page detaches, or it flashes blank. A full-size card is swapped for the tab in the same frame.
    if (self.grown < 1) [CATransaction flush];
    [self.page detachFromPaneHostView:self.host];
}

@end

DPPeekCard *DPPeekCardIn(NSWindow *window) {
    return (DPPeekCard *)DPFindView(window.contentView, ^BOOL(NSView *view) {
        return [view isKindOfClass:DPPeekCard.class] && !((DPPeekCard *)view).closing;
    });
}

static NSView *DPPeekPane(NSWindow *window) {
    NSView *pane = nil;
    for (NSView *candidate in DPFindViews(DPDiaContentPane))
        if (candidate.window == window && NSWidth(candidate.bounds) * NSHeight(candidate.bounds) > NSWidth(pane.bounds) * NSHeight(pane.bounds)) pane = candidate;
    return pane;
}

static NSView *DPPeekHolder(NSWindow *window, NSView *pane) {
    for (NSView *view = pane; view && view != window.contentView; view = view.superview)
        if (view.layer.cornerRadius > 0 && view.layer.masksToBounds) return view;
    return window.contentView;
}

static NSView *DPLayerView(void) {
    NSView *view = [NSView new];
    view.wantsLayer = YES;
    return view;
}

// A focused peek page swallows ⌘S, which Dia's tabs pass on to the menu.
static id DPWatchKeys(DPPeekCard *card) {
    __weak DPPeekCard *weak = card;
    return [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        DPPeekCard *peek = weak;
        if (!peek || event.window != peek.window) return event;
        NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask & ~NSEventModifierFlagCapsLock;
        BOOL command = mods == NSEventModifierFlagCommand, editing = [peek.window.firstResponder isKindOfClass:NSText.class];
        if (command && event.keyCode == kVK_ANSI_O) [peek close:DPPeekTab];
        else if ((command && event.keyCode == kVK_ANSI_W) || (!mods && event.keyCode == kVK_Escape && !editing)) [peek close:DPPeekClose];
        else if (!(command && event.keyCode == kVK_ANSI_S && [NSApp.mainMenu performKeyEquivalent:event])) return event;
        return nil;
    }];
}

// Below the page area, so it paints unseen at the card's size.
NSView *DPPeekWarmHost(NSWindow *window, id<DPPeekPage> page) {
    NSView *host = [page createPaneHostView], *pane = DPPeekPane(window);
    if (!host || !pane) return nil;
    NSView *holder = DPPeekHolder(window, pane);
    NSRect area = [holder convertRect:pane.bounds fromView:pane];
    host.frame = NSOffsetRect(DPPeekCardRect((NSRect){NSZeroPoint, area.size}), NSMinX(area), NSMinY(area));
    [holder addSubview:host positioned:NSWindowBelow relativeTo:nil];
    [page attachToPaneHostView:host];
    return host;
}

DPPeekCard *DPPeekShowCard(NSWindow *window, id<DPPeekPage> page, NSView *warmHost, NSRect screenLink) {
    NSView *host = warmHost ?: [page createPaneHostView], *pane = DPPeekPane(window);
    if (!window || !host || DPPeekCardIn(window)) return nil;
    NSView *holder = DPPeekHolder(window, pane);
    DPPeekCard *peek = [[DPPeekCard alloc] initWithFrame:pane ? [holder convertRect:pane.bounds fromView:pane] : holder.bounds];
    peek.autoresizingMask = pane ? NSViewNotSizable : NSViewWidthSizable | NSViewHeightSizable;
    peek.pane = pane;
    peek.page = page;
    peek.host = host;
    peek.dim = DPLayerView();
    peek.dim.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:DPPeekDarkness()].CGColor;
    peek.card = DPLayerView();
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.35];
    shadow.shadowBlurRadius = 24;
    shadow.shadowOffset = NSMakeSize(0, -6);
    peek.shade = DPLayerView();
    peek.shade.shadow = shadow;
    peek.clip = DPLayerView();
    peek.clip.layer.masksToBounds = YES;
    for (NSView *view in @[peek.shade, peek.clip]) {
        view.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
        view.layer.cornerRadius = 10;
        view.layer.cornerCurve = kCACornerCurveContinuous;
    }
    peek.controls = DPPeekControls(peek, @selector(control:));
    [peek.clip addSubview:host];
    [peek.card addSubview:peek.shade];
    [peek.card addSubview:peek.clip];
    for (NSView *view in @[peek.dim, peek.card, peek.controls]) [peek addSubview:view];
    [holder addSubview:peek positioned:NSWindowAbove relativeTo:nil];
    [peek layoutSubtreeIfNeeded];
    if (!warmHost) [page attachToPaneHostView:host];
    [window makeFirstResponder:host];
    if (pane) {
        pane.postsFrameChangedNotifications = YES;
        __weak DPPeekCard *weak = peek;
        peek.paneObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSViewFrameDidChangeNotification object:pane queue:nil
                                                                        usingBlock:^(NSNotification *note) { [weak followPane]; }];
    }
    peek.monitor = DPWatchKeys(peek);
    peek.link = [peek convertRect:[window convertRectFromScreen:screenLink] fromView:nil];
    [peek animateIn];
    return peek;
}
