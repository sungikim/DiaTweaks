// diapatch-mobile: serves Dia's spaces, bookmarks and tabs to a phone, as a page you can add to the Home Screen.
// DiaPatches.dylib writes them to mobile/sidebar.json while Dia runs; this serves that file and the page, and
// nothing else, under a secret path: http://<this Mac>:7480/<token>/. Run by launchd while Phone access is on.
#import <AppKit/AppKit.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include "index_html.h"

static const uint16_t kPort = 7480;
static NSString *gHome;
static NSData *gTouchIcon;

static NSString *inHome(NSString *name) { return [gHome stringByAppendingPathComponent:name]; }

static NSString *token(void) {
    NSString *t = [NSString stringWithContentsOfFile:inHome(@"mobile/token") encoding:NSUTF8StringEncoding error:nil];
    t = [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return t.length >= 16 ? t : nil;
}

// Dia's icon at the size iOS uses for the Home Screen.
static NSData *touchIcon(void) {
    NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:@"/Applications/Dia.app"];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:180 pixelsHigh:180 bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSColor.whiteColor setFill];  // iOS fills transparency with black
    NSRectFill(NSMakeRect(0, 0, 180, 180));
    [icon drawInRect:NSMakeRect(-14, -14, 208, 208)];  // macOS icons have a margin; iOS rounds the corners itself
    [NSGraphicsContext restoreGraphicsState];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

static void respond(int fd, int status, NSString *type, NSData *body) {
    NSString *reason = status == 200 ? @"OK" : status == 302 ? @"Found" : @"Not Found";
    NSMutableString *head = [NSMutableString stringWithFormat:@"HTTP/1.1 %d %@\r\nContent-Length: %lu\r\nConnection: close\r\n"
                             "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n",
                             status, reason, (unsigned long)body.length];
    if (type) [head appendFormat:@"Content-Type: %@\r\n", type];
    [head appendString:@"\r\n"];
    NSMutableData *out = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [out appendData:body ?: [NSData data]];
    for (size_t sent = 0; sent < out.length;) {
        ssize_t n = write(fd, (const char *)out.bytes + sent, out.length - sent);
        if (n <= 0) break;
        sent += n;
    }
}

static void handle(int fd) {
    struct timeval timeout = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    char buffer[8192];
    size_t length = 0;
    while (length < sizeof buffer - 1) {
        ssize_t n = read(fd, buffer + length, sizeof buffer - 1 - length);
        if (n <= 0) break;
        length += n;
        buffer[length] = 0;
        if (strstr(buffer, "\r\n\r\n")) break;
    }
    buffer[length] = 0;
    char method[8], target[2048];
    if (sscanf(buffer, "%7s %2047s", method, target) != 2 || strcmp(method, "GET")) { respond(fd, 404, nil, nil); close(fd); return; }
    NSString *path = [@(target) componentsSeparatedByString:@"?"].firstObject;
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];  // "", token, file...
    NSString *secret = token();
    NSData *given = [parts.count > 1 ? parts[1] : @"" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *expected = [secret dataUsingEncoding:NSUTF8StringEncoding];
    BOOL allowed = secret && given.length == expected.length && timingsafe_bcmp(given.bytes, expected.bytes, given.length) == 0;
    NSString *file = parts.count > 2 ? [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)] componentsJoinedByString:@"/"] : nil;

    if (!allowed) respond(fd, 404, nil, nil);
    else if (!file) {  // "/<token>": the page's links are relative, so it needs the slash
        NSString *head = [NSString stringWithFormat:@"HTTP/1.1 302 Found\r\nLocation: /%@/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", secret];
        write(fd, head.UTF8String, strlen(head.UTF8String));
    } else if (!file.length)
        respond(fd, 200, @"text/html; charset=utf-8", [NSData dataWithBytes:index_html length:index_html_len]);
    else if ([file isEqualToString:@"sidebar.json"]) {
        NSData *data = [NSData dataWithContentsOfFile:inHome(@"mobile/sidebar.json")];
        respond(fd, 200, @"application/json", data ?: [@"{\"spaces\":[]}" dataUsingEncoding:NSUTF8StringEncoding]);
    } else if ([file isEqualToString:@"manifest.webmanifest"]) {
        NSString *manifest = @"{\"name\":\"Dia\",\"short_name\":\"Dia\",\"start_url\":\"./\",\"scope\":\"./\",\"display\":\"browser\","
                              "\"background_color\":\"#000000\",\"icons\":[{\"src\":\"icon.png\",\"sizes\":\"180x180\",\"type\":\"image/png\"}]}";
        respond(fd, 200, @"application/manifest+json", [manifest dataUsingEncoding:NSUTF8StringEncoding]);
    } else if ([file isEqualToString:@"icon.png"])
        respond(fd, 200, @"image/png", gTouchIcon);
    else if ([file hasPrefix:@"site/"] && [file hasSuffix:@".png"]) {
        // Site icons DiaPatches saved, by name: "github.com.png", "localhost_3000.png".
        NSString *name = [file substringFromIndex:5].stringByRemovingPercentEncoding;
        BOOL safe = name.length && [name rangeOfString:@"/"].location == NSNotFound && ![name hasPrefix:@"."];
        NSData *png = safe ? [NSData dataWithContentsOfFile:[inHome(@"site-icons") stringByAppendingPathComponent:name]] : nil;
        respond(fd, png ? 200 : 404, png ? @"image/png" : nil, png);
    } else
        respond(fd, 404, nil, nil);
    close(fd);
}

int main(void) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        gHome = NSProcessInfo.processInfo.environment[@"DIAPATCH_HOME"]
            ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/DiaPatches"];
        gTouchIcon = touchIcon();

        int server = socket(AF_INET, SOCK_STREAM, 0);
        int on = 1;
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
        struct sockaddr_in address = {.sin_len = sizeof address, .sin_family = AF_INET, .sin_port = htons(kPort), .sin_addr.s_addr = htonl(INADDR_ANY)};
        if (bind(server, (struct sockaddr *)&address, sizeof address) || listen(server, 16)) {
            fprintf(stderr, "diapatch-mobile: cannot listen on port %u: %s\n", kPort, strerror(errno));
            return 1;
        }
        dispatch_source_t accepts = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, server, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(accepts, ^{
            int fd = accept(server, NULL, NULL);
            if (fd >= 0) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool { handle(fd); } });
        });
        dispatch_resume(accepts);
        fprintf(stderr, "diapatch-mobile: listening on port %u\n", kPort);
        dispatch_main();
    }
}
