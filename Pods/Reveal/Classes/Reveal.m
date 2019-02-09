
//
//  RevealSDK.m
//  RevealSDK
//
//  Created by Sean Doherty on 1/8/2015.
//  Copyright (c) 2015 StepLeader Digital. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "RVLBeaconManager.h"
#import "RVLLocation.h"
#import "Reveal.h"
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <AdSupport/AdSupport.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <SystemConfiguration/CaptiveNetwork.h>

// This rather convoluded set of #defines allows you to pass in environment variables
// for buddy build but not require them if you're not.
//
// Due to the XCode mechanism provided, you will get directive defined as empty instead
// of undefined if there is no environment variable defined. This is seems overly complex
// for such a simple task, but it handles all of the cases as far as I can see.

#define DO_EXPAND(VAL)  VAL ## 1
#define EXPAND(VAL)     DO_EXPAND(VAL)

#if !defined(ENABLE_COLOR_LOGS) || (EXPAND(ENABLE_COLOR_LOGS) == 1)
#define ENABLE_COLOR_LOGS               0
#endif


#if !defined(ENABLE_VERBOSE_LOGS) || (EXPAND(ENABLE_VERBOSE_LOGS) == 1)
#define ENABLE_VERBOSE_LOGS             0
#endif


#ifndef objc_dynamic_cast
#define objc_dynamic_cast(TYPE, object)                                       \
    ({                                                                        \
        TYPE *dyn_cast_object = (TYPE *)(object);                             \
        [dyn_cast_object isKindOfClass:[TYPE class]] ? dyn_cast_object : nil; \
    })
#endif

#ifndef DEFAULT_DWELL_TIME
#define DEFAULT_DWELL_TIME 140.0
//#define DEFAULT_DWELL_TIME 40.0
#endif

#define LOG       \
if (self.log) \
self.log
#define VERBOSE          \
if (self.logVerbose) \
self.logVerbose

// TODO: this should be generated externally and set with -dSDK_REVISION="version#"
//       but until then we will define it here
#ifndef SDK_REVISION
#define SDK_REVISION @"1.3.39"
#endif

//#define SEND_NOTES

@implementation NSDictionary (DebugTools)

- (void) iterate:(NSString* _Nonnull)path withBlock:(void (^_Nonnull)(NSString* _Nonnull keyPath, id _Nonnull key, id _Nonnull data))callback
{
    for( id key in self.allKeys ) {
        id value = self[key];
        NSMutableString* keyPath = [NSMutableString stringWithString: path];
        
        if ( [keyPath length] > 0 )
            [keyPath appendString: @"."];
        
        [keyPath appendFormat: @"%@", key];
        
        if ( [value isKindOfClass: [NSDictionary class]] )
            [(NSDictionary*) value iterate: keyPath withBlock: callback];
        else if ( [value isKindOfClass: [NSArray class]] )
            [(NSArray*) value iterate: keyPath withBlock: callback];
        else if ( callback )
            callback( keyPath, key, value );
    }
}

@end

@implementation NSArray (DebugTools)

- (void) iterate:(NSString* _Nonnull)path withBlock:(void (^_Nonnull)(NSString* _Nonnull keyPath, id _Nonnull key, id _Nonnull data))callback
{
    int index = 0;
    for( id value in self ) {
        NSNumber* key = [NSNumber numberWithInt: index];
        NSMutableString* keyPath = [NSMutableString stringWithString: path];
        
        [keyPath appendFormat: @"[%@]", key];
        
        if ( [value isKindOfClass: [NSDictionary class]] )
            [(NSDictionary*) value iterate: keyPath withBlock: callback];
        else if ( [value isKindOfClass: [NSArray class]] )
            [(NSArray*) value iterate: keyPath withBlock: callback];
        else if ( callback )
            callback( keyPath, key, value );
        
        index++;
    }
}

@end

@interface EventCache : NSObject

@property (nonatomic, strong, nonnull) NSMutableArray<RVLGenericEvent*>* events;
@property (nonatomic, assign) NSInteger maxCachedEvents;
@property (nonatomic, assign) NSInteger maxCachedEventsOverrun;
@property (nonatomic, assign) NSTimeInterval idleTimeout;
@property (nonatomic, strong, nullable) void (^batchReady)(NSMutableArray<RVLGenericEvent*>* events);

@property (nonatomic, assign, nullable) NSTimer* idleTimer;

- (void) addEvent:(RVLGenericEvent* _Nonnull)event;
- (void) flushEvents;
- (void) iterate:(void (^ _Nonnull)(RVLGenericEvent*))block;

- (NSMutableArray<RVLGenericEvent*>* _Nonnull) getEventsAndClear;

@end

@interface Reveal ()
{
    __strong NSMutableDictionary<NSString*,RVLStatus*>* _statuses;
    BOOL started;
}

@property (nonatomic, strong, nonnull) EventCache* eventCache;
@property (nonatomic, assign) BOOL sendLocationUpdates;
@property (nonatomic, strong, nonnull) NSMutableDictionary* successStatistics;
@property (nonatomic, strong, nonnull) NSMutableDictionary* failureStatistics;

@end

@implementation Reveal
NSString *const kRevealBaseURLSandbox = @"http://sandboxsdk.revealmobile.com/";
NSString *const kRevealBaseURLProduction = @"https://sdk.revealmobile.com/";
NSString *const kRevealNSUserDefaultsKey = @"personas";
static Reveal *_sharedInstance;

- (instancetype)init
{
    self = [super init];
    
    if (self)
    {
        self.eventCache = [EventCache new];
        self.sendLocationUpdates = YES;
        self.batchBackgroundSend = YES;
        self.inBackground = NO;
        self.sendAllEvents = YES;
        self.canRequestLocationPermission = NO;
        self.successStatistics = [NSMutableDictionary dictionary];
        self.failureStatistics = [NSMutableDictionary dictionary];
        _statuses = [NSMutableDictionary dictionaryWithCapacity: 3];
        self.incompleteBeaconSendTime = 60.0 * 60.0;
    
        [self setStatus: [[RVLStatus alloc] init: STATUS_BLUETOOTH]];
        [self setStatus: [[RVLStatus alloc] init: STATUS_NETWORK]];
        [self setStatus: [[RVLStatus alloc] init: STATUS_WEB]];
        [self setStatus: [[RVLStatus alloc] init: STATUS_LOCATION]];
        
        [self.eventCache setBatchReady:^(NSMutableArray<RVLGenericEvent*> *eventsList )
                {
                    RVLLogWithType( @"COMM", @"Sending %d cached events to server", (int) [eventsList count] );
                    
                    NSMutableArray<RVLGenericEvent*>* current = [NSMutableArray arrayWithCapacity: [[[Reveal sharedInstance] eventCache] maxCachedEvents]];
                    
                    // split list into batches based the max batch size
                    for( RVLGenericEvent* event in eventsList ){
                        [current addObject: event];
                        
                        // if we have a completed batch or if this is the last then send what we have so far
                        if ( ( [current count] > [[[Reveal sharedInstance] eventCache] maxCachedEvents] ) || (event == eventsList.lastObject ) ) {
                            
                            [[Reveal sharedInstance] sendBatchToServer: current];
                            
                            // create a new array for the next set (can't remove
                            // all objects because the the send batch is still
                            // using it - but it will go away when it finishes
                            // with them)
                            current = [NSMutableArray arrayWithCapacity: [[[Reveal sharedInstance] eventCache] maxCachedEvents]];
                        }
                    }
                }];
    }
    
    return self;
}

- (void)dealloc
{
}

+ (Reveal *)sharedInstance
{
    // refuse to initialize unless we're at iOS 7 or later.
    if ([[[UIDevice currentDevice] systemVersion] integerValue] < 7)
    {
        return nil;
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      _sharedInstance = [[Reveal alloc] init];
      _sharedInstance.debug = NO;
      _sharedInstance.beaconScanningEnabled = YES;
    });

    return _sharedInstance;
}

- (void) addEvent:(RVLGenericEvent* _Nonnull) event
{    
    if ( [event isKindOfClass: [RVLBeacon class]] ) {
        // handle beacon found
        if ( [[RVLDwellManager defaultManager] addEvent: event] ) {
            id <RVLBeaconDelegate> theDelegate = [self delegate];
            if ( [theDelegate respondsToSelector: @selector(foundBeaconOfType:identifier:data:)] ) {
                
                NSMutableDictionary* data = [NSMutableDictionary dictionaryWithDictionary: [event jsonDictionary]];
                
                if ( [event isKindOfClass: [RVLBeacon class]] ) {
                    RVLBeacon* beacon = (RVLBeacon*) event;
                    
                    [[Reveal sharedInstance] recordEvent: [NSString stringWithFormat: @"%@ beacon", beacon.type] success: YES];
                    
                    data[@"beacon"] = beacon;
                    
                    [theDelegate foundBeaconOfType: beacon.type
                                        identifier: beacon.identifier
                                              data: data];
                }
                else if ( self.sendAllEvents ) {
                    // this is a hack for testing remove it later
                    data[@"beacon"] = event;
                    
                    [theDelegate foundBeaconOfType: @"WiFi"
                                        identifier: event.identifier
                                              data: data];
                }
            }
        }
    }
}

- (void) sendBatchToServer:(NSArray*)eventsList {
    RVLLogWithType( @"COMM", @"Sending batch of %d cached events to the server\n%@", (int) [eventsList count], eventsList );
    
    // send batch to server
    [[RVLWebServices sharedWebServices] sendEvents: eventsList
                                            result:^(BOOL success, NSDictionary *result, NSError *error)
     {
         if ( success )
         {
             // update sentTime in the events so thet the calling program can
             // know they competed successfully
             for( RVLGenericEvent* event in eventsList )
                 event.sentTime = [NSDate date];
             
             // Save any recieved personas for later
             [Reveal sharedInstance].personas = objc_dynamic_cast(NSArray, [result objectForKey:@"personas"]);
             RVLLog( @"Recieved %d personas", (int) [[[Reveal sharedInstance] personas] count] );
         }
         else
         {
             // TODO: handle resend here
         }
     }];
}

