#import "NC.h"
#import "Energy.h"
#import "Panel.h"
#import "Lottie.h"

// Proportions from lib/main.dart, all in units of the digit size d — the
// face's layout unit: the time's ink stands kInkBottom × d tall, and the
// hairline, date and weather are sized from d.
/// The digits' ink ends here, down from the face's top; the hairline
/// follows from it.
#define kInkBottom 0.79
/// Chakra Petch's figures stand this many em on the baseline, flat (measured
/// from the phone's render of the same TTF), so the time's font is a little
/// bigger than d.
#define kCapHeight 0.703
#define kFontScale (kInkBottom / kCapHeight)
/// The slots the time's glyphs are centred in, in em: Chakra Petch's figures
/// are proportional (a "1" is 0.382, a "0" 0.652), so each gets a slot the
/// width of the widest, and the time's width never changes with the minutes
/// — the same slots as the phone's.
#define kDigitAdvance 0.652
#define kColonAdvance 0.232
#define kTimeWidth (kFontScale * (4 * kDigitAdvance + kColonAdvance))
/// Where Chakra Petch's baseline sits down a 1 em line box on the phone
/// (TextStyle height 1.0). UIKit's line box is taller (ascender +
/// descender), so every line here is placed by its baseline to land where
/// the phone's does.
#define kBaseline 0.7631
static const CGFloat kGap = 0.07;
static const CGFloat kDateSize = 0.2, kDateSpacing = 0.012;
/// The next holiday's line under the date (iPad only — the phone's face is
/// full; the user asked, 10 Nov 2026).
static const CGFloat kHolidaySize = 0.11, kHolidayGap = 0.06;
static const CGFloat kIcon = 0.46;
static const CGFloat kTempSize = 0.42, kTempGap = 0.12;

/// The face's font — the time, date and temperature are all Chakra Petch
/// Bold, from the bundle (Info.plist's UIAppFonts), else the system's bold.
static UIFont *clockFont(CGFloat size) {
  return [UIFont fontWithName:@"ChakraPetch-Bold" size:size] ?: [UIFont boldSystemFontOfSize:size];
}

static NSDictionary *attrs(UIFont *font, UIColor *color, CGFloat kern) {
  return @{NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSKernAttributeName: @(kern)};
}

/// [text]'s width in em of the face's font, with [kern] em after each character.
static CGFloat emWidth(NSString *text, CGFloat kern) {
  const CGFloat probe = 100;
  return [text sizeWithAttributes:attrs(clockFont(probe), UIColor.whiteColor, kern * probe)].width / probe;
}

static NSString *kwText(double w) {
  return w >= 1000 ? [NSString stringWithFormat:@"%.1f kW", w / 1000] : [NSString stringWithFormat:@"%ld W", lround(w)];
}

static NSString *mvrText(double v) {
  NSNumberFormatter *f = [NSNumberFormatter new];
  f.numberStyle = NSNumberFormatterDecimalStyle;
  f.maximumFractionDigits = 0;
  f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
  return [f stringFromNumber:@(lround(v))];
}

/// The energy rows under the weather (the user asked, 3 Nov 2026): the
/// room on screen's draw — the house's on the home page — and this bill's
/// estimate; the bills' graph follows.
static NSArray<NSArray<NSString *> *> *energyRows(NCEnergyTracker *e, NSArray<NSString *> *names, NSInteger room) {
  // Not on the home page: its own energy card is right there (the user
  // asked to drop the face's copy there, 3 Nov 2026).
  if (!e || e.totalWatts < 0 || room < 0 || room >= (NSInteger)e.roomWatts.count || room >= (NSInteger)names.count)
    return @[];
  NSMutableArray *rows = [NSMutableArray array];
  [rows addObject:@[names[room], kwText([e.roomWatts[room] doubleValue])]];
  if (e.bills.count) [rows addObject:@[@"This bill", [@"≈ MVR " stringByAppendingString:mvrText([e projectedMvr])]]];
  return rows;
}

