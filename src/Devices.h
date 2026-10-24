// The lights and ACs, local network only — ports of lib/lights.dart and
// lib/gree.dart. Every call here BLOCKS (sockets with timeouts); run them
// off the main thread, one device at a time (each device has its own queue).

#import <Foundation/Foundation.h>

@interface NCLight : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) BOOL dimmable;
/// A serial queue for this bulb's calls.
@property (nonatomic, readonly) dispatch_queue_t queue;
/// Reads on/off and brightness (-1 if unknown). NO on failure.
- (BOOL)readOn:(BOOL *)on brightness:(NSInteger *)brightness;
- (BOOL)setPower:(BOOL)on;
/// Sets the level (1–100) and turns the light on with it.
- (BOOL)setBrightness:(NSInteger)percent;
@end

/// Lights from lights.json, Tapo first, in the order given.
NSArray<NCLight *> *NCConfiguredLights(void);

@interface NCAcState : NSObject
@property (nonatomic) BOOL on;
@property (nonatomic) NSInteger setTemp;
/// 0 auto, 1 cool, 2 dry, 3 fan, 4 heat.
@property (nonatomic) NSInteger mode;
/// The unit's room sensor in °C, or NSNotFound.
@property (nonatomic) NSInteger roomTemp;
@end

static const NSInteger NCAcMinTemp = 16, NCAcMaxTemp = 30;

/// A Gree unit (Gree+ app) over its LAN protocol, JSON on UDP 7000.
@interface NCGreeAc : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) dispatch_queue_t queue;
- (NCAcState *)state;  // nil on failure
- (BOOL)setPower:(BOOL)on;
- (BOOL)setTemp:(NSInteger)celsius;
@end

NSArray<NCGreeAc *> *NCConfiguredAcs(void);

/// "Bed=192.168.1.20, Desk=…" → @[@[name, value], …]
NSArray<NSArray<NSString *> *> *NCEntries(NSString *spec);

// ── Plumbing shared with the TV code ─────────────────────────────────────
/// Sends [data] over UDP to host:port and returns the first reply, resending
/// [tries] times with [timeout] seconds each. nil if nothing came back.
NSData *NCUdpExchange(NSString *host, int port, NSData *data, int tries, double timeout);
/// Opens a TCP connection with a timeout; returns the socket or -1.
int NCTcpConnect(NSString *host, int port, double timeout);
NSData *NCRandomBytes(size_t n);
NSData *NCHex(NSString *hex);