- (RVLLocationServiceType)locationServiceType
{
    RVLLocationServiceType result = RVLLocationServiceTypeNone;
    
    if ([[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSLocationAlwaysUsageDescription"])
        result = RVLLocationServiceTypeAlways;
    else if ([[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSLocationWhenInUseUsageDescription"])
        result = RVLLocationServiceTypeInUse;
    else if ([[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSLocationUsageDescription"])
        result = RVLLocationServiceTypeAlways;
    else if ([[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSLocationUsageDescription"])
        result = RVLLocationServiceTypeAlways;
    
    return result;
}

- (BOOL) useManagedBackgroundMode
{
    BOOL result = NO;
    
    if ( [self locationServiceType] == RVLLocationServiceTypeInUse )
    {
        if ( [self beaconScanningEnabled] )
        {
            result = YES;
        }
    }
    
    return result;
}

- (void) setInBackground:(BOOL)inBackground {
    // If we have switched background states, then we need to refresh our location provider to make sure we are requesting location correctly
    if (inBackground != _inBackground) {
        if ( [self locationManager] != nil ) {
            [[self locationManager] refreshLocationState];
        }
    }
    _inBackground = inBackground;
}

- (NSString *)version
{
    return [[RVLWebServices sharedWebServices] version];
}

- (void) setServiceType:(RVLServiceType)serviceType {
    _serviceType = serviceType;
    
    
    if ( _serviceType == RVLServiceTypeSandbox)
    {
        [[RVLWebServices sharedWebServices] setApiUrl:kRevealBaseURLSandbox];
    }
    else
    {
        [[RVLWebServices sharedWebServices] setApiUrl:kRevealBaseURLProduction];
    }
}

- (void)setDebug:(BOOL)debug
{
    _debug = debug;

    [[RVLDebugLog sharedLog] setEnabled:_debug];
}

- (id<RVLBeaconDelegate>) delegate {
    return [[self beaconManager] delegate];
}

- (void) setDelegate:(id<RVLBeaconDelegate>)delegate
{
    if ( self.beaconManager == nil )
        self.beaconManager = [RVLBeaconManager sharedManager];
    
    [[self beaconManager] setDelegate: delegate];
}

- (Reveal *)setupWithAPIKey:(NSString *)key
{
    return [self setupWithAPIKey:key andServiceType:RVLServiceTypeProduction];
}

- (Reveal *)setupWithAPIKey:(NSString *)key andServiceType:(RVLServiceType)serviceType
{
    if (key == nil) {
        RVLLog(@"No API Key passed in, API Key is required for Reveal to start");
        return nil;
    }
    
    // set up logging methods so that info can be forwarded through the
    // delegate calls in both of the other classes
    [[RVLWebServices sharedWebServices] setLog:RVLLogWithType];
    [[RVLWebServices sharedWebServices] setLogVerbose:RVLLogVerbose];
    [[RVLLocation sharedManager] setLog:RVLLogWithType];
    [[RVLBeaconManager sharedManager] setLog:RVLLogWithType];
    [[RVLBeaconManager sharedManager] setLogVerbose:RVLLogVerbose];
    
    RVLLog( @"Setting up Reveal SDK with key: %@ and ServiceType: %d", key, (int) serviceType );

    if ( self.locationManager == nil )
        self.locationManager = [RVLLocation sharedManager];
    
    if ( self.beaconManager == nil )
        self.beaconManager = [RVLBeaconManager sharedManager];
    
    self.startTime = [NSDate date];
    [[Reveal sharedInstance] recordSuccessEvent: @"setupWithAPIKey"];

    if ( ![[ASIdentifierManager sharedManager] isAdvertisingTrackingEnabled] ) {
        RVLLogWithType( @"LOCATION", @"Not requesting location since ad tracking is disabled");
        [[Reveal sharedInstance] setStatus: STATUS_BLUETOOTH value: 2 message: @"Disabled because no Ad ID provided"];
    }
    else {
        // code to handle location updates
        [[self locationManager] setLocationUpdated:^(CLLocation * _Nonnull newLocation, CLLocation * _Nullable oldLocation )
         {
             if ( self.sendLocationUpdates ) {
                 // Get the address (The current location will be upto date since
                 // we have just been triggered by the request)
                 [[self locationManager] waitForValidLocation:^{
                     RVLLocationEvent* locationEvent = [RVLLocationEvent new];
                     
                     locationEvent.location = [[RVLCoordinate alloc] initWithLocation: newLocation];
                     
                     [[RVLDwellManager defaultManager] addEvent: locationEvent];
                     
                     [[Reveal sharedInstance] recordSuccessEvent: @"Location update"];
                     
                     [[RVLDebugLog sharedLog] log: [NSString stringWithFormat: @"Location changed to %@",
                                                    locationEvent.location]
                                           ofType: @"LOCATION"];
                 }];
             }
             
             // Pass the location to the delegate if they implemented the delegate function
             if ( [[self delegate] respondsToSelector: @selector(locationDidUpdatedTo:from:)] )
                 [[self delegate] locationDidUpdatedTo: newLocation from: oldLocation];
         }];
    }
    [[RVLWebServices sharedWebServices] setApiKey: key];
    //Set service type value and update webservices with appropriate base url
    self.serviceType = serviceType;
    
    RVLLog(@"setupWithAPIKey complete");
    
    return self;
}


- (void) backgroundFetchWithCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler
{
    // We need to be attached to the app delegate inorder to get some occasional CPU time
    UIBackgroundFetchResult result = UIBackgroundFetchResultNoData;

    if ( completionHandler )
        completionHandler( result );
}

- (void) updateAPIEndpointBase:(NSString * _Nonnull)apiEndpointBase {
    RVLLog(@"Setting endpoint base to %@ - only for specific installations", apiEndpointBase);
    [[RVLWebServices sharedWebServices] setApiUrl:apiEndpointBase];
}

- (void)registerDevice
{
    RVLLog(@"Registering device with Server");
    
    if ( self.beaconManager == nil )
        self.beaconManager = [RVLBeaconManager sharedManager];
    
    if ( ![[ASIdentifierManager sharedManager] isAdvertisingTrackingEnabled] ) {
        RVLLogWithType( @"LOCATION", @"Not registering device since ad tracking is disabled");
        [[Reveal sharedInstance] setStatus: STATUS_BLUETOOTH value: 2 message: @"Disabled because no Ad ID provided"];
    }
    else {
        [[RVLWebServices sharedWebServices] registerDeviceWithResult:^(BOOL success, NSDictionary *result, NSError *error) {
          if (success)
          {
              RVLLog(@"Device registered successfully with parameters:\n%@", result );
              
              self.personas = objc_dynamic_cast(NSArray, [result objectForKey:@"personas"]);
              
              [[RVLDwellManager defaultManager] setReadyToSend:^(RVLGenericEvent * event ) {
                  [[self eventCache] addEvent: event];
                  
                  RVLLogWithType( @"DEBUG", @"Event %@ being sent with notes: %@", event.identifier, event.notes );
                  
                  id <RVLBeaconDelegate> theDelegate = [self delegate];
                  if ( [theDelegate respondsToSelector: @selector(leaveBeaconOfType:identifier:)] ) {
                      if ( [event isKindOfClass: [RVLBeacon class]] ) {
                          RVLBeacon* beacon = (RVLBeacon*) event;
                          [theDelegate leaveBeaconOfType: beacon.type identifier: beacon.identifier];
                          
                          // release the old beacon so we start new next time
                          if ( [[[Reveal sharedInstance] beaconManager]  respondsToSelector: @selector(blueToothObjectForKey:)] ) {
                              RevealBluetoothObject* device = [[[Reveal sharedInstance] beaconManager] blueToothObjectForKey: [[beacon bluetooth] identifier]];
                              
                              if ( device )
                                  device.beacon = nil;
                          }
                      }
                  }
              }];

              //Only start scanning if server returns discovery_enabled = true
              if ([objc_dynamic_cast(NSNumber, result[@"discovery_enabled"]) boolValue] || [[RVLWebServices sharedWebServices].apiUrl isEqualToString:@"https://import.locarta.co/"])
              {
                  if (self.beaconScanningEnabled)
                  {
                      RVLBeaconManager* mgr = (RVLBeaconManager*) [self beaconManager];
                      
                      if ( [mgr isKindOfClass: [RVLBeaconManager class]] )
                      {
    //                      NSNumber *cacheTime = result[@"cache_ttl"];
    //                      if ([cacheTime isKindOfClass:[NSNumber class]])
    //                          [[mgr cachedBeacons] setCacheTime:[cacheTime floatValue] * 60.0];
                          
                          NSNumber *useSignifigantChange = result[@"signifigant_change"];
                          if ( [useSignifigantChange isKindOfClass: [NSNumber class]] ) {
                              [[self locationManager] setUseSignifigantChange: [useSignifigantChange boolValue]];
                          }
                          
                          NSNumber *useSignifigantChangeInBackground = result[@"signifigant_change_in_background"];
                          if ( [useSignifigantChangeInBackground isKindOfClass: [NSNumber class]] ) {
                              [[self locationManager] setUseSignifigantChangeInBackground: [useSignifigantChangeInBackground boolValue]];
                          }
                          
                          NSNumber *scanInterval = result[@"scan_interval"];
                          if ([scanInterval isKindOfClass:[NSNumber class]])
                              [mgr setScanInterval:[scanInterval floatValue] + 0.123];
                          else
                              [mgr setScanInterval:30.0 + 0.123];

                          
                          NSNumber *scanLength = result[@"scan_length"];
                          if ([scanLength isKindOfClass:[NSNumber class]])
                              [mgr setScanDuration:[scanLength floatValue] + 0.321];
                          else
                              [mgr setScanDuration:10.0 + 0.321];
                          
                          NSNumber* eddystoneTimeout = result[@"eddystone_completion_timeout"];
                          if ([eddystoneTimeout isKindOfClass:[NSNumber class]])
                              [mgr setEddystoneTimeOut: [eddystoneTimeout floatValue]];
                          else
                              [mgr setEddystoneTimeOut: 60.0];
                          
                          if ( [mgr eddystoneTimeOut] < [mgr scanInterval] )
                              [mgr setEddystoneTimeOut: [mgr scanInterval]];
                          
                          NSNumber* locationTimeOut = result[@"location_fix_timeout"];
                          if ( [locationTimeOut isKindOfClass:[NSNumber class]] )
                              [[self locationManager] setLocationRetainTime: [locationTimeOut floatValue] * 60.0];
                          else
                              [[self locationManager] setLocationRetainTime: 30.0 * 60.0];
                          
                          NSNumber* proximityTimeout = result[@"proximity_timeout"];
                          if ( [proximityTimeout isKindOfClass: [NSNumber class]] )
                              [[self beaconManager] setProximityTimeout: [proximityTimeout floatValue]];
                          
                          // setup batch settings
                          NSNumber* batchSize = result[@"batch_size"];
                          if ([batchSize isKindOfClass:[NSNumber class]])
                              [[self eventCache] setMaxCachedEvents: [batchSize integerValue]];
                          else
                              [[self eventCache] setMaxCachedEvents: 20];
                          
                          NSNumber* batchTimeOut = result[@"batch_timeout"];
                          if ([batchTimeOut isKindOfClass:[NSNumber class]])
                              [[self eventCache] setIdleTimeout: [batchTimeOut floatValue]];
                          else
                              [[self eventCache] setIdleTimeout: 5.0];
                          
                          NSNumber* batchSendLocation = result[@"batch_send_location"];
                          if ([batchSendLocation isKindOfClass:[NSNumber class]])
                              [self setSendLocationEvents: [batchSendLocation boolValue]];
                          
                          NSNumber* batchBackgroundSend= result[@"batch_background_send"];
                          if ([batchBackgroundSend isKindOfClass:[NSNumber class]])
                              [self setBatchBackgroundSend: [batchBackgroundSend boolValue]];
                          else
                              [self setBatchBackgroundSend: true];
                          
                          // setup dwell timeout, if not provided set for 5 minutes
                          NSNumber* dwellTimeout = result[@"beacon_exit_time"];
                          if ( ![dwellTimeout isKindOfClass: [NSNumber class]] )
                              dwellTimeout = @DEFAULT_DWELL_TIME;
                          
                      NSNumber* incompleteTime = result[@"incompleteBeaconSendTime"];
                      if ([incompleteTime isKindOfClass:[NSNumber class]])
                          [[Reveal sharedInstance] setIncompleteBeaconSendTime: [incompleteTime floatValue]];
                      
                          [[RVLDwellManager defaultManager] addEventType: RVLEventTypeBeacon withLossDelay: [dwellTimeout doubleValue]];
                          [[RVLDwellManager defaultManager] addEventType: RVLEventTypeEnter withLossDelay: [dwellTimeout doubleValue]];
                          [[RVLDwellManager defaultManager] addEventType: RVLEventTypeWiFiEnter withLossDelay: [dwellTimeout doubleValue]];
                          [[RVLDwellManager defaultManager] addEventType: RVLEventTypeLocation withLossDelay: 0.0];
                          
                          // NOTE: On android we only scan for specific secure cast codes as send from the server
                          //       but on iOS we want to get them all since they return only FEEB beacons
                          [mgr addVendorNamed:@"SecureCast" withCode: BEACON_SERVICE_SECURECAST];
                          
                          // add gimbal beacons
                          [mgr addVendorNamed: @"Gimbal" withCode: BEACON_TYPE_GIMBAL];
                      }
                      
                       [[UIApplication sharedApplication] setMinimumBackgroundFetchInterval: [mgr scanInterval] * 5.0];
                      
                      // Only start scanning if the app is starting up
                      if ( !started) {
                          started = YES;
                          //If we have debug UUID's set, ignore list from server
                          if (self.debugUUIDs)
                          {
                              [self startScanningForBeacons:self.debugUUIDs];
                          }
                          else
                          {
                              if ( [[self beaconManager] isKindOfClass: [RVLBeaconManager class]] ) {
                                  NSArray *blackList = objc_dynamic_cast(NSArray, result[@"black_list"]);
                                  RVLBeaconManager* mgr = (RVLBeaconManager*) [self beaconManager];
                                  NSMutableArray* array = [NSMutableArray array];
                                  
                                  if ( [blackList count] > 0 ) {
                                      for( NSNumber* num in blackList ) {
                                          if ( [num respondsToSelector: @selector(integerValue)] )
                                              [array addObject: num];
                                      }
                                      
                                      mgr.blackListedManufacturers = array;
                                  }
                              }
                              
                              NSArray *beaconsToScan = objc_dynamic_cast(NSArray, result[@"beacons"]);
                              if ([beaconsToScan isKindOfClass:[NSArray class]] && beaconsToScan.count > 0)
                                  [self startScanningForBeacons:beaconsToScan];
                              else {
                                  [self startScanningForBeacons:@[@"97FAACA4-D7F1-416D-A5A4-E922DC6EDB29", @"BFF08989-7E03-408C-B71F-4631936D8E7F", @"6CA0C73C-F8EC-4687-9112-41DCB6F28879", @"66622E6D-652F-40CA-9E6F-6F7166616365", @"5993A94C-7D97-4DF7-9ABF-E493BFD5D000", @"43A2BC29-C111-4A76-8B6F-78AECB142E5A", @"23538C90-4E4C-4183-A32B-381CFD11C465", @"47F6C672-0791-4825-B4F5-7210E7D41366", @"07775DD0-111B-11E4-9191-0800200C9A66", @"B9407F30-F5F8-466E-AFF9-25556B57FE6D", @"E2C56DB5-DFFB-48D2-B060-D0F5A71096E0", @"27BBB38E-3059-4396-8CAA-44FD175F5C06", @"418D4E97-93E2-4D1E-8955-FEC049CDE728", @"F7826DA6-4FA2-4E98-8024-BC5B71E0893E", @"F1EABF09-E313-4FCD-80DF-67C779763888", @"01BBAC2B-46ED-789E-62E3-35896D73B89C", @"02BBAC2B-46ED-9C7E-8A21-A348DB2A568B", @"2EDB7643-3B2D-488A-90D9-FC9A1F67EF6B", @"B2DD3555-EA39-4F08-862A-00FB026A800B", @"8D847D20-0116-435F-9A21-2FA79A706D9E"]];
                              }
                              
                          }
                      }
                  }
                  else
                  {
                      RVLLog(@"Beacon scanning was manually disabled");
                      [self setStatus: STATUS_SCAN value: STATUS_FAILED message: @"Beacon scanning was manually disabled"];
                  }
              }
              else
              {
                  RVLLog(@"Beacon scanning was disabled from the server");
                  [self stopScanningForBeacons];
                  [self setStatus: STATUS_BLUETOOTH value: STATUS_FAILED message: @"Beacon scanning was disabled from the server"];
                  [self setStatus: STATUS_SCAN value: STATUS_FAILED message: @"Beacon scanning was disabled from the server"];
              }
          }
          else
          {
              RVLLogWithType(@"ERROR", @"Device registration failed:\n%@\nERROR: %@", result, error);
          }
        }];
    }
}

- (void)startScanningForBeacons:(NSArray *)beacons
{
    RVLLog(@"Starting beacon scanning with %d beacons", (int) [beacons count]);
    
#ifdef USE_APPLE_SCAN
    for (NSString *uuid in beacons)
    {
        RVLLog(@"Scanning for beacons with UUID: %@", uuid);
        [[self beaconManager] addBeacon:uuid];
    }
#endif
    
    //Start non-iBeacon scanner
    [[self beaconManager] startScanner];
    
}

- (void)stopScanningForBeacons
{
    if ( [[self beaconManager] isKindOfClass: [RVLBeaconManager class]] )
        [(RVLBeaconManager*)[self beaconManager] stopBeaconScanning];
}

- (void)start
{
    RVLLogWithType(@"INIT", @"Starting Reveal SDK\nVERSION=%@\nServerType=%d\nURL=%@", SDK_REVISION, (int) _serviceType, [[RVLWebServices sharedWebServices] baseUrl] );
    [[Reveal sharedInstance] recordSuccessEvent: @"startupBegan"];
    
    // save the start time for the dwell manager. This is neccisary so that
    // it doesn't imiedaitly release all the beacons even if you are still
    // near them now. We are working under the assumption that if you were
    // near them when you closed and you are still near them when you
    // start back up then you never left.
    [[RVLDwellManager defaultManager] setStartupTime: [NSDate date]];
    
    // We only start in the foreground, so set the initial state
    [self setInBackground: NO];
    
    // Register for foreground notifications so we can handle the restart
    // since mParticle doesn't call us then.
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(wakeUp:)
                                                 name: UIApplicationWillEnterForegroundNotification
                                               object: nil];
    
    
    // TODO: We could check and flush the event cache here
    //       but this isn't required because the next incomming
    //       event will trigger it, so will save it for a future
    //       build when we are not rushed and can do some testing
    //       for possible threading issues.
    
    // if configured for detect location at start or already have permission just begin startup
    // otherwise we wait until permission is granted
    // TODO: Do we want to make this a part of the location manager?
    //       it seems to belong there but then we complicate the
    //       requirements on the user provided class if they choose
    //       to go that route. We should discuss this in the future
    if ( ![[ASIdentifierManager sharedManager] isAdvertisingTrackingEnabled] ) {
        RVLLogWithType( @"LOCATION", @"Not requesting location since ad tracking is disabled");
        [[Reveal sharedInstance] setStatus: STATUS_BLUETOOTH value: 2 message: @"Disabled because no Ad ID provided"];
    }
    else if ( [self canRequestLocationPermission] || [CLLocationManager authorizationStatus] == kCLAuthorizationStatusAuthorizedAlways
        || [CLLocationManager authorizationStatus] == kCLAuthorizationStatusAuthorizedWhenInUse) {
        [self.locationManager startLocationMonitoring];
        
        // send the registration request to Reveal's servers
        [self sendRegistrationIfPermitted];
        [[Reveal sharedInstance] recordSuccessEvent: @"startupCompleted"];
    }
    else {
        RVLLogWithType( @"STATE", @"Startup deffered  - awaiting location permission" );
    }
}

- (void)restart {
    // start location monitoring if 
    [[self locationManager] startLocationMonitoring];
    
    // since we are restarting we must be in the foreground
    [self setInBackground: NO];
    [self sendRegistrationIfPermitted];
    
    [[RVLDwellManager defaultManager] setStartupTime: [NSDate date]];
    
    [[Reveal sharedInstance] recordSuccessEvent: @"restart"];
}

- (void) sendRegistrationIfPermitted
{
    RVLLogWithType(@"STATE", @"Waiting for location before registering device");
    
    if ( self.locationManager )
    {
        [self.locationManager waitForValidLocation: ^()
            {
                if ( [CLLocationManager authorizationStatus] == kCLAuthorizationStatusAuthorizedAlways
                    || [CLLocationManager authorizationStatus] == kCLAuthorizationStatusAuthorizedWhenInUse)  {
                        [self handleRegistration];
                }
            }];
    }
    else {
        RVLLogWithType( @"ERROR",
                        @"No location manager set prior to sendRegistration, Did you call setupWithAPIKey?" );
    }
}

- (void) stop {
    if ( started ) {
        [[self beaconManager] stopBeaconScanning];
        
        started = NO;
    }
}

- (void) wakeUp:(NSNotification*)notification
{
    // If we have already started then restart - if not we do nothing
    if ( [self startTime] != nil )
    {
        RVLLogWithType( @"INFO", @"Returning to foreground restarting beacon monitoring" );
        
        [self restart];
    }
}

- (void) memoryWarning
{
    [[RVLDwellManager defaultManager] memoryWarning];
}

- (void) handleRegistration
{
    RVLLogWithType(@"STATE", @"Registering device");
    
    //If we are starting, we need to wait for the bluetooth status to be enabled
    if ( [CBCentralManager instancesRespondToSelector:@selector(initWithDelegate:queue:options:)] &&
         [[self beaconManager] isKindOfClass: [RVLBeaconManager class]] )
    {
        RVLLogVerbose(@"DEBUG", @"This device supports Bluetooth LE");
        // enable beacon scanning if this device supports Bluetooth LE
        [(RVLBeaconManager*)[self beaconManager] addStatusBlock:^(CBCentralManagerState state)
         {
             RVLLogVerbose(@"DEBUG", @"Bluetooth status block called");
             // don't connect to the endpoint until the bluetooth status is ready

             
         }];
        
        [self registerDevice];
    } else {
        RVLLog(@"Either cbcentralmanager can't be initialized or beacon manager isn't our beacon manager it is %@",self.beaconManager);
    }
}

- (void)setPersonas:(NSArray *)personas
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:personas forKey:kRevealNSUserDefaultsKey];
    [defaults synchronize];
}

- (NSArray *)personas
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:kRevealNSUserDefaultsKey];
}

- (NSDictionary *)beacons
{
    NSDictionary *result = @{};

    if ( [[self beaconManager] beacons] )
    {
        result = [[self beaconManager] beacons];
    }

    return result;
}

- (NSDictionary *)devices
{
    NSDictionary* result = @{};
    
    if ( [[self beaconManager] isKindOfClass: [RVLBeaconManager class]] )
        result = [[(RVLBeaconManager*)[self beaconManager] bluetoothDevices] dictionary];
    
    return result;
}

- (BOOL) captureAllDevices
{
    BOOL result = NO;
    
    if ( [[self beaconManager] isKindOfClass: [RVLBeaconManager class]] )
        result = [(RVLBeaconManager*)[self beaconManager] captureAllDevices];
    
    return result;
}

- (void) setCaptureAllDevices:(BOOL)captureAllDevices
{
    if ( [[self beaconManager] isKindOfClass: [RVLBeaconManager class]] )
        [(RVLBeaconManager*)[self beaconManager] setCaptureAllDevices: captureAllDevices];
}

- (NSDictionary<NSString*, RevealBluetoothObject*>*) bluetoothDevices
{
    NSDictionary* result = @{};
    
    if ( [[self beaconManager] isKindOfClass: [RVLBeaconManager class]] )
        result = [[(RVLBeaconManager*)[self beaconManager] bluetoothDevices] dictionary];
    
    return result;
}

- (CurveFittedDistanceCalculator*) distanceCalculator
{
    CurveFittedDistanceCalculator* result = nil;
    
    if ( [self.beaconManager isKindOfClass: [RVLBeaconManager class]] )
    {
        result = [(RVLBeaconManager*) self.beaconManager distanceCalculator];
    }
    
    return result;
}

- (void) recordSuccessEvent:(NSString*)eventName{
    [self recordEvent: eventName success: YES];
}

- (void) recordEvent:(NSString*)eventName success:(BOOL)success {
    [self recordEvent: eventName success: success count: 1];
}

- (void) recordEvent:(NSString*)eventName success:(BOOL)success count:(NSInteger)count {
    NSMutableDictionary* stats = nil;
    NSString* name = eventName;
    
    // track forground and background seperately
    if ( [[Reveal sharedInstance] inBackground] )
        name = [NSString stringWithFormat: @"%@ (background)", eventName];
    
    if ( success )
        stats = self.successStatistics;
    else
        stats = self.failureStatistics;
    
    NSNumber* total = stats[name];
    
    if ( total == nil )
        total = [NSNumber numberWithInteger: count];
    else
        total = [NSNumber numberWithInteger: total.integerValue + count];
    
    stats[name] = total;
}

- (NSDictionary<NSString*,NSDictionary<NSString*, NSNumber*>*>*) statistics {
    NSMutableDictionary* result = [NSMutableDictionary dictionaryWithCapacity: 2];
    
    result[@"success"] = [NSDictionary dictionaryWithDictionary: [self successStatistics]];
    result[@"failure"] = [NSDictionary dictionaryWithDictionary: [self failureStatistics]];
    
    return result;
}

// set the specified status
- (void) setStatus:(NSString* _Nonnull)name
             value:(NSInteger)value
           message:(NSString* _Nullable)message {
    RVLStatus* status = [self getStatus: name];
    
    if ( status == nil )
        status = [[RVLStatus alloc] init: name value: value];
    else {
        [status updateValue: value message: message];
    }
    
    status.time = [NSDate date];
    [self setStatus: status];
}

// set the specified status
- (void) setStatus:(RVLStatus* _Nonnull)status {
    _statuses[[[status name] lowercaseString]] = status;
    
    //RVLLogWithType( @"STATE",  @"Set %@ status to %d with message: %@", status.name, (int) status.value, status.message );
    
    dispatch_async( dispatch_get_main_queue(), ^
                   {
                       [[NSNotificationCenter defaultCenter] postNotificationName: STATUS_UPDATED_NOTIFICATION
                                                                           object: self
                                                                         userInfo: @{ @"status": status}];
                   });
}

// get the specified status
- (RVLStatus* _Nullable) getStatus:(NSString* _Nonnull) name {
    return _statuses[[name lowercaseString]];
}

@end

typedef enum {
    ConnectionTypeUnknown,
    ConnectionTypeNone,
    ConnectionType3G,
    ConnectionTypeWiFi
} ConnectionType;

#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <SystemConfiguration/SystemConfiguration.h>

#define IOS_CELLULAR @"pdp_ip0"
#define IOS_WIFI @"en0"
#define IOS_VPN @"utun0"
#define IP_ADDR_IPv4 @"ipv4"
#define IP_ADDR_IPv6 @"ipv6"

NSString *const kGodzillaDefaultsUrl = @"kGodzillaDefaultsUrl";
NSString *const kGodzillaDefaultsKey = @"kGodzillaDefaultsKey";

@implementation RVLWebServices

+ (RVLWebServices *)sharedWebServices
{
    static RVLWebServices *_mgr;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _mgr = [[RVLWebServices alloc] init];
    });
    
    return _mgr;
}

// Persist the info to access Godzilla for background operation
- (NSString *)apiKey
{
    return [[NSUserDefaults standardUserDefaults] objectForKey:kGodzillaDefaultsKey];
}

- (void)setApiKey:(NSString *)apiKey
{
    if ( apiKey )
        [[NSUserDefaults standardUserDefaults] setObject:apiKey forKey:kGodzillaDefaultsKey];
    else
        [[NSUserDefaults standardUserDefaults] removeObjectForKey: kGodzillaDefaultsKey];
    
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSString *) baseUrl{
    return self.apiUrl;
}

- (NSMutableDictionary *)getDefaultParameters
{
    return [self getDefaultParametersIncludeLocation: YES];
}

- (NSMutableDictionary *)getDefaultParametersIncludeLocation:(BOOL)includeLocation
{
    NSString *timeZone = [NSString stringWithFormat:@"%@", [NSTimeZone defaultTimeZone]] ?: @"";
    
    CTTelephonyNetworkInfo *telephonyInfo = [CTTelephonyNetworkInfo new];
    NSString *networkType = nil;
    
    switch ([[RVLWebServices sharedWebServices] connectionType])
    {
        case ConnectionTypeWiFi:
            networkType = @"wifi";
            break;
            
        case ConnectionTypeNone:
            networkType = @"none";
            break;
            
        default:
            networkType = telephonyInfo.currentRadioAccessTechnology;
            networkType = [networkType stringByReplacingOccurrencesOfString:@"CTRadioAccessTechnology" withString:@""];
            break;
    }
    
    LOG(@"INFO", @"Network type: %@", networkType);
    
    NSString* locationPermissionRequested = nil;
    
    switch ( [[Reveal sharedInstance] locationServiceType] ) {
        case RVLLocationServiceTypeNone:
            locationPermissionRequested = @"None";
            break;
            
        case RVLLocationServiceTypeInUse:
            locationPermissionRequested = @"In Use";
            break;
            
        case RVLLocationServiceTypeAlways:
            locationPermissionRequested = @"Always";
            break;
            
        default:
            locationPermissionRequested = @"Unknown";
            break;
    }
    
    
    NSMutableDictionary *fullParameters = [@{
                                             @"os" : @"ios",
                                             @"device_id" : [[[UIDevice currentDevice] identifierForVendor] UUIDString],
                                             @"app_version" : [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
                                             @"sdk_version" : SDK_REVISION,
                                             @"app_id" : [[NSBundle mainBundle] bundleIdentifier],
                                             @"sdk_version" : [self version],
                                             @"time_zone" : timeZone,
                                             @"locationSharingEnabled": [NSNumber numberWithBool: [CLLocationManager authorizationStatus] == kCLAuthorizationStatusAuthorizedAlways || [CLLocationManager authorizationStatus] == kCLAuthorizationStatusAuthorizedWhenInUse],
                                             @"locationPermissionRequested": locationPermissionRequested,
                                             @"version" : [[UIDevice currentDevice] systemVersion] ?: @"N/A",
                                             @"locale" : [[NSLocale currentLocale] localeIdentifier] ?: @"N/A",
                                             } mutableCopy];
    
    if ( [[[Reveal sharedInstance] beaconManager] isKindOfClass: [RVLBeaconManager class]] )
    {
        fullParameters[@"bluetooth_enabled"] = @( [(RVLBeaconManager*)[[Reveal sharedInstance] beaconManager] hasBluetooth] );
        fullParameters[@"supports_ble"] = @( [(RVLBeaconManager*)[[Reveal sharedInstance] beaconManager] hasBluetooth] );; // TODO: Is this right?
    }
    
    // Get make and model - note this is less useful than the android equivilent
    fullParameters[RVLManufacturer] = @"Apple";
    UIDevice* device = [UIDevice currentDevice];
    NSString* model = [device model];
    if ( model ) {
        fullParameters[RVLModel] = model;
    }
    
    if (networkType)
        fullParameters[@"con_type"] = networkType;
    
    if ( self.build )
        fullParameters[@"sdk_build"] = self.build;
    
    if ( includeLocation )
    {
        CLLocation* location = [[[Reveal sharedInstance] locationManager] userLocation];
        if (location) {
            fullParameters[@"location"] = [self locationJSONForLocation: location];
        }
    }
    
    if ([[ASIdentifierManager sharedManager] isAdvertisingTrackingEnabled])
    {
        //[DO] idfa is not guaranteed to return a valid string when device firsts starts up
        NSString *idfa = [[[ASIdentifierManager sharedManager] advertisingIdentifier] UUIDString];
        LOG(@"DEBUG", @"IDFA Available and is %@", idfa);
        if (idfa != nil && ![idfa isEqualToString:@""])
        {
            fullParameters[@"idfa"] = idfa;
        }
    }
    
    return fullParameters;
}

- (NSString *)version
{
    return SDK_REVISION;
}

- (void)registerDeviceWithResult:(void (^)(BOOL success, NSDictionary *result, NSError *error))result
{
    NSDictionary *params = @{
                             @"version" : [[UIDevice currentDevice] systemVersion] ?: @"",
                             @"locale" : [[NSLocale currentLocale] localeIdentifier] ?: @"",
                             //@"bluetooth_version" : @"4",     // not available on iOS
                             };
    NSMutableDictionary *fullParams = [self getDefaultParameters];
    [fullParams addEntriesFromDictionary:params];
    
    [[RVLWebServices sharedWebServices] sendRequestToEndpoint:@"info" withParams:fullParams forResult:result];
}

- (NSDictionary* _Nonnull) locationJSONForLocation: (CLLocation* _Nonnull)location
{
    CLLocationCoordinate2D coord = location.coordinate;
    NSTimeInterval coordAge = [[NSDate date] timeIntervalSinceDate:location.timestamp];
    NSUInteger coordAgeMS = (NSUInteger)(coordAge * pow(10, 6)); // convert to milliseconds
    NSNumber *floor = @(0);
    NSTimeInterval timeOffset = 999999.99;
    
    if ( location )
        timeOffset = [[location timestamp] timeIntervalSinceNow];
    
    
    if ( [location respondsToSelector: @selector(floor)] ) {
        if (location.floor)
            floor = [NSNumber numberWithInteger:location.floor.level];
    }
    
    return @{
                @"lat" : @(coord.latitude),
                @"lon" : @(coord.longitude),
                @"time" : @(coordAgeMS),
                @"altitude" : @(location.altitude),
                @"speed" : @(location.speed),
                @"floor" : floor,
                @"accuracy" : @(location.horizontalAccuracy),
                @"age" : @(timeOffset),
                @"provider": @"gps"
            };
}
    

- (NSDictionary* _Nonnull) placemarkJSONForPlacemark: (CLPlacemark* _Nonnull)addressPlacemark
{
    return @{
               @"street" : addressPlacemark.addressDictionary[@"Street"] ?: @"",
               @"city" : addressPlacemark.locality ?: @"",
               @"state" : addressPlacemark.administrativeArea ?: @"",
               @"zip" : addressPlacemark.postalCode ?: @"",
               @"country" : addressPlacemark.country ?: @"",
            };
}


- (void)sendEvents:(NSArray<RVLGenericEvent*> *)events
            result:(void (^)(BOOL success, NSDictionary *result, NSError *error))complete
{
    NSMutableDictionary *fullParams = [self getDefaultParametersIncludeLocation: NO];
    NSError* error = nil;
    
    // handle beacon events
    NSArray* beacons = [events filteredArrayUsingPredicate: [NSPredicate predicateWithFormat: @"eventType==%d", RVLEventTypeBeacon]];
    NSMutableArray* beaconsJSON = [NSMutableArray arrayWithCapacity: [beacons count]];
    for( RVLBeacon* beacon in beacons ) {
        NSDictionary* jsonDict = [beacon jsonDictionary];
        [beaconsJSON addObject: jsonDict];
        NSData* jsonData = [NSJSONSerialization dataWithJSONObject: jsonDict options:0 error:&error];
        RVLLogWithType( @"TEST", @"[NAME]='event' [TYPE]='JSON' [ID]='beacon'\n%@", [[NSString alloc] initWithData: jsonData encoding: NSASCIIStringEncoding] );
    }
    
    if ( [beaconsJSON count] )
        fullParams[@"beacons"] = beaconsJSON;
    
    // handle locations
    NSArray* locations = [events filteredArrayUsingPredicate: [NSPredicate predicateWithFormat: @"eventType==%d", RVLEventTypeLocation]];
    NSMutableArray* locationsJSON = [NSMutableArray arrayWithCapacity: [locations count]];
    for( RVLLocationEvent* loc in locations )
    {
        NSDictionary* jsonDict = [loc jsonDictionary];
        [locationsJSON addObject: jsonDict];
        NSData* jsonData = [NSJSONSerialization dataWithJSONObject: jsonDict options:0 error:&error];
        RVLLogWithType( @"TEST", @"[NAME]='event' [TYPE]='JSON' [ID]='location'\n%@", [[NSString alloc] initWithData: jsonData encoding: NSASCIIStringEncoding] );
        
    }
    
    if ( [locationsJSON count] )
        fullParams[@"locations"] = locationsJSON;
    
    [self sendRequestToEndpoint: @"event/batch"
                     withParams: fullParams
                      forResult: ^(BOOL success, NSDictionary *result, NSError *error)
     {
         if ( complete )
             complete( success, result, error );
     }];
}

- (void) sendInfo:(NSDictionary*)jsonableDictionary
           result:(void (^)(BOOL success, NSDictionary* result, NSError* error))complete
{
    NSMutableDictionary* params = [self getDefaultParameters];
    
    params[@"place"] = jsonableDictionary;
    
    [self sendRequestToEndpoint: @"nearby/info" withParams: params
                      forResult: ^(BOOL success, NSDictionary *result, NSError *error)
     {
         //LOG( @"COMM", @"sendInfo result=%@", result );
         
         if ( complete )
             complete( success, result, error );
     }];
}

- (void)sendRequestToEndpoint:(NSString *)endpoint
                   withParams:(NSDictionary *)params
                    forResult:(void (^)(BOOL success, NSDictionary *result, NSError *error))result
{
    RVLLog(@"Starting request dispatch on background thread");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // These gyrations avoid a double slash (http://foo.com//api/info)
        // which gives godzilla the fits.
        NSURL *apiUrl = [NSURL URLWithString:self.apiUrl];
        NSString *methodPath = [NSString stringWithFormat:@"/api/v3/%@", endpoint];
        NSURL *reqUrl = [NSURL URLWithString:methodPath relativeToURL:apiUrl];
        
        NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:reqUrl];
        [urlRequest setValue:self.apiKey forHTTPHeaderField:@"X-API-KEY"];
        [urlRequest setValue:@"application/json" forHTTPHeaderField:@"content-type"];
        
        [params iterate: @"params" withBlock:^(NSString * _Nonnull keyPath, id  _Nonnull key, id  _Nonnull data) {
            if ( ![data isKindOfClass: [NSString class]] && ![data isKindOfClass: [NSNumber class]] ) {
                RVLLog( @"request parameter %@ is unknown type %@", keyPath, [data class] );
            }
        }];
        
        [urlRequest setHTTPMethod:@"POST"];
        NSError *error = nil;
        NSData *body = [NSJSONSerialization dataWithJSONObject:params options:0 error:&error];
        RVLLog(@"After serialization, before request sending");
        if ( error ) {
            RVLLog(@"Request JSON serialization error: %@", error);
            [[Reveal sharedInstance] setStatus: STATUS_WEB value: 0 message: [error localizedDescription]];
        }
        
        if (body)
        {
            [urlRequest setHTTPBody:body];
            
            NSString *requestString = [[NSString alloc] initWithData:urlRequest.HTTPBody encoding:NSUTF8StringEncoding];
            RVLLog(@"Request post to URL: %@ with data: %@", reqUrl.absoluteURL, requestString);
            
            NSURLSession *session = [NSURLSession sharedSession];
            NSURLSessionDataTask *task = [session dataTaskWithRequest:urlRequest
                                                    completionHandler:^(NSData *data,
                                                                        NSURLResponse *response,
                                                                        NSError *error)
                                          {
                                              RVLLog(@"Data task finished");
                                              NSDictionary *jsonDict = nil;
                                              NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
                                              NSString* responseText = [[NSString alloc] initWithData: data
                                                                                             encoding: NSUTF8StringEncoding];
                                              if ( statusCode >= 300 )
                                              {
                                                  RVLLog(@"HTTP Error: %ld %@\nReq:\n%@\nResponse:\n%@",
                                                      (long)statusCode, responseText, requestString, response );
                                                  
                                                  if ( responseText == nil )
                                                      responseText = [NSString stringWithFormat: @"HTTP Error %d", (int) statusCode];
                                                  
                                                  error = [NSError errorWithDomain: @"Reveal server"
                                                                              code: statusCode
                                                                          userInfo: @{NSLocalizedDescriptionKey: responseText}];
                                                  
                                                  [[Reveal sharedInstance] recordEvent: methodPath success: NO];
                                                  [[Reveal sharedInstance] setStatus: STATUS_WEB  value: 0 message: [error localizedDescription]];
                                              }
                                              else if ( [data length] > 0 )
                                              {
                                                  RVLLog(@"Response from server is %ld: %@", (long)statusCode, responseText);
                                                  
                                                  //build JSON for result
                                                  jsonDict = [NSJSONSerialization JSONObjectWithData: data
                                                                                             options: NSJSONReadingMutableContainers
                                                                                               error: &error];
                                                  
                                                  //if json error, return error to result
                                                  if (error)
                                                  {
                                                      RVLLog(@"Error parsing response: %@",error.localizedDescription);
                                                      result(NO, @{ @"errors" : @"Error parsing response from Reveal API" }, error);
                                                      [[Reveal sharedInstance] recordEvent: methodPath success: NO];
                                                      
                                                      [[Reveal sharedInstance] setStatus: STATUS_WEB  value: 0 message: [error localizedDescription]];
                                                      return;
                                                  }
                                                  
                                                  //check json result for error array
                                                  NSArray *errorsArray = objc_dynamic_cast(NSArray, [jsonDict objectForKey:@"errors"]);
                                                  if (errorsArray && [errorsArray count] > 0)
                                                  {
                                                      //if errors returned from server, return error to result
                                                      result(NO, jsonDict, error);
                                                      [[Reveal sharedInstance] recordEvent: methodPath success: NO];
                                                      [[Reveal sharedInstance] setStatus: STATUS_WEB  value: 0 message: [[errorsArray firstObject] localizedDescription]];
                                                      return;
                                                  }
                                                  else {
                                                      [[Reveal sharedInstance] recordEvent: methodPath success: YES];
                                                      [[Reveal sharedInstance] setStatus: STATUS_WEB  value: 1 message: [NSString stringWithFormat: @"SUCCESS: %@%@",self.apiUrl, methodPath]];
                                                  }
                                              }
                                              else
                                              {
                                                  jsonDict = @{};
                                                  [[Reveal sharedInstance] setStatus: STATUS_WEB  value: 0 message: [NSString stringWithFormat: @"SUCCESS: Empty - status: %d", (int) statusCode]];
                                              }
                                              
                                              //if error or no data, return error to result
                                              if ( error)
                                              {
                                                  RVLLog(@"Error from request: %@",error.localizedDescription);
                                                  result(NO, @{ @"errors" : @"Error requesting Reveal API" }, error);
                                                  [[Reveal sharedInstance] setStatus: STATUS_WEB  value: 0 message: [error localizedDescription]];
                                                  
                                                  return;
                                              }
                                              
                                              //if no errors, return success to result
                                              dispatch_async(dispatch_get_main_queue(), ^
                                                             {
                                                                 result(YES, jsonDict, error);
                                                             });
                                          }];
            
            [task resume];
        }
        else
        {
            RVLLog(@"Could not encode Error: %@ body:\n%@", error, params);
            [[Reveal sharedInstance] recordEvent: methodPath success: NO];
            [[Reveal sharedInstance] setStatus: STATUS_WEB  value: 0 message: [NSString stringWithFormat: @"Could not encode Error: %@ body:\n%@", error, params]];
            
            if (result)
            {
                dispatch_async(dispatch_get_main_queue(), ^
                               {
                                   result(NO, nil, error);
                               });
            }
        }
    });
}

- (NSString *)getIPAddress:(BOOL)preferIPv4
{
    NSArray *searchArray = preferIPv4 ? @[ IOS_VPN @"/" IP_ADDR_IPv4, IOS_VPN @"/" IP_ADDR_IPv6, IOS_WIFI @"/" IP_ADDR_IPv4, IOS_WIFI @"/" IP_ADDR_IPv6, IOS_CELLULAR @"/" IP_ADDR_IPv4, IOS_CELLULAR @"/" IP_ADDR_IPv6 ] : @[ IOS_VPN @"/" IP_ADDR_IPv6, IOS_VPN @"/" IP_ADDR_IPv4, IOS_WIFI @"/" IP_ADDR_IPv6, IOS_WIFI @"/" IP_ADDR_IPv4, IOS_CELLULAR @"/" IP_ADDR_IPv6, IOS_CELLULAR @"/" IP_ADDR_IPv4 ];
    
    NSDictionary *addresses = [self getIPAddresses];
    VERBOSE(@"INFO", @"addresses: %@", addresses);
    
    __block NSString *address;
    [searchArray enumerateObjectsUsingBlock:^(NSString *key, NSUInteger idx, BOOL *stop) {
        address = addresses[key];
        if (address)
            *stop = YES;
    }];
    return address ? address : @"0.0.0.0";
}

- (NSDictionary *)getIPAddresses
{
    NSMutableDictionary *addresses = [NSMutableDictionary dictionaryWithCapacity:8];
    
    // retrieve the current interfaces - returns 0 on success
    struct ifaddrs *interfaces;
    if (!getifaddrs(&interfaces))
    {
        // Loop through linked list of interfaces
        struct ifaddrs *interface;
        for (interface = interfaces; interface; interface = interface->ifa_next)
        {
            if (!(interface->ifa_flags & IFF_UP) /* || (interface->ifa_flags & IFF_LOOPBACK) */)
            {
                continue; // deeply nested code harder to read
            }
            const struct sockaddr_in *addr = (const struct sockaddr_in *)interface->ifa_addr;
            char addrBuf[MAX(INET_ADDRSTRLEN, INET6_ADDRSTRLEN)];
            if (addr && (addr->sin_family == AF_INET || addr->sin_family == AF_INET6))
            {
                NSString *name = [NSString stringWithUTF8String:interface->ifa_name];
                NSString *type;
                if (addr->sin_family == AF_INET)
                {
                    if (inet_ntop(AF_INET, &addr->sin_addr, addrBuf, INET_ADDRSTRLEN))
                    {
                        type = IP_ADDR_IPv4;
                    }
                }
                else
                {
                    const struct sockaddr_in6 *addr6 = (const struct sockaddr_in6 *)interface->ifa_addr;
                    if (inet_ntop(AF_INET6, &addr6->sin6_addr, addrBuf, INET6_ADDRSTRLEN))
                    {
                        type = IP_ADDR_IPv6;
                    }
                }
                if (type)
                {
                    NSString *key = [NSString stringWithFormat:@"%@/%@", name, type];
                    addresses[key] = [NSString stringWithUTF8String:addrBuf];
                }
            }
        }
        // Free memory
        freeifaddrs(interfaces);
    }
    return [addresses count] ? addresses : nil;
}

// code from: http://stackoverflow.com/questions/7938650/ios-detect-3g-or-wifi
//
// for most things you want to use Reachability, but we are using this simple synchronous call
//
- (ConnectionType)connectionType
{
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithName(NULL, "8.8.8.8");
    SCNetworkReachabilityFlags flags;
    BOOL success = SCNetworkReachabilityGetFlags(reachability, &flags);
    CFRelease(reachability);
    if (!success)
    {
        return ConnectionTypeUnknown;
    }
    BOOL isReachable = ((flags & kSCNetworkReachabilityFlagsReachable) != 0);
    BOOL needsConnection = ((flags & kSCNetworkReachabilityFlagsConnectionRequired) != 0);
    BOOL isNetworkReachable = (isReachable && !needsConnection);
    
    if (!isNetworkReachable)
    {
        return ConnectionTypeNone;
    }
    else if ((flags & kSCNetworkReachabilityFlagsIsWWAN) != 0)
    {
        return ConnectionType3G;
    }
    else
    {
        return ConnectionTypeWiFi;
    }
}

- (BOOL)isWiFi {
    return ( [self connectionType] == ConnectionTypeWiFi );
}

@end


#pragma mark - Dwell Manager -

@interface RVLDwellManager ()

@property (nonatomic, strong, nonnull) NSMutableDictionary<NSString*, RVLGenericEvent*>* pendingEvents;
@property (nonatomic, strong, nonnull) NSMutableDictionary<NSNumber*, NSNumber*>* eventTypeTimes;

@end

@implementation RVLDwellManager

+ (RVLDwellManager* _Nonnull) defaultManager
{
    static RVLDwellManager *_mgr;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
          _mgr = [[RVLDwellManager alloc] init];
      });
    
    return _mgr;
}

- (instancetype) init {
    self = [super init];
    
    if ( self ) {
        self.pendingEvents = [NSMutableDictionary dictionary];
        self.eventTypeTimes = [NSMutableDictionary dictionary];
    }
    
    return self;
}

- (instancetype) initWithTypes:(NSMutableDictionary<NSNumber*, NSNumber*>*) types {
    self = [self init];
    
    if ( self ) {
        for( NSNumber* key in types )
            [self addEventType: [key integerValue] withLossDelay: [types[key] doubleValue]];
    }
    
    return self;
}

- (BOOL) addEvent:(RVLGenericEvent*)event
{
    BOOL result = NO;
    
    NSString* key = [event identifier];
    
    //RVLLogWithType( @"DEBUG", @"RVLDwellManager addEvent: %@", event );
    
    if ( [key length] > 0 ) {
        if ( event.lastSeen == nil )
            event.lastSeen = [NSDate date];
        
        RVLGenericEvent* old = _pendingEvents[key];
        
        if ( old ) {
            old.lastSeen = [NSDate date];
            
            // if it is a beacon then combine with the old one
            if ( [old isKindOfClass: [RVLBeacon class]] ) {
                [(RVLBeacon*)old combineWith: (RVLBeacon*) event];
                
                //RVLLogWithType( @"DEBUG", @"RVLBeacon addEvent combined: %@",  [(RVLBeacon*)old descriptionDetails] );
            }
        }
        else {
            _pendingEvents[key] = event;
            result = YES;
            
            if ( [event isKindOfClass: [RVLBeacon class]] ) {
                [[[Reveal sharedInstance] locationManager] waitForValidLocation:^{
                    RVLBeacon* beacon = (RVLBeacon*) event;
                    beacon.location = [[RVLCoordinate alloc] initWithLocation: [[[Reveal sharedInstance] locationManager] userLocation]];
                }];
            }
        }
    }
    
    [self processPendingEvents];
    
    return result;
}

- (void) addEventType:(RVLEventType)type withLossDelay:(NSTimeInterval)lossDelay
{
    self.eventTypeTimes[[NSNumber numberWithInt: type]] = [NSNumber numberWithDouble: lossDelay];
}

- (void) processPendingEvents {
    BOOL needSave = NO;
    
    @synchronized (self.pendingEvents ) {
        // loop through a copy so we can remove from the original
        for( NSString* key in [NSArray arrayWithArray: [self.pendingEvents allKeys]] ) {
            RVLGenericEvent* event = self.pendingEvents[key];
            
            // it is open unless we close it in this pass
            event.state = RVLStateOpen;
            
            // if the last seen time is non zero then see if it has been long enough to consider it lost
            if ( event.lastSeen ) {
                if ( self.startupTime == nil )
                    self.startupTime = [NSDate date];
                
                NSTimeInterval timeSinceStart = fabs( [self.startupTime timeIntervalSinceNow] );
                NSTimeInterval interval = fabs( [event.lastSeen timeIntervalSinceNow] );
                RVLEventType type = event.eventType;
                NSNumber* threshold = self.eventTypeTimes[[NSNumber numberWithInteger: type]];
                
                // send the event if it has been long enough
                if ( ( interval >= [threshold doubleValue] && self.readyToSend ) && ( timeSinceStart > [threshold doubleValue] ) ) {
                    if ( event.notes == nil )
                        event.notes = [NSString stringWithFormat: @"Not been seen for %.1fs (%@ threshold %.1fs)", interval, [RVLGenericEvent eventType: type], [threshold doubleValue]];
                    else
                        event.notes = [NSString stringWithFormat: @"%@, %.1fs", event.notes, interval];
                    
                    event.state = RVLStateClosed;
                    
                    if ( self.readyToSend )
                        self.readyToSend( event );
                    
                    [self.pendingEvents removeObjectForKey: key];
                    needSave = YES;
                }
            }
        }
    }
    
    // save the infromation in case we reset
    if ( needSave )
        [[[Reveal sharedInstance] beaconManager] storeFoundBeacons];
    
    NSArray<RVLGenericEvent*>* oldItems = [self getOldEvents: [[Reveal sharedInstance] incompleteBeaconSendTime]];
    
    for( RVLGenericEvent* event in oldItems ) {
        if ( self.readyToSend )
            self.readyToSend( event );
    }
}

- (void) memoryWarning
{
    RVLLogWithType( @"STATE", @"Recevied memory warning" );
    Reveal.sharedInstance.memoryWarningInprogress = YES;
    NSArray<RVLGenericEvent*>* oldItems = [self getOldEvents: 0.0];
    for( RVLGenericEvent* event in oldItems ) {
        if ( self.readyToSend )
            self.readyToSend( event );
    }
}

- (NSArray<RVLGenericEvent*>*) getOldEvents:(NSTimeInterval)olderThan {
    NSMutableArray<RVLGenericEvent*>* result = [NSMutableArray array];
    
    @synchronized (self.pendingEvents ) {
        // loop through a copy so we can remove from the original
        for( NSString* key in [NSArray arrayWithArray: [self.pendingEvents allKeys]] ) {
            RVLGenericEvent* event = self.pendingEvents[key];
            
            NSDate* now = [NSDate date];
            NSDate* last = nil;
            
            if ( event.lastUpload == nil ) {
                last = now; // [NSDate dateWithTimeIntervalSince1970: 0.0]; // NOTE: set to "now" if you don't want send on initial sighting
                event.lastUpload = now;
            }
            else
                last = event.lastUpload;
            
            NSTimeInterval diff = fabs( [now timeIntervalSinceDate: last] );
            if ( diff > olderThan ) {
                event.lastUpload = now;
                
                [result addObject: event];
            }
        }
    }
    
    return result;
}


- (NSArray<RVLGenericEvent*>* _Nullable) pendingEvents:(RVLEventType)type {
    NSArray* result = [[[self pendingEvents] allValues] filteredArrayUsingPredicate: [NSPredicate predicateWithFormat: @"eventType==%d", type]];
    
    return [result sortedArrayUsingDescriptors: @[
                                                  [NSSortDescriptor sortDescriptorWithKey: @"lastSeen" ascending: NO],
                                                  [NSSortDescriptor sortDescriptorWithKey: @"discoveryTime" ascending: NO]]];
}

- (void)import:(RVLDwellManager*)other {
    for( NSNumber* key in other.eventTypeTimes )
        [self addEventType: [key integerValue] withLossDelay: [other.eventTypeTimes[key] doubleValue]];
    
    for( NSString* key in other.pendingEvents )
        self.pendingEvents[key] = other.pendingEvents[key];
}

- (void) releaseAll {
    @synchronized (self.pendingEvents ) {
        for( RVLGenericEvent* event in [NSArray arrayWithArray: [self.pendingEvents allValues]] ) {
            if ( event.lastSeen ) {
                
                if ( event.notes == nil )
                    event.notes = @"releaseAll called";
                else
                    event.notes = [NSString stringWithFormat: @"%@, releaseAll called", event.notes];
                
                if ( self.readyToSend )
                    self.readyToSend( event );
                    
                [self.pendingEvents removeObjectForKey: [event identifier]];
            }
        }
    }
}

- (NSString*) description {
    NSMutableString* result = [NSMutableString stringWithString: @"RVLDwellManager types:\n"];
    
    for ( NSNumber* key in self.eventTypeTimes )
        [result appendFormat: @"    %@: %@s\n", key, self.eventTypeTimes[key]];
    
    if ( [self.pendingEvents count] > 0 ) {
    [result appendString: @"Events:\n"];
    
    for( RVLGenericEvent* event in self.pendingEvents.allValues )
        [result appendFormat: @"    %@ (%d %.1fs)\n", event, (int) event.eventType, event.secondsVisible];
    }
    else {
        [result appendString: @"Events: NONE"];
    }
    
    return result;
}

#pragma mark - NSCoding -

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject: self.pendingEvents forKey:@"pendingEvents"];
    [coder encodeObject: self.eventTypeTimes forKey:@"eventTypeTimes"];
}