static const CGFloat kEnergyRow = 21, kEnergyGap = 14, kGraphGap = 8, kGraphUnit = 18, kGraphU = 7;
static const CGFloat kCardPad = 18 * 1.1;

/// The energy block's card — the home page's energy card, cut down to the
/// room on screen (the user asked for the same frosted card, 3 Nov 2026):
/// real frosted glass (a dark blur view) under a view that draws the
/// card's wash and border, the rows and the graph. A UIView's own drawing
/// sits under its subviews, which is why the ink is a view of its own.
@interface NCFaceEnergyCard : UIView
@property (nonatomic, weak) NCEnergyTracker *energy;
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *rows;
@property (nonatomic) BOOL night, standby;
/// Its height for [rows] (and the graph when there are bills).
- (CGFloat)height;
@end

@interface NCFaceEnergyInk : UIView
@end

@implementation NCFaceEnergyCard {
  UIVisualEffectView *_frost;
  NCFaceEnergyInk *_ink;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.userInteractionEnabled = NO;
    _frost = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    _frost.alpha = 0.85;
    _frost.clipsToBounds = YES;
    _frost.layer.cornerRadius = kGraphUnit * 1.8;
    [self addSubview:_frost];
    _ink = [NCFaceEnergyInk new];
    _ink.opaque = NO;
    _ink.backgroundColor = UIColor.clearColor;
    _ink.contentMode = UIViewContentModeRedraw;
    [self addSubview:_ink];
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  _frost.frame = _ink.frame = self.bounds;
}

- (CGFloat)height {
  return 2 * kCardPad + self.rows.count * kEnergyRow + (self.energy.bills.count ? kGraphGap + kGraphUnit * kGraphU : 0);
}

- (void)setRows:(NSArray<NSArray<NSString *> *> *)rows { _rows = [rows copy]; [_ink setNeedsDisplay]; }
- (void)setNight:(BOOL)night { _night = night; [_ink setNeedsDisplay]; }
- (void)setStandby:(BOOL)standby {
  if (standby == _standby) return;
  _standby = standby;
  [UIView animateWithDuration:1.5 animations:^{ self->_frost.alpha = standby ? 0 : 0.85; }];
  [_ink setNeedsDisplay];
}

@end

@implementation NCFaceEnergyInk

