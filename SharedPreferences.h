#ifndef SHAREDPREFERENCES_H
#define SHAREDPREFERENCES_H

#import <Foundation/Foundation.h>

@interface SharedPreferences : NSObject

+ (BOOL)isTweakEnabled;
+ (void)setTweakEnabled:(BOOL)enabled;

+ (NSString *)serverURL;
+ (void)setServerURL:(NSString *)url;

+ (void)synchronize;

@end

#endif /* SHAREDPREFERENCES_H */