- (instancetype)initWithCoder:(NSCoder *)decoder
{
    self = [self init];
    
    if (self)
    {
        self.pendingEvents = [decoder decodeObjectForKey:@"pendingEvents"];
        self.eventTypeTimes = [decoder decodeObjectForKey:@"eventTypeTimes"];
        
        RVLLogWithType( @"INFO", @"initWithCoder startup state:\n%@", self );
    }
    
    return self;
}

@end

#pragma mark - Location -

@implementation RVLCoordinate

- (instancetype) initWithLocation:(CLLocation* _Nonnull)location {
    self = [super init];
    
    if ( self ) {
        self.longitude = location.coordinate.longitude;
        self.latitude = location.coordinate.latitude;
        self.floor = location.floor.level;
        self.speed = location.speed;
        self.altitude = location.altitude;
        self.horizontalAccuracy = location.horizontalAccuracy;
        self.timestamp = location.timestamp;
    }
    
    return self;
}

- (NSString*) description {
    return [NSString stringWithFormat: @"Lon: %.6f, Lat: %.6f", self.longitude, self.latitude];
}

#pragma mark JSONAble

- (NSDictionary<NSString*, id>*)jsonDictionary {
    NSMutableDictionary* result = [NSMutableDictionary dictionary];
    NSTimeInterval coordAge = [[NSDate date] timeIntervalSinceDate: self.timestamp];
    NSUInteger coordAgeMS = (NSUInteger)(coordAge * pow(10, 6)); // convert to milliseconds
    NSTimeInterval timeOffset = 999999.99;
    
    if ( self.longitude )
        result[@"lon"] = [NSNumber numberWithDouble: self.longitude];
    
    if ( self.latitude )
        result[@"lat"] = [NSNumber numberWithDouble: self.latitude];
    
    if ( self.timestamp )
        timeOffset = [self.timestamp timeIntervalSinceNow];
    
    if ( coordAgeMS )
        result[@"time"] = [NSNumber numberWithInteger: coordAgeMS];
    
    if ( self.altitude )
        result[@"altitude"] = [NSNumber numberWithDouble: self.altitude];
    
    if ( self.speed )
        result[@"speed"] = [NSNumber numberWithDouble: self.speed];
    
    if ( self.floor )
        result[@"floor"] = [NSNumber numberWithInteger: self.floor];
    
    if ( self.horizontalAccuracy )
        result[@"accuracy"] = [NSNumber numberWithDouble: self.horizontalAccuracy];
    
    if ( timeOffset )
        result[@"age"] = [NSNumber numberWithDouble: timeOffset];
    
    result[@"provider"] = @"gps";
    
    return result;
}