- (void)drawRect:(CGRect)rect {
  NCFaceEnergyCard *card = (NCFaceEnergyCard *)self.superview;
  CGFloat u = kGraphUnit;
  UIColor *amber = NCHue(0xFFFFB547, card.night), *white = NCRGB(0xFFE8E8E8);
  NCDrawCard(self.bounds, amber, NO, NO, u, card.standby);
  // Label left, figure right, then the bills' graph — as on the home card.
  CGFloat bx = kCardPad, bw = self.bounds.size.width - 2 * kCardPad, by = kCardPad;
  UIFont *f = [UIFont fontWithName:@"Inter-Medium" size:15] ?: [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
  NSArray<NSArray<NSString *> *> *rows = card.rows;
  for (NSUInteger i = 0; i < rows.count; i++) {
    CGFloat yy = by + i * kEnergyRow;
    [rows[i][0] drawAtPoint:CGPointMake(bx, yy) withAttributes:attrs(f, [white colorWithAlphaComponent:0.55], 0)];
    NSDictionary *va = attrs(f, white, 0);
    CGFloat vw = [rows[i][1] sizeWithAttributes:va].width;
    [rows[i][1] drawAtPoint:CGPointMake(bx + bw - vw, yy) withAttributes:va];
  }
  if (card.energy.bills.count) {
    CGRect gr = CGRectMake(bx, by + rows.count * kEnergyRow + kGraphGap, bw, u * kGraphU);
    NCDrawEnergyGraph(card.energy, gr, u, amber, -1);
  }
}

@end

/// Draws one line of [text] with its baseline at [baseline].
static void drawOnBaseline(NSString *text, NSDictionary *a, CGFloat x, CGFloat baseline) {
  UIFont *f = a[NSFontAttributeName];
  [text drawAtPoint:CGPointMake(x, baseline - f.ascender) withAttributes:a];
}

/// A weather icon from the bundle (wx_<name>.png, rendered by
/// tool/glyphs_test.dart), multiplied towards the dashboard's red in night
/// mode — made once per icon and mode.
static UIImage *weatherImage(NSString *name, BOOL night) {
  static NSMutableDictionary<NSString *, UIImage *> *cache;
  if (!cache) cache = [NSMutableDictionary dictionary];
  NSString *key = [NSString stringWithFormat:@"%@/%d", name, night];
  if (cache[key]) return cache[key];
  UIImage *img = [UIImage imageNamed:[@"wx_" stringByAppendingString:name]];
  if (!img || !night) return cache[key] = img;
  UIGraphicsBeginImageContextWithOptions(img.size, NO, img.scale);
  CGRect r = {CGPointZero, img.size};
  [img drawInRect:r];
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  CGContextSetBlendMode(ctx, kCGBlendModeMultiply);
  [NCHue(0xFFE8E8E8, YES) setFill];
  CGContextFillRect(ctx, r);
  [img drawInRect:r blendMode:kCGBlendModeDestinationIn alpha:1];
  UIImage *tinted = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return cache[key] = tinted;
}

@implementation NCFaceView {
  /// The weather icon, animated (Meteocons' Lottie file) outside night
  /// mode; hidden and stopped in it, where a still red-tinted copy is drawn
  /// instead — the user asked for the animation to stop with the red tint.
  LOTAnimationView *_anim;
  NSString *_animName;
  /// The energy card under the weather (made when there's something to show).
  NCFaceEnergyCard *_card;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    self.userInteractionEnabled = NO;
  }
  return self;
}

/// Plays [name]'s animation over [box]; NO if the bundle hasn't got it.
- (BOOL)showAnimation:(NSString *)name in:(CGRect)box {
  if (![name isEqualToString:_animName]) {
    [_anim removeFromSuperview];
    _anim = nil;
    _animName = name;
    if (![[NSBundle mainBundle] pathForResource:name ofType:@"json"]) return NO;
    _anim = [LOTAnimationView animationNamed:name];
    _anim.contentMode = UIViewContentModeScaleAspectFit;
    _anim.loopAnimation = YES;
    _anim.userInteractionEnabled = NO;
    [self addSubview:_anim];
  }
  if (!_anim) return NO;
  if (!CGRectEqualToRect(_anim.frame, box)) _anim.frame = box;
  if (_anim.hidden || !_anim.isAnimationPlaying) {
    _anim.hidden = NO;
    [_anim play];
  }
  return YES;
}

- (void)hideAnimation {
  if (!_anim || _anim.hidden) return;
  [_anim pause];
  _anim.hidden = YES;
}

- (void)setNow:(NSDate *)now { _now = now; [self setNeedsDisplay]; }
- (void)setWeather:(NCWeather *)weather { _weather = weather; [self setNeedsDisplay]; }
- (void)setStandby:(BOOL)standby {
  _standby = standby;
  _card.standby = standby;
  [self setNeedsDisplay];
}

- (NSString *)dateText {
  NSDateFormatter *f = [NSDateFormatter new];
  f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  f.dateFormat = @"EEE'  ·  'MMM d";
  return [[f stringFromDate:self.now] uppercaseString];
}

/// The date's font size: shrunk if it would run wider than 0.85 of the time.
- (CGFloat)dateScaleFor:(NSString *)date {
  CGFloat w = kDateSize * emWidth(date, kDateSpacing / kDateSize);
  return MIN(1.0, kTimeWidth * 0.85 / w);
}

- (CGFloat)faceHeight:(CGFloat)dateScale holiday:(CGFloat)holidayScale {
  return kInkBottom + kGap + 0.0045 + kGap + kDateSize * dateScale +
      (holidayScale > 0 ? kHolidayGap + kHolidaySize * holidayScale : 0);
}

