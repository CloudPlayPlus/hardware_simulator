#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef CPP_LOG_AVAILABLE
#import <cpp_log/cpp_log_apple.h>
#else
#define CPPLOGM_WARN(...) do {} while (0)
#endif

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic, retain) NSArray *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, retain) NSString *name;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) CGPoint whitePoint;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic, copy) void (^terminationHandler)(id, id);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static CGVirtualDisplay *g_display = nil;
static CGVirtualDisplayDescriptor *g_descriptor = nil;
static volatile sig_atomic_t g_should_exit = 0;

static void handleSignal(int signo) {
  (void)signo;
  g_should_exit = 1;
  dispatch_async(dispatch_get_main_queue(), ^{
    CFRunLoopStop(CFRunLoopGetMain());
  });
}

static BOOL parsePositiveInt(const char *text, int *outValue) {
  if (text == NULL || outValue == NULL) return NO;
  char *end = NULL;
  long value = strtol(text, &end, 10);
  if (end == text || *end != '\0' || value <= 0 || value > INT_MAX) {
    return NO;
  }
  *outValue = (int)value;
  return YES;
}

static BOOL parentIsAlive(pid_t parentPID) {
  if (parentPID <= 1) return YES;
  return kill(parentPID, 0) == 0 || errno == EPERM;
}

static CGVirtualDisplaySettings *targetModeSettings(int width,
                                                    int height,
                                                    int refreshRate,
                                                    BOOL useHiDPI) {
  int modeWidth = useHiDPI ? width / 2 : width;
  int modeHeight = useHiDPI ? height / 2 : height;
  CGVirtualDisplayMode *mode =
      [[CGVirtualDisplayMode alloc] initWithWidth:(unsigned int)modeWidth
                                           height:(unsigned int)modeHeight
                                      refreshRate:(double)refreshRate];
  if (mode == nil) return nil;

  CGVirtualDisplaySettings *settings =
      [[CGVirtualDisplaySettings alloc] init];
  settings.hiDPI = useHiDPI ? 1 : 0;
  settings.modes = @[ mode ];
  return settings;
}

static BOOL displayHasTargetMode(CGDirectDisplayID displayID,
                                 int width,
                                 int height,
                                 BOOL useHiDPI) {
  int logicalWidth = useHiDPI ? width / 2 : width;
  int logicalHeight = useHiDPI ? height / 2 : height;
  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
  if (mode == NULL) return NO;
  BOOL matches = (int)CGDisplayModeGetWidth(mode) == logicalWidth &&
                 (int)CGDisplayModeGetHeight(mode) == logicalHeight &&
                 (int)CGDisplayModeGetPixelWidth(mode) == width &&
                 (int)CGDisplayModeGetPixelHeight(mode) == height;
  CGDisplayModeRelease(mode);
  return matches;
}

// 接管 selected 引用；调用返回前不能确认 mode 或开始下一次 applySettings。
static BOOL waitForModeSelection(CGDirectDisplayID displayID,
                                 CGDisplayModeRef selected,
                                 dispatch_time_t deadline) {
  dispatch_semaphore_t completed = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    (void)CGDisplaySetDisplayMode(displayID, selected, NULL);
    CFRelease(selected);
    dispatch_semaphore_signal(completed);
  });
  if (dispatch_semaphore_wait(completed, deadline) == 0) return YES;

  // 无法取消阻塞的 CoreGraphics 调用。退出持有显示器的进程，防止旧请求
  // 在 1× 回退或后续 SET 成功后覆盖 mode；父进程按现有失败路径清理 / 重建。
  g_should_exit = 1;
  CFRunLoopStop(CFRunLoopGetMain());
  return NO;
}

static BOOL selectTargetMode(CGDirectDisplayID displayID,
                             int width,
                             int height,
                             BOOL useHiDPI) {
  if (displayHasTargetMode(displayID, width, height, useHiDPI)) return YES;
  int logicalWidth = useHiDPI ? width / 2 : width;
  int logicalHeight = useHiDPI ? height / 2 : height;
  NSDictionary *options =
      @{(NSString *)kCGDisplayShowDuplicateLowResolutionModes : @YES};
  CGDisplayModeRef selected = NULL;
  for (int attempt = 0; attempt < 20 && selected == NULL; attempt++) {
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(
        displayID, (__bridge CFDictionaryRef)options);
    if (modes != NULL) {
      CFIndex count = CFArrayGetCount(modes);
      for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef mode =
            (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (CGDisplayModeIsUsableForDesktopGUI(mode) &&
            (int)CGDisplayModeGetWidth(mode) == logicalWidth &&
            (int)CGDisplayModeGetHeight(mode) == logicalHeight &&
            (int)CGDisplayModeGetPixelWidth(mode) == width &&
            (int)CGDisplayModeGetPixelHeight(mode) == height) {
          selected = (CGDisplayModeRef)CFRetain(mode);
          break;
        }
      }
      CFRelease(modes);
    }
    if (selected == NULL) usleep(50000);
  }
  if (selected == NULL) return NO;

  NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 2.0;
  if (!waitForModeSelection(displayID, selected,
                           dispatch_time(DISPATCH_TIME_NOW, 2LL * NSEC_PER_SEC))) {
    return NO;
  }
  // 返回值可能为 1001，但 WindowServer 仍会异步完成切换；核验实际 mode。
  while (NSProcessInfo.processInfo.systemUptime < deadline) {
    if (displayHasTargetMode(displayID, width, height, useHiDPI)) return YES;
    usleep(50000);
  }
  return displayHasTargetMode(displayID, width, height, useHiDPI);
}