- (void) setJsonDictionary:(NSDictionary<NSString*, id>*)jsonDictionary {
    NSNumber* value = jsonDictionary[@"lon"];
    if ( [value isKindOfClass: [NSNumber class]] )
        self.longitude = [value doubleValue];
    
    value = jsonDictionary[@"lat"];
    if ( [value isKindOfClass: [NSNumber class]] )
        self.latitude = [value doubleValue];
    
    NSAssert( false, @"Incomplete implementation - encode not needed so not implementing" );
}

#pragma mark NSCoding

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeDouble: self.longitude forKey:@"longitude"];
    [coder encodeDouble: self.latitude forKey:@"latitude"];
    [coder encodeObject: self.timestamp forKey:@"timestamp"];
    [coder encodeInteger: self.floor forKey:@"floor"];
    [coder encodeDouble: self.speed forKey:@"speed"];
    [coder encodeDouble: self.altitude forKey:@"altitude"];
    [coder encodeDouble: self.horizontalAccuracy forKey:@"horizontalAccuracy"];
}

- (instancetype)initWithCoder:(NSCoder *)decoder
{
    self = [self init];
    
    if (self)
    {
        self.longitude = [decoder decodeDoubleForKey: @"longitude"];
        self.latitude = [decoder decodeDoubleForKey: @"latitude"];
        self.timestamp = [decoder decodeObjectForKey: @"timestamp"];
        self.floor = [decoder decodeIntegerForKey: @"floor"];
        self.speed = [decoder decodeDoubleForKey: @"speed"];
        self.altitude = [decoder decodeDoubleForKey: @"altitude"];
        self.horizontalAccuracy = [decoder decodeDoubleForKey: @"horizontalAccuracy"];
    }
    
    return self;
}

