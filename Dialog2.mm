//
//  Dialog2.mm
//  Dialog2
//
//  Created by Ciaran Walsh on 19/11/2007.
//

#import "Dialog2.h"
#import "TMDCommand.h"
#import "CLIProxy.h"

@protocol TMPlugInController
- (CGFloat)version;
@end

@interface Dialog2 : NSObject
{
	CFMessagePortRef _port;
}
- (id)initWithPlugInController:(id <TMPlugInController>)aController;
- (void)connectFromClientWithOptions:(id)options;
@end

// Runs on the main run loop; the request is dispatched after the callback returns so the tool never waits on the command.
static CFDataRef DialogServerCallback (CFMessagePortRef port, SInt32 messageID, CFDataRef data, void* info)
{
	if(data)
	{
		id options = [NSPropertyListSerialization propertyListWithData:(__bridge NSData*)data options:NSPropertyListImmutable format:nil error:nil];
		if([options isKindOfClass:[NSDictionary class]])
			[(__bridge Dialog2*)info connectFromClientWithOptions:options];
	}
	return NULL;
}


@implementation Dialog2

- (id)initWithPlugInController:(id <TMPlugInController>)aController
{
	NSApp = NSApplication.sharedApplication;
	if(self = [self init])
	{
		NSString* portName = [NSString stringWithFormat:@"%@.%d", kDialogServerConnectionName, getpid()];
		CFMessagePortContext context = { 0, (__bridge void*)self, NULL, NULL, NULL };
		_port = CFMessagePortCreateLocal(kCFAllocatorDefault, (__bridge CFStringRef)portName, &DialogServerCallback, &context, NULL);
		if(_port)
		{
			CFRunLoopSourceRef source = CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, _port, 0);
			CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
			CFRelease(source);
		}

		if(!_port)
			NSLog(@"couldn't setup dialog server."), NSBeep();
		else if(NSString* path = [[NSBundle bundleForClass:[self class]] pathForResource:@"tm_dialog2" ofType:nil])
		{
			char* oldDialog = getenv("DIALOG");
			if(oldDialog == NULL || ![@(oldDialog) isEqualToString:path])
			{
				if(oldDialog)
					setenv("DIALOG_1", oldDialog, 1);
				setenv("DIALOG", [path UTF8String], 1);
			}

			setenv("DIALOG_PORT_NAME", [portName UTF8String], 1);
		}
	}

	return self;
}

- (void)dispatch:(id)options
{
	// The proxy owns the tool's FIFOs and the tool waits for them to close. Release it here rather than at the next
	// drain of the outer pool, which a command that runs a nested event loop (the tooltip) can postpone indefinitely.
	@autoreleasepool {
		CLIProxy* interface = [CLIProxy proxyWithOptions:options];

		NSString* command = [interface numberOfArguments] <= 1 ? @"help" : [interface argumentAtIndex:1];

		if(id target = [TMDCommand objectForCommand:command])
				[target performSelector:@selector(handleCommand:) withObject:interface];
		else	[interface writeStringToError:@"unknown command, try help.\n"];
	}
}

- (void)connectFromClientWithOptions:(id)options
{
	[self performSelector:@selector(dispatch:) withObject:options afterDelay:0.0];
}

@end
/*
echo '{ menuItems = ({title = 'foo';});}' | "$DIALOG" menu
*/
