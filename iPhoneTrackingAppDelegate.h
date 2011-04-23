//
//  iPhoneTrackingAppDelegate.h
//  iPhoneTracking
//
//  Created by Pete Warden on 4/15/11.
//

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface iPhoneTrackingAppDelegate : NSObject <NSApplicationDelegate> {
  NSWindow *window;
  WebView *webView;
  WebScriptObject* scriptObject;
    
    NSString* dbFilePath;
    NSString* deviceName;
}

- (void)loadLocationDB;
- (BOOL)tryToLoadLocationDB:(NSString*) locationDBPath forDevice:(NSString*) deviceName;
- (void) incrementBuckets:(NSMutableDictionary*)buckets forKey:(NSString*)key;

@property (assign) IBOutlet NSWindow *window;
@property (assign) IBOutlet WebView *webView;
- (IBAction)openAboutPanel:(id)sender;
- (IBAction)exportGPX:(id)sender;

@end