@end

#pragma mark - Generic event -

@interface RVLGenericEvent ()
{
    __strong NSString* _identifier;
}

@end

@implementation RVLGenericEvent

- (instancetype) init {
    self = [super init];
    
    if ( self ) {
        self.discoveryTime = [NSDate date];
        self.lastSeen = self.discoveryTime;
    }
    
    return self;
}

- (RVLEventType) eventType
{
    return RVLEventTypeUnknown;
}

- (NSString*) identifier {
    if ( _identifier == nil )
        _identifier = @""; // [[NSUUID new] UUIDString];
    
    return _identifier;
}

- (NSTimeInterval) secondsVisible {
    NSTimeInterval result = 0.0;
    
    if ( [self discoveryTime] && [self lastSeen] )
        result = [[self lastSeen] timeIntervalSinceDate: [self discoveryTime]];
    
    return result;
}


+ (NSString*) eventType:(RVLEventType)type {
    NSString* result = nil;
    
    switch ( type ) {
        case RVLEventTypeDwell:
            result = @"Dwell";
            break;
            
        case RVLEventTypeEnter:
            result = @"Enter";
            break;
            
        case RVLEventTypeExit:
            result = @"Exit";
            break;
            
        case RVLEventTypeLocation:
            result = @"Location";
            break;
            
        case RVLEventTypeBeacon:
            result = @"Beacon";
            break;
            
        case RVLEventTypeWiFiEnter:
            result = @"WiFi";
            break;
            
        default:
            result = [NSString stringWithFormat: @"%d", (int) type];
            break;
    }
    
    return result;
}

#pragma mark JSONAble

- (NSDictionary<NSString*, id>*)jsonDictionary {
    NSMutableDictionary* result = [NSMutableDictionary dictionary];
    
    if ( self.discoveryTime )
        result[RVLBeaconDiscoveryTime] = [NSNumber numberWithDouble: [self.discoveryTime timeIntervalSince1970]];
    
    if ( self.lastSeen )
        result[RVLBeaconLastSeenTime] = [NSNumber numberWithDouble: [self.lastSeen timeIntervalSince1970]];
    
    if ( self.secondsVisible > 0.0 )
        result[RVLBeaconDwellTime] = [NSNumber numberWithLong: (long) self.secondsVisible];
    
    if ( self.location ) {
        NSDictionary<NSString*,id>* value = [[self location] jsonDictionary];
        
        if ( [value count] > 0 )
            result[RVLBeaconLocation] = value;
    }
    
#ifdef SEND_NOTES
    if ( self.notes )
        result[RVLBeaconNotes] = self.notes;
#endif
    
    return result;
}

- (void) setJsonDictionary:(NSDictionary<NSString*, id>*)jsonDictionary {
    NSNumber* value = jsonDictionary[RVLBeaconDiscoveryTime];
    if ( [value isKindOfClass: [NSNumber class]] )
        self.discoveryTime = [NSDate dateWithTimeIntervalSince1970: value.doubleValue];
    
    value = jsonDictionary[RVLBeaconLastSeenTime];
    if ( [value isKindOfClass: [NSNumber class]] )
        self.lastSeen = [NSDate dateWithTimeIntervalSince1970: value.doubleValue];
    
    NSString* string = jsonDictionary[RVLBeaconNotes];
    if ( [string isKindOfClass: [NSString class]] )
        self.notes = string;
    
    NSAssert( false, @"Incomplete implementation - encode not needed so not implementing" );
}

#pragma mark NSCoding

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject: self.discoveryTime forKey: @"discoveryTime"];
    [coder encodeObject: self.lastSeen forKey: @"lastSeen"];
    [coder encodeObject: self.location forKey: @"location"];
    [coder encodeObject: self.notes forKey: @"notes"];
}

- (instancetype)initWithCoder:(NSCoder *)decoder
{
    self = [self init];
    
    if (self)
    {
        self.discoveryTime = [decoder decodeObjectForKey: @"discoveryTime"];
        self.lastSeen = [decoder decodeObjectForKey: @"lastSeen"];
        self.location = [decoder decodeObjectForKey: @"location"];
        self.notes = [decoder decodeObjectForKey: @"notes"];
    }
    
    return self;
}

@end

#pragma mark - Startup event

@implementation RVLStartupEvent

- (RVLEventType) eventType
{
    return RVLEventTypeStart;
}

@end

#pragma mark - Reveal location -

@implementation RVLLocationEvent

- (instancetype) init {
    self = [super init];
    
    return self;
}

- (NSString*) identifier {
    return [NSString stringWithFormat: @"%p", self];
}

- (RVLEventType) eventType
{
    return RVLEventTypeLocation;
}

@end

#pragma mark - Beacon Definitions -
// NOTE: These objects would normally be in a seperate file but are placed here so that
//       individual files may be included with out using a framework