// 每次请求重新优先尝试 HiDPI；不可用时保持像素尺寸，回退精确 1×。
static BOOL applyTargetMode(CGVirtualDisplay *display,
                            int width,
                            int height,
                            int refreshRate) {
  if (display == nil || g_should_exit) return NO;
  BOOL preferHiDPI = width % 2 == 0 && height % 2 == 0;
  for (int attempt = preferHiDPI ? 0 : 1; attempt < 2; attempt++) {
    BOOL useHiDPI = attempt == 0;
    CGVirtualDisplaySettings *settings =
        targetModeSettings(width, height, refreshRate, useHiDPI);
    if (settings != nil && [display applySettings:settings] &&
        selectTargetMode(display.displayID, width, height, useHiDPI)) {
      return YES;
    }
    if (g_should_exit) return NO;
    if (useHiDPI) {
      CPPLOGM_WARN("VIRTUAL_DISPLAY", @"HiDPI unavailable; trying 1x for %dx%d",
                   width, height);
    }
  }
  return NO;
}

static void handleCommandLine(NSString *line) {
  NSArray<NSString *> *rawParts =
      [line componentsSeparatedByCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
  NSMutableArray<NSString *> *parts = [NSMutableArray array];
  for (NSString *part in rawParts) {
    if (part.length > 0) [parts addObject:part];
  }

  int width = 0;
  int height = 0;
  int refreshRate = 0;
  BOOL valid = parts.count == 4 && [parts[0] isEqualToString:@"SET"] &&
               parsePositiveInt([parts[1] UTF8String], &width) &&
               parsePositiveInt([parts[2] UTF8String], &height) &&
               parsePositiveInt([parts[3] UTF8String], &refreshRate);
  BOOL applied = valid && applyTargetMode(g_display, width, height, refreshRate);
  if (applied) {
    fprintf(stdout, "OK %u\n", g_display.displayID);
  } else {
    fprintf(stdout, "ERR\n");
  }
  fflush(stdout);
}

static void forceExtended(CGDirectDisplayID displayID) {
  CGDisplayConfigRef config = NULL;
  if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess ||
      config == NULL) {
    return;
  }
  CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay);
  CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);

  config = NULL;
  if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess ||
      config == NULL) {
    return;
  }
  CGDirectDisplayID mainDisplay = CGMainDisplayID();
  CGRect mainBounds = CGDisplayBounds(mainDisplay);
  CGConfigureDisplayOrigin(config,
                           displayID,
                           (int32_t)CGRectGetMaxX(mainBounds),
                           0);
  CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc < 5 || NSClassFromString(@"CGVirtualDisplay") == Nil) {
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    int width = 0;
    int height = 0;
    int refreshRate = 0;
    int parentPIDInt = 0;
    int serialNum = 0x43505601;
    if (!parsePositiveInt(argv[1], &width) ||
        !parsePositiveInt(argv[2], &height) ||
        !parsePositiveInt(argv[3], &refreshRate) ||
        !parsePositiveInt(argv[4], &parentPIDInt)) {
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }
    if (argc >= 6 && !parsePositiveInt(argv[5], &serialNum)) {
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    signal(SIGTERM, handleSignal);
    signal(SIGINT, handleSignal);
    signal(SIGHUP, handleSignal);
    signal(SIGPIPE, SIG_IGN);

    CGVirtualDisplayDescriptor *descriptor =
        [[CGVirtualDisplayDescriptor alloc] init];
    descriptor.name = @"CloudPlayPlus Virtual Display";
    descriptor.vendorID = 0x4350;
    // macOS persists the preferred mode by vendor+product and ignores serial.
    // A fresh product identity prevents an old manual 1x choice from
    // overriding the first (HiDPI) mode of this new display instance.
    descriptor.productID = arc4random_uniform(UINT16_MAX - 1) + 1;
    descriptor.serialNum = (unsigned int)serialNum;
    // On macOS 26 the descriptor maximum becomes the preferred HiDPI backing
    // size. Keep it equal to the requested target; a larger catalog maximum
    // would silently start the display at that larger resolution instead.
    descriptor.maxPixelsWide = (unsigned int)width;
    descriptor.maxPixelsHigh = (unsigned int)height;
    // Match the declared physical size to Retina density. A fixed 27-inch
    // descriptor makes 2448x1848 look like a low-DPI panel and macOS prefers
    // its 1x mode even when hiDPI is enabled.
    double targetPPI = (width % 2 == 0 && height % 2 == 0) ? 220.0 : 110.0;
    descriptor.sizeInMillimeters =
        CGSizeMake(width * 25.4 / targetPPI, height * 25.4 / targetPPI);
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
    descriptor.redPrimary = CGPointMake(0.64, 0.33);
    descriptor.greenPrimary = CGPointMake(0.30, 0.60);
    descriptor.bluePrimary = CGPointMake(0.15, 0.06);
    [descriptor setDispatchQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,
                                                           0)];
    descriptor.terminationHandler = ^(__unused id sender, __unused id reason) {
      g_should_exit = 1;
      dispatch_async(dispatch_get_main_queue(), ^{
        CFRunLoopStop(CFRunLoopGetMain());
      });
    };

    CGVirtualDisplaySettings *initialSettings =
        targetModeSettings(width, height, refreshRate,
                           width % 2 == 0 && height % 2 == 0);
    __block CGVirtualDisplay *display = nil;
    __block BOOL settingsApplied = NO;
    dispatch_semaphore_t created = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
      if (display != nil) {
        settingsApplied = initialSettings != nil && [display applySettings:initialSettings];
        if (!settingsApplied) {
          CGVirtualDisplaySettings *fallback =
              targetModeSettings(width, height, refreshRate, NO);
          settingsApplied = fallback != nil && [display applySettings:fallback];
        }
      }
      dispatch_semaphore_signal(created);
    });

    if (dispatch_semaphore_wait(created,
                                dispatch_time(DISPATCH_TIME_NOW,
                                              8LL * NSEC_PER_SEC)) != 0) {
      CPPLOGM_WARN("VIRTUAL_DISPLAY", @"Create timed out");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    if (display == nil || !settingsApplied || display.displayID == 0) {
      CPPLOGM_WARN("VIRTUAL_DISPLAY", @"Create failed (applied=%d)", settingsApplied);
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    g_descriptor = descriptor;
    g_display = display;
    CGDirectDisplayID displayID = display.displayID;

    // 初始 ID 仅表示对象已分配。主进程等待发布后发送首次 SET，
    // 由命令处理统一选择缩放并核验；避免后台选择与后续 SET 并发修改 mode。
    fprintf(stdout, "%u\n", displayID);
    fflush(stdout);

    dispatch_async(
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
          if (CGDisplayIsInMirrorSet(displayID)) forceExtended(displayID);
        });

    NSFileHandle *inputHandle = [NSFileHandle fileHandleWithStandardInput];
    __block NSMutableData *inputBuffer = [NSMutableData data];
    inputHandle.readabilityHandler = ^(NSFileHandle *handle) {
      NSData *chunk = handle.availableData;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (chunk.length == 0) {
          g_should_exit = 1;
          CFRunLoopStop(CFRunLoopGetMain());
          return;
        }
        [inputBuffer appendData:chunk];
        while (!g_should_exit) {
          const void *bytes = inputBuffer.bytes;
          const void *newline = memchr(bytes, '\n', inputBuffer.length);
          if (newline == NULL) break;
          NSUInteger lineLength =
              (const uint8_t *)newline - (const uint8_t *)bytes;
          NSData *lineData = [inputBuffer subdataWithRange:NSMakeRange(0, lineLength)];
          [inputBuffer replaceBytesInRange:NSMakeRange(0, lineLength + 1)
                                 withBytes:NULL
                                    length:0];
          NSString *line = [[NSString alloc] initWithData:lineData
                                                 encoding:NSUTF8StringEncoding];
          if (line != nil) handleCommandLine(line);
        }
      });
    };

    pid_t parentPID = (pid_t)parentPIDInt;
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC,
                              NSEC_PER_MSEC * 100);
    dispatch_source_set_event_handler(timer, ^{
      if (g_should_exit || !parentIsAlive(parentPID)) {
        CFRunLoopStop(CFRunLoopGetMain());
      }
    });
    dispatch_resume(timer);

    while (!g_should_exit) {
      CFRunLoopRun();
      break;
    }

    dispatch_source_cancel(timer);
    inputHandle.readabilityHandler = nil;
    g_display = nil;
    g_descriptor = nil;
    return 0;
  }
}
