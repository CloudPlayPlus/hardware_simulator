// 模拟 CoreGraphics 调用持续阻塞，验证回退前已结束旧请求或退出 helper。
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <assert.h>

static dispatch_semaphore_t allowSelection;
static dispatch_semaphore_t selectionReturned;
static BOOL blockSelection = NO;
static BOOL currentModeUsable = NO;

static CGDisplayModeRef testCopyDisplayMode(CGDirectDisplayID displayID) {
  (void)displayID;
  return (CGDisplayModeRef)CFRetain(CFSTR("current mode"));
}
static size_t testModeWidth(CGDisplayModeRef mode) { (void)mode; return 924; }
static size_t testModeHeight(CGDisplayModeRef mode) { (void)mode; return 496; }
static size_t testPixelWidth(CGDisplayModeRef mode) { (void)mode; return 1848; }
static size_t testPixelHeight(CGDisplayModeRef mode) { (void)mode; return 992; }
static bool testModeUsable(CGDisplayModeRef mode) { (void)mode; return currentModeUsable; }
static void testModeRelease(CGDisplayModeRef mode) { CFRelease(mode); }

static CGError testSetDisplayMode(CGDirectDisplayID displayID,
                                  CGDisplayModeRef mode,
                                  CFDictionaryRef options) {
  (void)displayID;
  (void)mode;
  (void)options;
  if (blockSelection) {
    dispatch_semaphore_wait(allowSelection, DISPATCH_TIME_FOREVER);
  }
  dispatch_semaphore_signal(selectionReturned);
  return kCGErrorIllegalArgument;
}

#define CGDisplaySetDisplayMode testSetDisplayMode
#define CGDisplayCopyDisplayMode testCopyDisplayMode
#define CGDisplayModeGetWidth testModeWidth
#define CGDisplayModeGetHeight testModeHeight
#define CGDisplayModeGetPixelWidth testPixelWidth
#define CGDisplayModeGetPixelHeight testPixelHeight
#define CGDisplayModeIsUsableForDesktopGUI testModeUsable
#define CGDisplayModeRelease testModeRelease
#define main virtualDisplayHelperMain
#import "CloudPlayPlusVirtualDisplayHelper.m"
#undef main
#undef CGDisplaySetDisplayMode

int main(void) {
  @autoreleasepool {
    // 尺寸匹配但不可用于桌面的当前模式，不能被快速路径接受。
    assert(!displayHasTargetMode(1, 1848, 992, YES));
    currentModeUsable = YES;
    assert(displayHasTargetMode(1, 1848, 992, YES));
    assert(!displayHasTargetMode(1, 1848, 992, NO));

    allowSelection = dispatch_semaphore_create(0);
    selectionReturned = dispatch_semaphore_create(0);
    // fake setter 不访问 mode 内容；生产函数接管这一份引用。
    CGDisplayModeRef marker = (CGDisplayModeRef)CFRetain(CFSTR("test mode"));
    assert(waitForModeSelection(1, marker, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
    assert(g_should_exit == 0);
    assert(dispatch_semaphore_wait(selectionReturned, DISPATCH_TIME_NOW) == 0);

    blockSelection = YES;
    marker = (CGDisplayModeRef)CFRetain(CFSTR("blocked mode"));
    assert(!waitForModeSelection(1, marker, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC)));
    assert(g_should_exit != 0);
    assert(dispatch_semaphore_wait(selectionReturned, DISPATCH_TIME_NOW) != 0);
    // 测试释放阻塞调用；真实 helper 此时退出，不再应用回退或处理后续命令。
    dispatch_semaphore_signal(allowSelection);
    assert(dispatch_semaphore_wait(selectionReturned, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    puts("PASS: mode selection completes before fallback, or helper exits on timeout");
  }
  return 0;
}
