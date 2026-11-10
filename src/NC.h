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

// ── The clock's colour ───────────────────────────────────────────────────
/// The sky the clock is coloured for at [now]: morning, day, evening, rain,
/// dark, darkrain or night (the FORCE_* switches apply here).
NSString *NCClockPalette(NSDate *now, BOOL raining);
/// The clock's colour for that sky — the time, date and temperature all use
/// it. Matches _clockColor in lib/main.dart.
UIColor *NCClockColor(NSDate *now, BOOL raining);

// ── Icons, pre-rendered ──────────────────────────────────────────────────
/// The panel's Material icons and Hugeicons, rendered to white PNGs by
/// ipad/tool/glyphs_test.dart and tinted here. (The clock's glyphs used to
/// be pre-rendered too, when it was a colour font iOS 10 can't draw; its
/// font now, Chakra Petch, is drawn by UIKit itself.)
@interface NCGlyphs : NSObject
+ (instancetype)shared;
/// A white icon PNG (icon_<name>.png) tinted [color], drawn into [rect].
- (void)drawIcon:(NSString *)name in:(CGRect)rect color:(UIColor *)color;
@end

// ── Weather ──────────────────────────────────────────────────────────────
@interface NCWeather : NSObject
@property (nonatomic) BOOL raining;
/// WMO weather code, and whether the sun is up (Open-Meteo's is_day).
@property (nonatomic) NSInteger code;
@property (nonatomic) BOOL isDay;
/// The Meteocons icon for it ("clear-day", "rain", …) — as weatherIcon in
/// lib/weather.dart; drawn from the bundle's wx_<name>.png.
@property (nonatomic, readonly) NSString *icon;
@property (nonatomic) NSInteger temp, low, high;
/// Open-Meteo, no key. Calls back on the main queue; nil on failure.
+ (void)fetch:(void (^)(NCWeather *w))done;
@end

// ── Holidays ─────────────────────────────────────────────────────────────
/// The Maldives' public holidays, from Google's public calendar (no key;
/// it follows the moon-sighted Islamic dates). Kept in NSUserDefaults so a
/// restart offline still has them.
@interface NCHolidays : NSObject
/// Fetches again if the last fetch is over 12 h old; calls back on the
/// main queue only when new dates came in.
+ (void)refresh:(void (^)(void))done;
/// The line under the date: the next holiday within 15 days ("REPUBLIC
/// DAY  ·  TOMORROW"), nil when there's none.
+ (NSString *)lineFor:(NSDate *)now;
@end

// ── Views ────────────────────────────────────────────────────────────────
/// The clock column's top: the date, the time, the hairline (with the next
/// holiday) and the weather row.
@interface NCFaceView : UIView
@property (nonatomic, strong) NSDate *now;
@property (nonatomic, strong) NCWeather *weather;
/// Standby (the weather icon keeps moving; only night mode stills it).
@property (nonatomic) BOOL standby;
/// Its height, in points (the width is the column's).
+ (CGFloat)height;
@end

/// The picture in the clock column: the user's clips, framed, with soft
/// edges — playing by day, a greyscale still after dark.
@interface NCSkyView : UIView
- (void)updateForNow:(NSDate *)now raining:(BOOL)raining;
/// Standby: the clip stops where it is.
@property (nonatomic) BOOL standby;
/// Its fade down the view: [alphas] at [locations] (0–1), so the clock
/// sits on its faint top and the bill on its dim foot.
- (void)setFadeLocations:(NSArray<NSNumber *> *)locations alphas:(NSArray<NSNumber *> *)alphas;
/// Fade the right edge into the black too (the picture as a column).
@property (nonatomic) BOOL fadeRight;
- (void)pause;
- (void)resume;
@end

@interface NCClockViewController : UIViewController
- (void)appDidBecomeActive;
- (void)appWillResignActive;
@end