@interface RVLBeacon ()


@end

#pragma mark - RVLBeacon -
@implementation RVLBeacon


- (instancetype)initWithUUID:(NSUUID *)uuid
                       major:(NSString *)major
                       minor:(NSString *)minor
                   proximity:(CLProximity)proximity
                    accuracy:(NSNumber *)accuracy
                        rssi:(NSNumber *)rssi
{
    self = [super init];
    if (self)
    {
        _proximityUUID = uuid;
        
        _major = @""; // FIXME -- currently logging beacon regions with no major/minor specified.
        _minor = @"";
        
        if (major)
        {
            _major = major;
        }
        if (minor)
        {
            _minor = minor;
        }
        
        _proximityInteger = proximity;
        _accuracy = accuracy;
        _rssi = rssi;
        self.discoveryTime = [NSDate date];
    }
    
    return self;
}

- (RVLEventType) eventType
{
    return RVLEventTypeBeacon;
}

- (NSString*) proximity
{
    NSString* result = @"unknown";
    
    switch (self.proximityInteger )
    {
        case CLProximityImmediate:
            result = @"immediate";
            break;
            
        case CLProximityNear:
            result = @"near";
            break;
            
        case CLProximityFar:
            result = @"far";
            break;
            
        default:
            break;
    }
    
    return result;
}

- (NSString*) decodedPayload {
    NSMutableString* result = [NSMutableString string];
    
    if ( [self.major length] > 0 )
        [result appendFormat: @"Major: %@", self.major];
    
    if ( [self.minor length] > 0 ) {
        if ( [result length] > 0 )
            [result appendString: @", "];
        [result appendFormat: @"Minor: %@", self.minor];
    }
    
    return result;
}

- (BOOL) readyToSend
{
    BOOL result = YES;
    
    if ( result )
    {
        if ( [self proximityInteger] != CLProximityImmediate )
            result = NO;
    }
    
    return result;
}

- (BOOL) timeoutWaitingToSend
{
    BOOL result = NO;
    
    NSTimeInterval age = fabs( [[self discoveryTime] timeIntervalSinceNow] );
    
    if ( age >= [[[Reveal sharedInstance] beaconManager] proximityTimeout] )
        result = YES;
    
    return result;
}

- (BOOL) combineWith:(RVLBeacon*)beacon
{
    BOOL result = false;
    
    //RVLLogWithType( @"DEBUG", @"RVLBeacon combineWith:\n  Self: %@\n  New: %@", [self descriptionDetails], [beacon descriptionDetails] );
    
    // compare the distance and see if new one ic closer
    if ( [beacon proximityInMeters] < [self proximityInMeters] )
    {
        self.accuracy = beacon.accuracy;
        self.proximityInteger = beacon.proximityInteger;
        self.rssi = beacon.rssi;
    }
    
    // if there is a location then use the newer one
    if ( [beacon location] )
        self.location = [beacon location];
    
    result = true;
    
    return result;
}

- (BOOL) saveWhenReady
{
    BOOL result = false;
    
    if ( [[Reveal sharedInstance] locationManager] )
    {
        // wait until we have a location or have timed out before acting
        [[[Reveal sharedInstance] locationManager] waitForValidLocation: ^
         {
             // if we are close enough then send the beacon, otherwise schedule it for later
             if ( [self readyToSend] || [self timeoutWaitingToSend] )
             {
                 [[[Reveal sharedInstance] beaconManager] processBeacon: self];
             }
             else
             {
                 [[[Reveal sharedInstance] beaconManager] saveIncompeteBeacon: self];
             }
         }];
    }
    else
    {
        // if we are close enough then send the beacon, otherwise schedule it for later
        if ( self.proximityInMeters <= RVL_IMMEDIATE_RADIUS )
        {
            [[[Reveal sharedInstance] beaconManager] processBeacon: self];
            result = true;
        }
        else
        {
            [[[Reveal sharedInstance] beaconManager] saveIncompeteBeacon: self];
        }
    }
    
    return result;
}


- (instancetype)initWithBeacon:(CLBeacon *)beacon
{
    return [self initWithUUID:beacon.proximityUUID
                        major:[NSString stringWithFormat:@"%@", beacon.major]
                        minor:[NSString stringWithFormat:@"%@", beacon.minor]
                    proximity:beacon.proximity
                     accuracy:@(beacon.accuracy)
                         rssi:@(beacon.rssi)];
}

- (instancetype)initWithBeaconRegion:(CLBeaconRegion *)beaconRegion
{
    return [self initWithUUID:beaconRegion.proximityUUID
                        major:[NSString stringWithFormat:@"%@", beaconRegion.major]
                        minor:[NSString stringWithFormat:@"%@", beaconRegion.minor]
                    proximity:0
                     accuracy:@(0)
                         rssi:@(0)];
}

- (instancetype)initWithRawBeacon:(RVLRawBeacon *)beacon
{
    self = [super init];
    if (self)
    {
        _major = @""; // FIXME -- currently logging beacon regions with no major/minor specified.
        _minor = @"";
        
        self.discoveryTime = [NSDate date];
    }
    
    return self;
}

- (double) proximityInMeters
{
    double result = RVL_UNKNOWN_RADIUS;
    
    switch ( self.proximityInteger )
    {
        case CLProximityImmediate:
            result = RVL_IMMEDIATE_RADIUS;
            break;
            
        case CLProximityNear:
            result = RVL_NEAR_RADIUS;
            break;
            
        case CLProximityFar:
            result = RVL_FAR_RADIUS;
            break;
            
        default:
            break;
    }
        
    CGFloat accuracy = [self.accuracy floatValue];
    
    if ( accuracy > 0 )
        result = accuracy;
    
    return result;
}

- (NSString *)identifier
{
    return [RVLBeacon rvlUniqStringWithBeacon: self];
}

+ (NSString *)rvlUniqStringWithBeacon:(RVLBeacon *)beacon
{
    return [NSString stringWithFormat:@"%@-%@-%@", beacon.major, beacon.minor, [beacon.proximityUUID UUIDString]];
}

- (NSString *)type
{
    // apple does not tell us wht type it is so return the generic
    
    return @"iBeacon";
}

- (BOOL)decoded
{
    return ([[self minor] length] + [[self major] length]) > 0;
}

- (void) calculateDistance
{
    double distance = [[[Reveal sharedInstance] distanceCalculator] calculateDistanceWithRSSI: fabs([self.rssi doubleValue])];
    
    if ( distance < 0 )
        self.proximityInteger = CLProximityUnknown;
    else if ( distance < RVL_IMMEDIATE_RADIUS )
        self.proximityInteger = CLProximityImmediate;
    else if ( distance <= RVL_NEAR_RADIUS )
        self.proximityInteger = CLProximityNear;
    else if ( distance <= RVL_FAR_RADIUS)
        self.proximityInteger = CLProximityFar;
    else
        self.proximityInteger = CLProximityUnknown;
    
    self.accuracy = @(distance);
}

- (NSString *)description
{
    NSDate *time = self.sentTime;
    NSString* payloadString = @"";
    
    if (!time)
        time = self.discoveryTime;
    
    if (time)
        return [NSString stringWithFormat:@"%@ %@ %@%@", self.type,
                self.identifier, time, payloadString];
    else
        return [NSString stringWithFormat:@"%@ %@%@", self.type, self.identifier,
                payloadString];
}

- (NSString *)descriptionDetails
{
    NSMutableString* result = [NSMutableString stringWithFormat: @"%@ %@", self.type, self.identifier];
    
    [result appendFormat: @"\n    Visible:        %.1f", self.secondsVisible];
    
    if ( self.discoveryTime )
        [result appendFormat: @"\n    Discovery:      %@", self.discoveryTime];
    
    if ( self.sentTime )
        [result appendFormat: @"\n    Sent:           %@", self.sentTime];
    
    
    [result appendFormat: @"\n    Proximity:      %@ (%d) %.2fm", self.proximity, (int) self.proximityInteger, self.proximityInMeters];
    [result appendFormat: @"\n    RSSI:           %@", self.rssi];
    [result appendFormat: @"\n    UUID:           %@", self.proximityUUID];
    [result appendFormat: @"\n    Major:          %@", self.major];
    [result appendFormat: @"\n    Minor:          %@", self.minor];
    
    return result;
}

#pragma mark JSONAble

- (NSDictionary<NSString*, id>*)jsonDictionary {
    NSMutableDictionary* result = [NSMutableDictionary dictionaryWithDictionary: [super jsonDictionary]];
    
    if ( [self proximityUUID] )
        result[RVLBeaconProximityUUID] = [[self proximityUUID] UUIDString];
    
    if ( [self major] )
        result[RVLBeaconMajor] = [self major];
    
    if ( [self minor] )
        result[RVLBeaconMinor] = [self minor];
    
    if ( [self proximity] )
        result[RVLBeaconProximity] = [self proximity];
    
    result[RVLBeaconProximityInteger] = @([self proximityInteger]);
    
    if ( [self accuracy] )
        result[RVLBeaconAccuracy] = [self accuracy];
    
    if ( [self rssi] )
        result[RVLBeaconRSSI] = [self rssi];
    
    if ( [self identifier] )
        result[RVLBeaconUniqString] = [self identifier];
    
//    if ( [self sentTime] )
//        result[RVLBeaconSentTime] = [self sentTime];
    
    if ( [self type] )
        result[RVLBeaconType] = [self type];
    
    result[@"beacon_uuid"] = [[self proximityUUID] UUIDString];
    if (self.accuracy)
        result[@"beacon_accuracy"] = self.accuracy;
    
    result[@"beacon_rssi"] = self.rssi;
    
    if (self.proximity)
        result[@"beacon_proximity"] = self.proximity;
    
    if (self.type)
        result[@"beacon_type"] = self.type;
    
    switch ( self.state ) {
        case RVLStateOpen:
            result[@"event_state"] = @"OPEN";
            break;
            
        case RVLStateClosed:
            result[@"event_state"] = @"CLOSED";
            break;
            
        default:
            result[@"event_state"] = @"unknown";
            break;
    }
    
    if (self.decoded)
    {
        if ( [self.major length] )
            result[@"beacon_major"] = self.major;
        
        if ( [self.minor length] )
            result[@"beacon_minor"] = self.minor;
    }
    
    return result;
}

- (void) setJsonDictionary:(NSDictionary<NSString*, id>*)jsonDictionary {
    [super setJsonDictionary: jsonDictionary];
    
    NSAssert( false, @"Incomplete implementation - encode not needed so not implementing" );
}

#pragma mark NSCoding

- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder: coder];
    
    [coder encodeObject:self.proximityUUID forKey:@"proximityUUID"];
    [coder encodeObject:self.major forKey:@"major"];
    [coder encodeObject:self.minor forKey:@"minor"];
    [coder encodeInteger: self.proximityInteger forKey:@"proximityInteger"];
    [coder encodeObject:self.accuracy forKey:@"accuracy"];
    [coder encodeObject:self.rssi forKey:@"rssi"];
    [coder encodeObject:self.sentTime forKey:@"sentTime"];
}

- (instancetype)initWithCoder:(NSCoder *)decoder {
    self = [super initWithCoder: decoder];
    
    if (self) {
        self.proximityUUID = [decoder decodeObjectForKey:@"proximityUUID"];
        self.major = [decoder decodeObjectForKey:@"major"];
        self.minor = [decoder decodeObjectForKey:@"minor"];
        self.proximityInteger = [decoder decodeIntegerForKey:@"proximityInteger"];
        self.accuracy = [decoder decodeObjectForKey:@"accuracy"];
        self.rssi = [decoder decodeObjectForKey:@"rssi"];
        self.sentTime = [decoder decodeObjectForKey:@"sentTime"];
    }
    
    return self;
}

@end

#pragma mark - Eddystone object -

@implementation RVLEddyStoneBeacon

- (BOOL) readyToSend {
    BOOL result = NO;
    
        if ( self.url && (self.extendedData[@"namespace"] || self.extendedData[@"instance"]) )
            result = [super readyToSend];
    
    return result;
}

- (BOOL) saveWhenReady {
    return [super saveWhenReady];
}


- (NSString *)type {
    return @"Eddystone";
}

- (NSString*) decodedPayload {
    NSMutableString* result = [NSMutableString stringWithString: [super decodedPayload]];
    NSString* ext = self.extendedData[@"namespace"];
    NSString* instance = self.extendedData[@"instance"];
    
    if ( self.url )
        [result appendFormat: @"URL: %@", self.url];
    
    if ( [ext length] > 0 ) {
        if ( [result length] > 0 )
            [result appendString: @", "];
        [result appendFormat: @"Ext: %@", ext];
    }
    
    if ( [instance length] > 0 ) {
        if ( [result length] > 0 )
            [result appendString: @", "];
        [result appendFormat: @"Instance: %@", instance];
    }
    
    return result;
}

- (NSString *)identifier {
    NSMutableString* result = [NSMutableString string];
    
    NSString* ns = self.extendedData[@"namesspace"];
    NSString* instance = self.extendedData[@"instance"];
    
    if ( ns ) {
        [result appendString: ns];
    
        if ( instance )
            [result appendFormat: @"-%@", instance];
    }
    
    if ( [result length] == 0 )
        result = [NSMutableString stringWithString: [super identifier]];
    
    return result;
}



- (NSString *)ident:(NSInteger)index
{
    NSString *result = nil;
    
    if (index == 0)
        result = [self identifier];
    else
    {
        switch (index)
        {
            case 1:
                result = self.extendedData[@"namespace"];
                break;
                
            case 2:
                result = self.extendedData[@"instance"];
                
            default:
                break;
        }
    }
    
    return result;
}

@end

#pragma mark - Tile object -

@implementation RVLTileBeacon


- (NSString *)type
{
    return @"Tile";
}

@end

#pragma mark - Pebblebee object -

@implementation RVLPebblebeeBeacon


- (NSString *)type
{
    return @"Pebblebee";
}

// this method override is currently only used for debugging and may be removed if needed
- (NSDictionary<NSString*, id>*)jsonDictionary
{
    NSDictionary<NSString*, id>* result = [super jsonDictionary];
    
    //RVLLogWithType( @"DEBUG", @"RVLPebblebeeBeacon jsonDictionary:\n%@", result );
    
    return result;
}

@end

#pragma mark - SecureCast object -

@implementation RVLSecurecastBeacon


- (NSString *)type
{
    return @"SecureCast";
}


- (NSString*) decodedPayload {
    NSMutableString* result = [NSMutableString stringWithString: [super decodedPayload]];
    
    if ( [self.vendorId length] > 0 ) {
        if ( [result length] > 0 )
            [result appendString: @", "];
        [result appendFormat: @"VID: %@", self.vendorId];
    }
    
    if ( self.key != 0 ) {
        if ( [result length] > 0 )
            [result appendString: @", "];
        [result appendFormat: @"Key: %d", (int) self.key];
    }
    
    if ( self.vendorCode != 0 ) {
        if ( [result length] > 0 )
            [result appendString: @", "];
        [result appendFormat: @"VC: %d", (int) self.vendorCode];
    }
    
    return result;
}

@end

#pragma marl - TrackR -

@implementation RVLTrackRBeacon


- (NSString *)type
{
    return @"TrackR";
}

