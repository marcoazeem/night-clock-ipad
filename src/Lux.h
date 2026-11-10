// The "luxury" look (Nov 2026): OLED black, ivory and muted text, one
// gold accent, thin outline icons, cards with a brushed-metal hairline
// border. Shared drawing helpers, plus the screen's chrome — the top bar
// (room name, scenes), the room tabs and the energy strip.

#import <UIKit/UIKit.h>

@class NCEnergyTracker;

// ── Palette ──────────────────────────────────────────────────────────────
static const uint32_t kLuxGold = 0xFFC8A97E, kLuxIvory = 0xFFEDE6DA, kLuxMuted = 0xFF8E877C;
static const uint32_t kLuxHoliday = 0xFFFF4A3D;
static inline UIColor *NCRGBA(uint32_t rgb, CGFloat a) {
  return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0
                          blue:(rgb & 0xFF) / 255.0 alpha:a];
}
/// Gold, pulled to the night red in night mode (as every device colour is).
UIColor *NCLuxGold(BOOL night);
/// Ivory, a little dimmer in night mode.
UIColor *NCLuxIvory(BOOL night);
UIColor *NCLuxMuted(void);

// ── Type ─────────────────────────────────────────────────────────────────
/// A bundled font by PostScript name ("Inter-Regular", "Jost-ExtraLight"…),
/// else the system font.
UIFont *NCLuxFont(NSString *name, CGFloat size);
NSDictionary *NCLuxAttrs(UIFont *font, UIColor *color, CGFloat kern);
CGFloat NCLuxWidth(NSString *text, NSDictionary *attrs);
/// Draws one line with the top of its line box (ascender + descender, as
/// CSS's "normal" line height) at [y].
void NCLuxDraw(NSString *text, NSDictionary *attrs, CGFloat x, CGFloat y);
/// Same, centred vertically on [cy].
void NCLuxDrawMid(NSString *text, NSDictionary *attrs, CGFloat x, CGFloat cy);
/// The line box's height for [font].
CGFloat NCLuxLine(UIFont *font);
/// Small caps label: Inter Regular, letter-spaced, uppercase.
NSDictionary *NCLuxLabel(CGFloat size, CGFloat kern, UIColor *color);

// ── Icons ────────────────────────────────────────────────────────────────
/// Thin outline icons as SVG path data on a 24×24 grid.
extern NSString *const NCLuxIconBulb, *const NCLuxIconMoon, *const NCLuxIconSun, *const NCLuxIconFan,
    *const NCLuxIconCeiling, *const NCLuxIconMinus, *const NCLuxIconPlus, *const NCLuxIconPower,
    *const NCLuxIconPlay, *const NCLuxIconUpDown;
/// Strokes [svg] (24-unit grid) into [rect]; [stroke] is in grid units.
void NCLuxIcon(NSString *svg, CGRect rect, UIColor *color, CGFloat stroke);

// ── Cards ────────────────────────────────────────────────────────────────
/// A card on black: #050505 → #020202, and a 1 px "brushed metal" border
/// fading from [top] at the upper edge (170°) to [bottom] by [stop].
void NCLuxCard(CGRect r, CGFloat radius, UIColor *top, UIColor *bottom, CGFloat stop);
/// The usual card: ivory edge at [strength] (0.24 for big cards).
void NCLuxPlainCard(CGRect r, CGFloat radius, CGFloat strength);
/// A small glowing dot.
void NCLuxDot(CGPoint c, CGFloat radius, UIColor *color, CGFloat glow);

// ── Chrome ───────────────────────────────────────────────────────────────

/// The row across the top: the page's name left, the scenes right.
@interface NCTopBar : UIView
@property (nonatomic, copy) NSString *title;
@property (nonatomic) BOOL showScenes, night;
/// @"gn" / @"gm" while a scene runs (both fade), else nil.
@property (nonatomic, copy) NSString *running;
@property (nonatomic, copy) void (^onScene)(BOOL goodNight);
@end

/// Text-only tabs along the foot: HOME, then each room.
@interface NCTabBar : UIView
@property (nonatomic, copy) NSArray<NSString *> *titles;
@property (nonatomic) NSInteger active;
@property (nonatomic) BOOL night;
@property (nonatomic, copy) void (^onSelect)(NSInteger index);
@end

/// Under the picture: ENERGY, the room's draw and this bill's estimate,
/// and a thin gold line of the bills (kWh a day) with their months.
@interface NCEnergyStrip : UIView
@property (nonatomic, weak) NCEnergyTracker *energy;
/// The room whose draw is shown; -1 for the whole house.
@property (nonatomic) NSInteger room;
@property (nonatomic) BOOL night;
+ (CGFloat)height;
@end