/// The holiday line's size: shrunk if it would run wider than the time.
- (CGFloat)holidayScaleFor:(NSString *)text {
  if (!text.length) return 0;
  CGFloat w = kHolidaySize * emWidth(text, kDateSpacing / kDateSize);
  return MIN(1.0, kTimeWidth * 0.95 / w);
}

- (CGFloat)cardHeight {
  return kIcon;
}

- (void)drawRect:(CGRect)rect {
  if (!self.now) return;
  BOOL night = NCIsNight(self.now);
  UIColor *color = NCClockColor(self.now, self.weather.raining);
  NSString *date = [self dateText];
  CGFloat dateScale = [self dateScaleFor:date];
  NSString *holiday = [NCHolidays lineFor:self.now];
  CGFloat holidayScale = [self holidayScaleFor:holiday];
  CGFloat faceH = [self faceHeight:dateScale holiday:holidayScale];
  BOOL hasCard = self.weather != nil;
  NSString *temp = hasCard ? [NSString stringWithFormat:@"%ld°C", (long)self.weather.temp] : @"";
  // The weather: the icon, a gap, then the temperature.
  CGFloat cardW = hasCard ? kIcon + kTempGap + kTempSize * emWidth(temp, 0) : 0;

  // Natural size at d = 1, two ways: the weather beside the clock or under
  // it. Whichever lets the digits grow bigger wins.
  CGFloat rowW = kTimeWidth + (hasCard ? 0.2 + cardW : 0);
  CGFloat rowH = MAX(faceH, hasCard ? self.cardHeight : 0);
  CGFloat colW = MAX(kTimeWidth, cardW);
  CGFloat colH = faceH + (hasCard ? 2 * kGap + self.cardHeight : 0);
  // The energy rows and graph take a fixed strip at the foot; the face
  // fits above.
  NSArray<NSArray<NSString *> *> *rows = energyRows(self.energy, self.roomNames, self.room);
  if (rows.count && !_card) {
    _card = [NCFaceEnergyCard new];
    _card.energy = self.energy;
    [self addSubview:_card];
  }
  _card.hidden = !rows.count;
  _card.rows = rows;
  _card.night = night;
  _card.standby = self.standby;
  CGFloat blockH = rows.count ? kEnergyGap + [_card height] : 0;
  CGFloat W = self.bounds.size.width, H = self.bounds.size.height - blockH;
  CGFloat dRow = MIN(W / rowW, H / rowH), dCol = MIN(W / colW, H / colH);
  BOOL row = dRow >= dCol;
  CGFloat d = row ? dRow : dCol;
  CGFloat totalW = (row ? rowW : colW) * d, totalH = (row ? rowH : colH) * d;
  CGFloat x0 = (W - totalW) / 2, y0 = (H - totalH) / 2;

  // The face column: its own top-left.
  CGFloat fx = row ? x0 : x0 + (totalW - kTimeWidth * d) / 2;
  CGFloat fy = row ? y0 + (totalH - faceH * d) / 2 : y0;

  // Time: HH:MM, every glyph centred in a fixed slot, on a baseline at the
  // foot of the ink's box.
  NSDateFormatter *tf = [NSDateFormatter new];
  tf.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  tf.dateFormat = @"HH:mm";
  NSString *time = [tf stringFromDate:self.now];
  UIFont *font = clockFont(kFontScale * d);
  NSDictionary *ta = attrs(font, color, 0);
  CGFloat baseline = fy + kInkBottom * d, x = fx;
  for (NSUInteger i = 0; i < time.length; i++) {
    NSString *ch = [time substringWithRange:NSMakeRange(i, 1)];
    CGFloat slot = ([ch isEqualToString:@":"] ? kColonAdvance : kDigitAdvance) * font.pointSize;
    CGFloat adv = [ch sizeWithAttributes:ta].width;
    drawOnBaseline(ch, ta, x + (slot - adv) / 2, baseline);
    x += slot;
  }

  // Hairline: fades in and out, 0.61 of the time's width.
  CGFloat y = fy + d * (kInkBottom + kGap);
  CGFloat lineW = kTimeWidth * 0.61 * d, lineH = MAX(1.5, d * 0.0045);
  CGRect line = CGRectMake(fx + (kTimeWidth * d - lineW) / 2, y, lineW, lineH);
  UIColor *tc = night ? NCRGB(0xFFFF8A75) : NCRGB(0xFFE8E8E8);
  CGFloat r, g, b, a;
  [tc getRed:&r green:&g blue:&b alpha:&a];
  CGFloat comps[] = {r, g, b, 0, r, g, b, 0.55, r, g, b, 0};
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, NULL, 3);
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  CGContextSaveGState(ctx);
  CGContextClipToRect(ctx, line);
  CGContextDrawLinearGradient(ctx, grad, CGPointMake(CGRectGetMinX(line), 0),
                              CGPointMake(CGRectGetMaxX(line), 0), 0);
  CGContextRestoreGState(ctx);
  CGGradientRelease(grad);
  CGColorSpaceRelease(space);

  // Date: "FRI  ·  OCT 23", centred, the clock's font and colour.
  y += lineH + kGap * d;
  CGFloat ds = kDateSize * dateScale * d;
  NSDictionary *da = attrs(clockFont(ds), color, kDateSpacing * dateScale * d);
  CGFloat dw = [date sizeWithAttributes:da].width;
  drawOnBaseline(date, da, fx + (kTimeWidth * d - dw) / 2, y + kBaseline * ds);

  // The next holiday within 15 days, smaller and softer, under the date.
  if (holidayScale > 0) {
    y += ds + kHolidayGap * d;
    CGFloat hs = kHolidaySize * holidayScale * d;
    NSDictionary *ha = attrs(clockFont(hs), NCRGB(0xFFFF4A3D), kDateSpacing / kDateSize * hs);
    CGFloat hw = [holiday sizeWithAttributes:ha].width;
    drawOnBaseline(holiday, ha, fx + (kTimeWidth * d - hw) / 2, y + kBaseline * hs);
  }

  // The icon stands still only in night mode (the user: no animation with
  // the red tint); in standby it keeps moving (the user asked, 6 Nov 2026).
  BOOL still = night;
  if (!hasCard || still) [self hideAnimation];
  if (rows.count) {
    // The card goes under the face, as wide as most of the time.
    CGFloat bw = MIN(kTimeWidth * d * 0.8, 440);
    CGRect cf = CGRectMake(x0 + (totalW - bw) / 2, y0 + totalH + kEnergyGap, bw, [_card height]);
    if (!CGRectEqualToRect(_card.frame, cf)) _card.frame = cf;
  }

  if (!hasCard) return;

  // Weather: the icon beside the temperature (the low - high was removed).
  CGFloat cx = row ? x0 + (kTimeWidth + 0.2) * d : x0 + (totalW - cardW * d) / 2;
  CGFloat cy = row ? y0 + (totalH - self.cardHeight * d) / 2 : fy + (faceH + 2 * kGap) * d;
  CGFloat s = kIcon * d;
  // Meteocons (Bas Milius, MIT), as on the phone: full colour, the art
  // fills ~70% of its box so it's drawn a little larger than the slot.
  NSString *wx = self.weather.icon ?: @"clear-day";
  CGRect box = CGRectInset(CGRectMake(cx, cy, s, s), -s * 0.18, -s * 0.18);
  if (still || ![self showAnimation:wx in:box]) {
    UIImage *img = weatherImage(wx, night);
    if (img) [img drawInRect:box];
  }
  // The temperature, its digits' ink centred on the icon.
  CGFloat ts = kTempSize * d;
  drawOnBaseline(temp, attrs(clockFont(ts), color, 0), cx + (kIcon + kTempGap) * d,
                 cy + s / 2 + kCapHeight * ts / 2);
}

@end