@end

#pragma mark - Bluetooth object -

@interface RevealBluetoothObject () <CBPeripheralDelegate>
@end

@implementation RevealBluetoothObject

- (BOOL)connectable
{
    BOOL result = NO;
    
    NSNumber *num = [self.advertisement objectForKey:@"kCBAdvDataIsConnectable"];
    if ([num isKindOfClass:[NSNumber class]])
        result = YES;
    
    return result;
}

- (instancetype)init
{
    self = [super init];
    
    if (self)
    {
        self.services = [NSMutableDictionary dictionary];
        self.characteristics = [NSMutableDictionary dictionary];
    }
    
    return self;
}

- (NSString *)name
{
    return [[self peripheral] name];
}

- (void)loadCharacteristics:(CBService *)service
{
    [self.peripheral setDelegate:self];
    
    [self.peripheral discoverCharacteristics:nil forService:service];
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error
{
    NSMutableDictionary *svc = self.characteristics[characteristic.service.UUID.UUIDString];
    
    if (svc == nil)
        svc = [NSMutableDictionary dictionary];
    
    svc[characteristic.UUID.UUIDString] = characteristic;
    self.characteristics[characteristic.service.UUID.UUIDString] = svc;
    
    //LOG( @"DEBUG", @"CHAR:   %@/%@: %@ = %@", peripheral.identifier.UUIDString, characteristic.service.UUID.UUIDString, characteristic.UUID.UUIDString, characteristic.value );
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(nullable NSError *)error
{
    for (CBService *svc in peripheral.services)
    {
        if (svc.characteristics)
            [self peripheral:peripheral didDiscoverCharacteristicsForService:svc error:nil]; //already discovered characteristic before, DO NOT do it again
        else
        {
            [peripheral discoverCharacteristics:nil
                                     forService:svc]; //need to discover characteristics
            
            // NOTE: discover included services disabled because it does not provide useful
            //       information from our perspective since we are already polling the
            //       primary services
            //[peripheral discoverIncludedServices: nil forService: svc];
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverIncludedServicesForService:(CBService *)service error:(nullable NSError *)error
{
    //LOG( @"DEBUG", @"Discovered included services for %@: %@", peripheral.identifier.UUIDString, service.UUID );
    
    NSMutableDictionary *svc = self.characteristics[service.UUID.UUIDString];
    
    if (svc == nil)
        svc = [NSMutableDictionary dictionary];
    
    for (CBCharacteristic *characteristic in service.characteristics)
    {
        NSString *key = [NSString stringWithFormat:@"INC:%@", characteristic.UUID.UUIDString];
        svc[key] = characteristic;
    }
    
    self.characteristics[service.UUID.UUIDString] = svc;
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(nullable NSError *)error
{
    //NSMutableString* chars = [NSMutableString string];
    
    for (CBCharacteristic *c in service.characteristics)
    {
        //[chars appendFormat: @"\n    %@ (%lX)=%@", c.UUID.UUIDString, (long) c.properties, c.value];
        [peripheral readValueForCharacteristic:c];
    }
    
    //LOG( @"DEBUG", @"Discovered characteristic for %@: %@: %@", peripheral.identifier.UUIDString, service.UUID.UUIDString, chars );
}

+ (NSString *)serviceName:(NSString *)serviceName
{
    NSString *result = serviceName;
    
    if ([serviceName isEqualToString:@"kCBAdvDataIsConnectable"])
        result = @"C";
    else if ([serviceName isEqualToString:@"kCBAdvDataLocalName"])
        result = @"N";
    else if ([serviceName isEqualToString:@"kCBAdvDataServiceData"])
        result = @"D";
    else if ([serviceName isEqualToString:@"kCBAdvDataManufacturerData"])
        result = @"AM";
    else if ([serviceName isEqualToString:@"kCBAdvDataServiceUUIDs"])
        result = @"SU";
    
    return result;
}

+ (NSString *)data:(id)data
{
    NSString *result = nil;
    
    if ([data isKindOfClass:[NSDictionary class]])
    {
        NSMutableString *str = [NSMutableString string];
        
        for (NSString *key in data)
        {
            if ([str length])
                [str appendString:@","];
            [str appendFormat:@"%@=%@", key, data[key]];
        }
        
        result = str;
    }
    else if ([data isKindOfClass:[NSArray class]])
    {
        NSMutableString *str = [NSMutableString string];
        
        for (NSString *key in data)
        {
            if ([str length])
                [str appendString:@","];
            [str appendFormat:@"%@", key];
        }
        
        result = str;
    }
    else
    {
        result = [NSString stringWithFormat:@"%@", data];
    }
    
    return result;
}

@end

#pragma mark - Raw Beacon -

@implementation RVLRawBeacon

- (instancetype) init
{
    self = [super init];
    
    if ( self )
    {
        self.discoveryTime = [NSDate date];
    }
    
    return self;
}

- (NSString *)identifier
{
    // if a proximity UUID is present then use it
    if ([[self proximityUUID] UUIDString])
        return [[self proximityUUID] UUIDString];
    
    // build it from the deciphered data
    NSMutableString *result = [NSMutableString new];
    
    NSString* ns = self.extendedData[@"namespace"];
    
    if ( ns  )
        [result appendFormat: @"%@", ns];
    else if ( self.vendorId )
    {
        [result appendString: self.vendorId];
    }
    else if (self.vendorCode && self.key )
    {
        [result appendFormat:@"%04X-%X", (int)self.vendorCode, (int)self.key];
        
        if ( self.local )
            [result appendFormat:@"%X", (int)self.local];
    }
    else
    {
        if (self.bluetoothIdentifier)
            [result appendFormat:@"%@", [self.bluetoothIdentifier UUIDString]];
        else
            result = [NSMutableString stringWithString: [super identifier]];
    }
    
    return result; // Multiple returns
}


- (NSString *)type
{
    NSString *result = nil;
    
    result = self.vendorName;
    if ([result length] == 0)
        result = [NSString stringWithFormat:@"Type-%ld", (long) self.vendorCode];
    
    return result;
}

- (NSString *)ident:(NSInteger)index
{
    NSString *result = nil;
    
    if (index == 0)
        result = [self identifier];
    else
    {
        switch (index)
        {
            case 1:
                if ( self.key )
                    result = [NSString stringWithFormat:@"%ld", (long)self.key];
                else
                    result = nil;
                break;
                
            case 2:
                if ( self.local )
                    result = [NSString stringWithFormat:@"%ld", (long)self.local];
                else
                    result = @"";
                
            default:
                break;
        }
    }
    
    return result;
}

- (BOOL) combineWith:(RVLBeacon*)other
{
    BOOL result = false;
    
    if ( [other isKindOfClass: [RVLRawBeacon class]] ) {
        RVLRawBeacon* beacon = (RVLRawBeacon*) other;
        
        // copy the URL if it has been decoded
        if ( [beacon url] )
            [self setUrl: [beacon url]];
        
        // get any extended data fields if they are present
        if ( [[beacon extendedData] count] > 0 ) {
            if ( [self extendedData] == nil )
                [self setExtendedData: [NSMutableDictionary dictionaryWithDictionary: [beacon extendedData]]];
            else
                [[self extendedData] addEntriesFromDictionary: [beacon extendedData]];
        }
        
        if ( [beacon payload] )
            [self setPayload: [beacon payload]];
        
        if ( [beacon services] )
            [self setServices: [beacon services]];
        
        if ( [beacon uuids] )
            [self setUuids: [beacon uuids]];
        
        if ( [beacon bluetooth] )
            self.bluetooth = [beacon bluetooth];
        
        if ( [beacon advertisement] )
            self.advertisement = [beacon advertisement];
        
        result = true;
    }
    
    return result;
}

- (NSString *)description
{
    NSDate *time = self.sentTime;
    NSString* payloadString = @"";
    
    if ( [[self payload] isKindOfClass: [NSData class]] )
    {
        payloadString = [NSString stringWithFormat: @" Payload: %@", [self payload]];
    }
    
    if (!time)
        time = self.discoveryTime;
    
    if (time)
        return [NSString stringWithFormat:@"%@ %@ %@%@", self.type,
                self.identifier, time, payloadString];
    else
        return [NSString stringWithFormat:@"%@ %@%@", self.type, self.identifier,
                payloadString];
}

- (NSString *)descriptionDetails
{
    NSMutableString* result = [NSMutableString stringWithString: [super descriptionDetails]];
    
    [result appendFormat: @"\n    Payload:          %@", self.payloadString];
    [result appendFormat: @"\n    URL:              %@", self.url];
    [result appendFormat: @"\n    Vendor name:      %@", self.vendorName];
    [result appendFormat: @"\n    Vendor code:      %d", (int)self.vendorCode];
    [result appendFormat: @"\n    Vendor ID:        %@", self.vendorId];
    [result appendFormat: @"\n    Key:              %d", (int)self.key];
    [result appendFormat: @"\n    Local:            %d", (int)self.local];
    [result appendFormat: @"\n    Complete:         %d", self.complete];
    
    return result;
}

#pragma mark JSONAble

- (NSDictionary<NSString*, id>*)jsonDictionary {
    NSMutableDictionary* result = [NSMutableDictionary dictionaryWithDictionary: [super jsonDictionary]];
    
    if ( [self key]  )
        result[RVLBeaconKey] = @( [self key] );
    
    if ( [self local]  )
        result[RVLBeaconLocal] = @( [self local] );

    result[@"beacon_rssi"] = self.rssi;
    
    if ( self.vendorCode )
        result[@"beacon_vendor"] = @(self.vendorCode);
    
    NSString* venKey = nil;
    
    if ( [self.vendorId length] )
    {
        NSScanner* scanner = [NSScanner scannerWithString: self.vendorId];
        
        unsigned long long value;
        [scanner scanHexLongLong: &value];
        
        if ( value )
        {
            venKey = [NSString stringWithFormat: @"%llx", value];
            result[@"beacon_vendor_key"] = @(value);
        }
    }
    else
    {
        if ( self.key )
        {
            result[@"beacon_vendor_key"] = @(self.key);
            venKey = [NSString stringWithFormat: @"%lx", (long) self.key];
        }
        else
            venKey = self.identifier;
    }
    
    if (self.payload )
        result[@"beacon_payload"] = self.payloadString;
    
    if (self.url)
        result[@"beacon_url"] = [NSString stringWithFormat:@"%@", self.url];
    
    if ( [venKey length] )
        result[@"beacon_uuid"] = venKey;
    else if ([self.uuids count] > 0)
        result[@"beacon_uuid"] = [NSString stringWithFormat:@"%@", self.uuids.firstObject];
    
    if ( [[self bluetooth] name] )
        result[@"name"] = self.bluetooth.name;
    
    return result;
}

- (NSString *)payloadString
{
    NSString *result = nil;
    
    if (self.payload)
        result = [self.payload base64EncodedStringWithOptions:0];
    
    return result;
}

- (NSTimeInterval) age
{
    NSTimeInterval result = 0.0;
    
    if ( [self discoveryTime] )
    {
        result = [[self discoveryTime] timeIntervalSinceNow] * -1.0;
    }
    
    return result;
}

#pragma mark NSCoding

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder: coder];
    
    [coder encodeObject:self.vendorName forKey:@"vendorName"];
    [coder encodeInteger:self.vendorCode forKey:@"vendorCode"];
    [coder encodeInteger:self.key forKey:@"key"];
    [coder encodeInteger:self.local forKey:@"local"];
    [coder encodeObject:self.payload forKey:@"payload"];
    [coder encodeObject:self.bluetoothIdentifier forKey:@"bluetoothIdentifier"];
    [coder encodeObject:self.url forKey:@"url"];
    [coder encodeBool:self.complete forKey:@"complete"];
    [coder encodeObject: self.extendedData forKey: @"extendedData"];
}

- (instancetype)initWithCoder:(NSCoder *)decoder
{
    self = [super initWithCoder: decoder];
    
    if (self)
    {
        self.vendorName = [decoder decodeObjectForKey:@"vendorName"];
        self.vendorCode = [decoder decodeIntegerForKey:@"vendorCode"];
        self.key = [decoder decodeIntegerForKey:@"key"];
        self.local = [decoder decodeIntegerForKey:@"local"];
        self.payload = [decoder decodeObjectForKey:@"payload"];
        self.rssi = [decoder decodeObjectForKey:@"rssi"];
        self.bluetoothIdentifier = [decoder decodeObjectForKey:@"bluetoothIdentifier"];
        self.url = [decoder decodeObjectForKey:@"url"];
        self.complete = [decoder decodeBoolForKey:@"complete"];
        self.discoveryTime = [decoder decodeObjectForKey:@"discoveryTime"];
        self.extendedData = [decoder decodeObjectForKey:@"extendedData"];
    }
    
    return self;
}

@end

#pragma mark - Event Cache -

@implementation EventCache

- (instancetype) init
{
    self = [super init];
    
    if ( self )
    {
        self.events = [NSMutableArray array];
        self.maxCachedEvents = 50;
        self.maxCachedEventsOverrun = self.maxCachedEvents * 10;
        self.idleTimeout = 1 * 60;
    }
    
    return self;
}

- (void) addEvent:(RVLGenericEvent* _Nonnull)event
{
    @synchronized ( self )
    {
        [[self events] addObject: event];
        
        while ( [[self events] count] > [self maxCachedEventsOverrun] )
            [[self events] removeObjectAtIndex: 0];
    }
    
    dispatch_async( dispatch_get_main_queue(), ^
            {
                [[self idleTimer] invalidate];
                self.idleTimer = nil;
                
                if ( [[self events] count] >= [self maxCachedEvents] )
                    [self flushEvents];
                else
                    self.idleTimer = [NSTimer scheduledTimerWithTimeInterval: self.idleTimeout
                                                                      target: self
                                                                    selector: @selector(timerExpired)
                                                                    userInfo: nil
                                                                     repeats: NO];
            });
    
}


- (void) iterate:(void (^ _Nonnull)(RVLGenericEvent*))block {
    for( RVLGenericEvent* event in [self events] ) {
        if ( block )
            block( event );
    }
}

- (void) timerExpired {
    self.idleTimer = nil;
    [self flushEvents];
}

- (NSInteger) countOfEventsOfType:(RVLEventType)typeToGet {
    NSInteger result = 0;
    
    if ( [self events] ) {
        NSArray* array = nil;
        
        @synchronized ( self ) {
            array = [NSArray arrayWithArray: _events];
        }
        
        for( RVLGenericEvent* event in array )
            if ( event.eventType == typeToGet )
                result++;
    }
    
    return result;
}

- (NSMutableArray<RVLGenericEvent*>*) getEventsOfType:(RVLEventType)typeToGet {
    NSMutableArray<RVLGenericEvent*>* result = [NSMutableArray arrayWithCapacity: [[self events] count]];
    
    @synchronized ( self ) {
        if ( [self events] ) {
            for( RVLGenericEvent* event in _events )
                if ( event.eventType == typeToGet )
                    [result addObject: event];
            
            for( RVLGenericEvent* event in result )
                [[self events] removeObject: event];
        }
    }
    
    return result;
}

- (NSMutableArray<RVLGenericEvent*>*) getEventsAndClear
{
    NSMutableArray<RVLGenericEvent*>* result = [NSMutableArray arrayWithCapacity: [[self events] count]];
    
    @synchronized ( self )
    {
        if ( [self events] )
        {
            [result addObjectsFromArray: [self events]];
            [[self events] removeAllObjects];
        }
    }
    
    return result;
}

- (void) flushEvents
{
    NSMutableArray<RVLGenericEvent*>* eventsList = nil;
    
    if ( ![[Reveal sharedInstance] inBackground] || [[Reveal sharedInstance] batchBackgroundSend] )
        eventsList = [self getEventsAndClear];
    else if ( [self countOfEventsOfType: RVLEventTypeEnter] )
        eventsList = [self getEventsAndClear];
        
    if ( [eventsList count] ) {
        if ( [self batchReady] ) {
            self.batchReady( eventsList );
        }
    }
}

@end

// How to apply color formatting to your log statements:
//
// To set the foreground color:
// Insert the ESCAPE into your string, followed by "fg124,12,255;" where r=124, g=12, b=255.
//
// To set the background color:
// Insert the ESCAPE into your string, followed by "bg12,24,36;" where r=12, g=24, b=36.
//
// To reset the foreground color (to default value):
// Insert the ESCAPE into your string, followed by "fg;"
//
// To reset the background color (to default value):
// Insert the ESCAPE into your string, followed by "bg;"
//
// To reset the foreground and background color (to default values) in one operation:
// Insert the ESCAPE into your string, followed by ";"

#define XCODE_COLORS_ESCAPE @"\033["

#define XCODE_COLORS_RESET_FG  XCODE_COLORS_ESCAPE @"fg;" // Clear any foreground color
#define XCODE_COLORS_RESET_BG  XCODE_COLORS_ESCAPE @"bg;" // Clear any background color
#define XCODE_COLORS_RESET     XCODE_COLORS_ESCAPE @";"   // Clear any foreground or background color

void RVLLog(NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    
    NSString *formattedString = [[NSString alloc] initWithFormat:format arguments:arguments];
    [[RVLDebugLog sharedLog] log:formattedString];
    
    va_end(arguments);
}

void RVLLogWithType(NSString* type, NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    
    NSString *formattedString = [[NSString alloc] initWithFormat:format arguments:arguments];
    [[RVLDebugLog sharedLog] log:formattedString ofType: type];
    
    va_end(arguments);
}

void RVLLogVerbose(NSString* type, NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    
    NSString *formattedString = [[NSString alloc] initWithFormat:format arguments:arguments];
    [[RVLDebugLog sharedLog] logVerbose: formattedString ofType: type];
    
    va_end(arguments);
}

@implementation RVLDebugLog

+ (RVLDebugLog *) sharedLog
{
    static RVLDebugLog *_mgr;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^
                  {
                      _mgr = [[RVLDebugLog alloc] init];
                  });
    
    return _mgr;
}

- (void) log:(NSString *)aString
{
    [self log: aString ofType: @"DEBUG"];
}

- (void) log:(NSString *)aString ofType:(NSString*)type
{
    NSString* theType = type.lowercaseString;
    
    if ( [theType isEqualToString: @"error"] )
        [self logString: aString withRed: 255 green: 0 blue: 0 ofType: type];
    else if ( [theType isEqualToString: @"warning"] )
        [self logString: aString withRed: 238 green: 238 blue: 0 ofType: type];
    else if ( [theType isEqualToString: @"debug"] )
        [self logString: aString withRed: 0 green: 255 blue: 0 ofType: type];
    else if ( [theType isEqualToString: @"standout"] )
        [self logString: aString withRed: 255 green: 128 blue: 0 ofType: type];
    else if ( [theType isEqualToString: @"info"] )
        [self logString: aString withRed: 152 green: 225 blue: 255 ofType: type];
    else if ( [theType isEqualToString: @"comm"] )
        [self logString: aString withRed: 255 green: 0 blue: 255 ofType: type];
    else
        [self logString: aString withRed: 64 green: 192 blue: 64 ofType: type];
}

- (void) logVerbose:(NSString *)aString ofType:(NSString*)type
{
    if ( self.verbose )
        [self log: aString ofType: type];
}

- (void) logString:(NSString *)aString withRed:(NSInteger)red green:(NSInteger)green blue:(NSInteger)blue ofType:(NSString*)type
{
    if (self.enabled)
    {
        if ( self. useColor && red >= 0 )
            NSLog(XCODE_COLORS_ESCAPE @"fg%d,%d,%d;" @"Reveal [%@]: %@" XCODE_COLORS_RESET, (int)red, (int)green, (int)blue, type, aString );
        else
            NSLog(@"Reveal [%@]: %@", type, aString);
        
        if ( self.logMirror )
            self.logMirror( type, aString, [UIColor colorWithRed: red /255.0 green: green /255.0 blue: blue /255.0 alpha: 1.0] );
    }
}


@end

#pragma mark - Status object -

@implementation RVLStatus

- (id _Nonnull ) init: (NSString*_Nonnull)name {
    self = [super init];
    
    if ( self ) {
        self.name = name;
        self.message = [NSString stringWithFormat: @"%@ awaiting first use", name];
    }
    
    return self;
}

- (id _Nonnull ) init: (NSString*_Nonnull)name value:(NSInteger)value {
    self = [super init];
    
    if ( self ) {
        self.name = name;
        self.value = value;
    }
    
    return self;
}

// set a new state
- (void) updateValue:(NSInteger)value
             message:(NSString* _Nullable)message
{
    if ( self.time ) {
        // TODO: Save in list for later retrieval
    }
    
    self.time = [NSDate date];
    self.value = value;
    self.message = message;
}

@end

@implementation RevealPDU

- (instancetype) init {
    self = [super init];
    
    return self;
}

- (instancetype _Nonnull) initWith:(id _Nonnull )data ofType:(NSInteger) type {
    self = [super init];
    
    if ( self ) {
        self.type = type;
        [self addData: data];
    }
    
    return self;
}

+ (NSArray<RevealPDU*>* _Nonnull) PDUList:(NSData* _Nonnull)data
{
    NSMutableArray<RevealPDU*>* result = [NSMutableArray new];
    NSInteger dataSize = data.length;
    
    char *bytes = (char*) data.bytes;
    NSInteger current = 0;
    BOOL done = NO;
    
    while( !done ) {
        if ( current >= dataSize )
            done = YES;
        else {
            NSInteger length = *(bytes + current) & 0xff;
            
            if ( ( current + length ) > dataSize )
                done = YES;
            else if ( length == 0 )
                done = YES;
            else {
                RevealPDU* item = [RevealPDU new];
                item.length = length - 1;
                item.type = *(bytes + current + 1) & 0xff;
                item.data = [NSData dataWithBytes: (bytes + current + 2) length: item.length];
                
                [result addObject: item];
                
                current = current + length;
            }
        }
    }
    
    return result;
}

+ (NSArray<RevealPDU*>* _Nonnull) PDUListFromServiceData:(NSDictionary * _Nonnull)services {
    NSMutableArray<RevealPDU*>* result = [NSMutableArray new];
    
    if ( services ) {
        for( NSString* key in services ) {
            NSData* value = services[key];
            
            if ( [value isKindOfClass: [NSData class]] ) {
                NSArray<RevealPDU*>* pdu = [RevealPDU PDUList: value];
                
                if ( [pdu count] > 0 )
                    [result addObjectsFromArray: pdu];
            }
        }
    }
    
    return result;
}

+ (NSArray<RevealPDU*>* _Nonnull) PDUListFromAdvertisingData:(NSDictionary * _Nonnull)advertisement {
    NSMutableArray<RevealPDU*>* result = [NSMutableArray new];
    
    if ( advertisement ) {
        for( NSString* key in advertisement ) {
            id value = advertisement[key];
            
            NSInteger type = [RevealPDU PDUFrom: key];
            
            if ( type != 0 ) {
                RevealPDU* pdu = [[RevealPDU alloc] initWith: value ofType: type];
                
                if ( [pdu length] > 0 )
                    [result addObject: pdu];
            }
        }
    }
    
    return result;
}

+ (NSArray<RevealPDU*>* _Nonnull) PDUListFromServiceData:(NSDictionary * _Nonnull)services andDavertisingData:(NSDictionary * _Nonnull)advertisement {
    NSMutableArray<RevealPDU*>* result = [NSMutableArray new];
    
    NSArray<RevealPDU*>* pdus = [RevealPDU PDUListFromServiceData: services];
    if ( [pdus count] > 0 )
        [result addObjectsFromArray: pdus];
    
    pdus = [RevealPDU PDUListFromAdvertisingData: advertisement];
    if ( [pdus count] > 0 )
        [result addObjectsFromArray: pdus];
    
    return result;
}

+ (NSInteger) PDUFrom:(NSString*)value {
    NSInteger result = 0;
    
    if ( [value isEqualToString: @"kCBAdvDataLocalName"] )
        result = REVEAL_PDU_TYPE_COMPLETE_NAME;
    else if ( [value isEqualToString: @"kCBAdvDataServiceUUIDs"] )
        result = 0;
    else if ( [value isEqualToString: @"kCBAdvDataManufacturerData"] )
        result = REVEAL_PDU_TYPE_MANUFACTURER_SPECIFIC_DATA;
    else if ( [value isEqualToString: @"kCBAdvDataTxPowerLevel"] )
        result = REVEAL_PDU_TYPE_TX_POWER;
    else if ( [value isEqualToString: @"kCBAdvDataIsConnectable"] )
        result = 0;
    else {
        result = -1;
        
        RVLLogWithType( @"DEBUG", @"   --------   Unknown apple PDU type: %@   ---------", value );
    }
    
    return result;
}

- (BOOL) addData:(id _Nonnull)value {
    BOOL result = true;
    
    if ( [value isKindOfClass: [NSData class]] )
        self.data = value;
    else if ( [value isKindOfClass: [NSString class]] )
        self.data = [(NSString*)value dataUsingEncoding: NSASCIIStringEncoding];
    else if ( [value isKindOfClass: [NSNumber class]] ) {
        // TODO: assume the number is integer for now this may need to be extended later
        NSInteger number = [(NSNumber*)value integerValue];
        
        self.data = [NSData dataWithBytes: &number length: sizeof(number)];
    }
    else
        result = false;
    
    self.length = [self.data length];
    
    
    return result;
}

- (NSString* _Nonnull) typeName {
    NSString* result;
    NSString* mfgName;
    
    switch( [self type] ) {
        case REVEAL_PDU_TYPE_FLAGS:
            result = @"FLAGS";
            break;
            
        case REVEAL_PDU_TYPE_UUID16_INCOMPLETE:
            result = @"UUID16-I";
            break;
            
        case REVEAL_PDU_TYPE_UUID16:
            result = @"UUID16";
            break;
            
        case REVEAL_PDU_TYPE_UUID32_INCOMPLETE:
            result = @"UUID32-I";
            break;
            
        case REVEAL_PDU_TYPE_UUID128:
            result = @"UUID128";
            break;
            
        case REVEAL_PDU_TYPE_SHORT_NAME:
            result = @"NAME-S";
            break;
            
        case REVEAL_PDU_TYPE_COMPLETE_NAME:
            result = @"NAME";
            break;
            
        case REVEAL_PDU_TYPE_TX_POWER:
            result = @"TX";
            break;
            
        case REVEAL_PDU_TYPE_SERVICE_DATA:
            result = @"SERVICE-DATA";
            break;
            
        case REVEAL_PDU_TYPE_MANUFACTURER_SPECIFIC_DATA:
            mfgName = [self manufacturerName: [self int16at: 0]];
            result = [NSString stringWithFormat: @"DATA-%@", mfgName];
            break;
            
        default:
            result = [NSString stringWithFormat: @"PDU-(%d)", (int) [self type]];
            break;
    }
    
    return result;
}

- (NSString* _Nonnull) manufacturerName:(NSInteger)code {
    NSString* result = nil;
    
    switch ( code ) {
        case 6:
            result = @"Microsoft";
            break;
            
        case 76:
            result = @"Apple, Inc.";
            break;
            
        case 138:
            result = @"Jawbone";
            break;
            
        case 140:
            result = @"Gimbal, Inc.";
            break;
            
        case 181:
            result = @"Swirl";
            break;
            
        case 272:
            result = @"Nippon Seiki Co. Ltd.";
            break;
            
        case 280:
            result = @"Radius Networks, Inc.";
            break;
            
        case 301:
            result = @"Sony";
            break;
            
        case 349:
            result = @"Estimote, Inc.";
            break;
            
        default:
            result = [NSString stringWithFormat: @"MFG-%d", (int) code];
            break;
    }
    
    return result;
}

- (int) int8at:(NSInteger) index {
    int result = 0;
    
    if ( [[self data] length] > index ) {
        char *bytes = (char*) [[self data] bytes];
        
        result = *(bytes + index) & 0xff;
    }
    
    return result;
}

- (int) int16at:(NSInteger) index {
    return ([self int8at: index + 1]<<8) + [self int8at: index];
}

- (int) int16Flippedat:(NSInteger) index {
    return ([self int8at: index]<<8) + [self int8at: index + 1];
}

- (id) objectAtIndexedSubscript:(NSInteger)idx {
    return [NSNumber numberWithInt: [self int8at: idx]];
}

- (NSString* _Nonnull) string {
    return [self stringAt: 0];
}

- (NSString* _Nonnull) stringAt:(NSInteger)start {
    return [self stringAt: start length: [self length]];
}

- (NSString* _Nonnull) stringAt:(NSInteger)start length:(NSInteger)length {
    NSMutableString* result = [NSMutableString string];
    
    if ( [[self data] length] > 0 ) {
        char *bytes = (char*) [[self data] bytes];
        
        for( NSInteger index=0 ; index<length ; index++ )
            [result appendFormat: @"%c", bytes[start+index] & 0xff];
    }
    
    return result;
}

- (NSData* _Nonnull) dataAt:(NSInteger)start length:(NSInteger)length {
    NSData* result = [NSData data];
    
    if ( [[self data] length] > 0 ) {
        char *bytes = (char*) [[self data] bytes];
        
        result = [NSData dataWithBytes: bytes + start length: length];
    }
    
    return result;
}

- (NSString* _Nonnull) hex {
    return [self hexAt: 0];
}

- (NSString* _Nonnull) hexAt:(NSInteger)start {
    return [self hexAt: start length: [self length]];
}

- (NSString* _Nonnull) hexAt:(NSInteger)start length:(NSInteger)length {
    NSMutableString* result = [NSMutableString string];
    
    if ( [[self data] length] > 0 ) {
        char *bytes = (char*) [[self data] bytes];
        
        for( NSInteger index=0 ; index<length ; index++ )
            [result appendFormat: @"%02x", bytes[start+index] & 0xff];
    }
    
    return result;
}

- (NSString*) description {
    NSString* text;
    
    switch ( [self type] ) {
        case REVEAL_PDU_TYPE_SHORT_NAME:
        case REVEAL_PDU_TYPE_COMPLETE_NAME:
            text = [self string];
            break;
            
        default:
            text = [self hex];
            break;
    }
    
    return [NSString stringWithFormat: @"%@: %@", [self typeName], text];
}

@end
