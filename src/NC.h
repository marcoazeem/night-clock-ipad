// Night Clock for the old iPad (iOS 10, 32-bit) — the Flutter app can't run
// there, so this is a hand-written UIKit port. Shared declarations.

#import <UIKit/UIKit.h>
#import "Config.h"

// ── Colours (same values as lib/main.dart) ──────────────────────────────
static inline UIColor *NCRGB(uint32_t argb) {
  return [UIColor colorWithRed:((argb >> 16) & 0xFF) / 255.0
                         green:((argb >> 8) & 0xFF) / 255.0
                          blue:(argb & 0xFF) / 255.0
                         alpha:((argb >> 24) & 0xFF) / 255.0];
}

/// Night mode pulls every device colour 80% of the way to this red.
UIColor *NCHue(uint32_t argb, BOOL night);

// ── Times of day ─────────────────────────────────────────────────────────
BOOL NCIsNight(NSDate *t);    // 23:00–06:00: slate clock, red hues
BOOL NCIsDark(NSDate *t);     // 19:00–06:00: night sky
BOOL NCIsMorning(NSDate *t);  // 06:00–11:00
NSInteger NCHour(NSDate *t);

// ── Nabla, pre-rendered ──────────────────────────────────────────────────
/// iOS 10 can't draw Nabla (a COLRv1 colour font), so each character is a
/// PNG rendered by ipad/tool/glyphs_test.dart, drawn here at any size.
@interface NCNabla : NSObject
+ (instancetype)shared;
/// Width of [text] at [fontSize], with [spacing] after every character.
- (CGFloat)widthOf:(NSString *)text size:(CGFloat)fontSize spacing:(CGFloat)spacing night:(BOOL)night;
/// The advance of one character at [fontSize].
- (CGFloat)advanceOf:(unichar)c size:(CGFloat)fontSize night:(BOOL)night;
/// Draws [c] with its advance box's top-left at [origin] (line height = fontSize).
- (void)drawChar:(unichar)c at:(CGPoint)origin size:(CGFloat)fontSize night:(BOOL)night;
- (void)drawText:(NSString *)text at:(CGPoint)origin size:(CGFloat)fontSize spacing:(CGFloat)spacing night:(BOOL)night;
/// A white icon PNG (icon_<name>.png) tinted [color], drawn into [rect].
- (void)drawIcon:(NSString *)name in:(CGRect)rect color:(UIColor *)color;
@end

// ── Weather ──────────────────────────────────────────────────────────────
@interface NCWeather : NSObject
@property (nonatomic) BOOL raining;
@property (nonatomic) NSInteger temp, low, high;
/// Open-Meteo, no key. Calls back on the main queue; nil on failure.
+ (void)fetch:(void (^)(NCWeather *w))done;
@end

// ── Views ────────────────────────────────────────────────────────────────
/// The time, hairline, date and weather, scaled to fill its bounds.
@interface NCFaceView : UIView
@property (nonatomic, strong) NSDate *now;
@property (nonatomic, strong) NCWeather *weather;
@end

/// The background: the user's video clips over a drawn gradient sky.
@interface NCSkyView : UIView
- (void)updateForNow:(NSDate *)now raining:(BOOL)raining;
/// The home page is open: it has its own clip (the forest), whatever the
/// weather. Takes effect at the next updateForNow:.
@property (nonatomic) BOOL home;
- (void)pause;
- (void)resume;
@end

@interface NCClockViewController : UIViewController
- (void)appDidBecomeActive;
- (void)appWillResignActive;
@end
