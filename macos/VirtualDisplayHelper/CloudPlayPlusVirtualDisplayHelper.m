#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>

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

extern CGError SLSBeginDisplayConfiguration(CGDisplayConfigRef *);
extern CGError SLSConfigureDisplayEnabled(CGDisplayConfigRef,
                                          CGDirectDisplayID,
                                          bool);
extern CGError SLSConfigureDisplayOrigin(CGDisplayConfigRef,
                                         CGDirectDisplayID,
                                         int32_t,
                                         int32_t);
extern CGError SLSCompleteDisplayConfiguration(CGDisplayConfigRef,
                                               CGConfigureOption,
                                               uint32_t);

static CGVirtualDisplay *g_display = nil;
static CGVirtualDisplayDescriptor *g_descriptor = nil;
static volatile sig_atomic_t g_should_exit = 0;

static void handleSignal(int signo) {
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

static void addMode(NSMutableArray *modes,
                    unsigned int width,
                    unsigned int height,
                    double refreshRate,
                    unsigned int maxWidth,
                    unsigned int maxHeight) {
  if (width == 0 || height == 0 || width > maxWidth || height > maxHeight) {
    return;
  }
  CGVirtualDisplayMode *mode =
      [[CGVirtualDisplayMode alloc] initWithWidth:width
                                           height:height
                                      refreshRate:refreshRate];
  if (mode != nil) {
    [modes addObject:mode];
  }
}

static NSArray *buildModes(int width, int height, int refreshRate) {
  NSMutableArray *modes = [NSMutableArray array];
  const unsigned int maxWidth = (unsigned int)width;
  const unsigned int maxHeight = (unsigned int)height;
  const double hz = (double)refreshRate;

  addMode(modes, maxWidth, maxHeight, hz, maxWidth, maxHeight);
  addMode(modes, maxWidth / 2, maxHeight / 2, hz, maxWidth, maxHeight);

  return modes;
}

static void activateDisplay(CGDirectDisplayID displayID) {
  CGDisplayConfigRef config = NULL;
  if (SLSBeginDisplayConfiguration(&config) != kCGErrorSuccess ||
      config == NULL) {
    return;
  }

  SLSConfigureDisplayEnabled(config, displayID, true);
  CGDirectDisplayID mainDisplay = CGMainDisplayID();
  CGRect mainBounds = CGDisplayBounds(mainDisplay);
  SLSConfigureDisplayOrigin(config,
                            displayID,
                            (int32_t)CGRectGetMaxX(mainBounds),
                            0);
  SLSCompleteDisplayConfiguration(config, kCGConfigureForSession, 0);
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

static void preferNativeScale(CGDirectDisplayID displayID,
                              int width,
                              int height) {
  NSDictionary *options =
      @{(NSString *)kCGDisplayShowDuplicateLowResolutionModes : @YES};
  CFArrayRef modes =
      CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)options);
  if (modes == NULL) return;

  CGDisplayModeRef selected = NULL;
  CFIndex count = CFArrayGetCount(modes);
  for (CFIndex i = 0; i < count; i++) {
    CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
    if ((int)CGDisplayModeGetWidth(mode) == width &&
        (int)CGDisplayModeGetHeight(mode) == height &&
        CGDisplayModeGetPixelWidth(mode) == CGDisplayModeGetWidth(mode) &&
        CGDisplayModeGetPixelHeight(mode) == CGDisplayModeGetHeight(mode)) {
      selected = mode;
      break;
    }
  }
  if (selected != NULL) {
    CGDisplaySetDisplayMode(displayID, selected, NULL);
  }
  CFRelease(modes);
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

    CGVirtualDisplayDescriptor *descriptor =
        [[CGVirtualDisplayDescriptor alloc] init];
    descriptor.name = @"CloudPlayPlus Virtual Display";
    descriptor.vendorID = 0x4350;
    descriptor.productID = 0x5644;
    descriptor.serialNum = (unsigned int)serialNum;
    descriptor.maxPixelsWide = (unsigned int)width;
    descriptor.maxPixelsHigh = (unsigned int)height;
    descriptor.sizeInMillimeters = CGSizeMake(597, 336);
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

    CGVirtualDisplaySettings *settings =
        [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = 1;
    settings.modes = buildModes(width, height, refreshRate);

    fprintf(stderr,
            "[cloudplayplus_vd_helper] creating %dx%d@%d\n",
            width,
            height,
            refreshRate);

    __block CGVirtualDisplay *display = nil;
    __block BOOL settingsApplied = NO;
    dispatch_semaphore_t created = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
      if (display != nil) {
        settingsApplied = [display applySettings:settings];
      }
      dispatch_semaphore_signal(created);
    });

    if (dispatch_semaphore_wait(created,
                                dispatch_time(DISPATCH_TIME_NOW,
                                              8LL * NSEC_PER_SEC)) != 0) {
      fprintf(stderr, "[cloudplayplus_vd_helper] create timeout\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    if (display == nil || !settingsApplied || display.displayID == 0) {
      fprintf(stderr,
              "[cloudplayplus_vd_helper] create failed display=%p applied=%d id=%u\n",
              display,
              settingsApplied,
              display ? display.displayID : 0);
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    g_descriptor = descriptor;
    g_display = display;
    CGDirectDisplayID displayID = display.displayID;
    fprintf(stderr, "[cloudplayplus_vd_helper] created display %u\n", displayID);

    activateDisplay(displayID);
    usleep(500000);
    forceExtended(displayID);
    usleep(250000);
    preferNativeScale(displayID, width, height);

    fprintf(stdout, "%u\n", displayID);
    fflush(stdout);
    close(STDOUT_FILENO);

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
    g_display = nil;
    g_descriptor = nil;
    return 0;
  }
}
