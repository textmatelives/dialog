//
//  TMDHTMLTips.mm
//
//  Created by Ciarán Walsh on 2007-08-19.
//

#import "TMDHTMLTips.h"
#import <WebKit/WebKit.h>

/*
"$DIALOG" tooltip --text '‘foobar’'
"$DIALOG" tooltip --html '<h1>‘foobar’</h1>'
*/

@interface TMDHTMLTip () <WKNavigationDelegate>
{
	WKWebView* webView;

	NSSize contentSize;    // measured once the page has loaded

	NSDate* didOpenAtDate; // ignore mouse moves for the next second
	NSPoint mousePositionWhenOpened;
}
- (void)setContent:(NSString*)content transparent:(BOOL)transparent;
- (void)runUntilUserActivity:(id)sender;
@end

@implementation TMDHTMLTip
// ==================
// = Setup/teardown =
// ==================
+ (void)showWithContent:(NSString*)content atLocation:(NSPoint)point transparent:(BOOL)transparent
{
	TMDHTMLTip* tip = [TMDHTMLTip new];
	[tip setFrameTopLeftPoint:point];
	[tip setContent:content transparent:transparent]; // The tooltip will show itself automatically when the HTML is loaded
}

- (id)init;
{
	if(self = [self initWithContentRect:NSMakeRect(0, 0, 1, 1) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO])
	{
		// Since we are relying on `setReleaseWhenClosed:`, we need to ensure that we are over-retained.
		CFBridgingRetain(self);
		[self setReleasedWhenClosed:YES];
		[self setAlphaValue:0.97];
		[self setOpaque:NO];
		[self setBackgroundColor:[NSColor clearColor]];
		[self setHasShadow:YES];
		[self setLevel:NSStatusWindowLevel];
		[self setHidesOnDeactivate:YES];
		[self setIgnoresMouseEvents:YES];

		WKWebViewConfiguration* configuration = [WKWebViewConfiguration new];
		configuration.suppressesIncrementalRendering = YES;

		webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
		[webView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
		[webView setNavigationDelegate:self];
		// The page paints its own background (or none, for --transparent); keep the view from painting white underneath
		if([webView respondsToSelector:NSSelectorFromString(@"_setDrawsBackground:")])
			[webView setValue:@NO forKey:@"drawsBackground"];

		[self setContentView:webView];
	}
	return self;
}

// ===========
// = Webview =
// ===========
- (NSString*)fontStyle
{
	NSString* fontName = [NSUserDefaults.standardUserDefaults stringForKey:@"fontName"];
	int fontSize = [NSUserDefaults.standardUserDefaults integerForKey:@"fontSize"] ?: 11;
	NSFont* font = fontName ? [NSFont fontWithName:fontName size:fontSize] : [NSFont userFixedPitchFontOfSize:fontSize];
	NSString* family = [[font familyName] stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
	return [NSString stringWithFormat:@"font-family: '%@'; font-size: %dpx;", family, fontSize];
}

- (void)setContent:(NSString*)content transparent:(BOOL)transparent
{
	NSString* fullContent =	@"<html>"
				@"<head>"
				@"  <style type='text/css' media='screen'>"
				@"      html { background: transparent; }"
				@"      body {"
				@"          background: %@;"
				@"          margin: 0;"
				@"          padding: 2px;"
				@"          overflow: hidden;"
				@"          display: table-cell;"
				@"          max-width: 800px;"
				@"          %@"
				@"      }"
				@"      pre, code, tt { font-size: inherit; }"
				@"      pre { white-space: pre-wrap; }"
				@"  </style>"
				@"</head>"
				@"<body>%@</body>"
				@"</html>";

	fullContent = [NSString stringWithFormat:fullContent, transparent ? @"transparent" : @"#F6EDC3", [self fontStyle], content];
	[webView loadHTMLString:fullContent baseURL:nil];
}

- (void)sizeToContentWidth:(double)width height:(double)height
{
	// Current tooltip position
	NSPoint pos = NSMakePoint([self frame].origin.x, [self frame].origin.y + [self frame].size.height);

	// Find the screen which we are displaying on
	NSRect screenFrame = [[NSScreen mainScreen] visibleFrame];
	for(NSScreen* candidate in [NSScreen screens])
	{
		if(NSPointInRect(pos, [candidate frame]))
		{
			screenFrame = [candidate visibleFrame];
			break;
		}
	}

	[webView setFrameSize:NSMakeSize(width, height)];

	NSRect frame      = [self frameRectForContentRect:[webView frame]];
	frame.size.width  = std::min(NSWidth(frame), NSWidth(screenFrame));
	frame.size.height = std::min(NSHeight(frame), NSHeight(screenFrame));
	[self setFrame:frame display:NO];

	pos.x = std::max(NSMinX(screenFrame), std::min(pos.x, NSMaxX(screenFrame)-NSWidth(frame)));
	pos.y = std::min(std::max(NSMinY(screenFrame)+NSHeight(frame), pos.y), NSMaxY(screenFrame));

	[self setFrameTopLeftPoint:pos];
}

- (void)webView:(WKWebView*)sender didFinishNavigation:(WKNavigation*)navigation
{
	// The web view is laid out at a large size first and then sized down to fit the content, which WKWebView reports asynchronously
	NSRect screenFrame = [[NSScreen mainScreen] visibleFrame];
	[self setContentSize:NSMakeSize(screenFrame.size.width - screenFrame.size.width / 3.0, screenFrame.size.height)];

	[webView evaluateJavaScript:@"(function(){ var r = document.body.getBoundingClientRect(); return [r.right, r.bottom]; })();" completionHandler:^(id result, NSError* error){
		NSArray* size = [result isKindOfClass:[NSArray class]] && [result count] == 2 ? result : nil;
		self->contentSize = NSMakeSize(size ? ceil([size[0] doubleValue]) : 1, size ? ceil([size[1] doubleValue]) : 1);
		// Show on the next run loop pass, not inside the completion handler: the command that asked for the tooltip
		// is still being torn down (its FIFOs close when its proxy is released) and the event loop below would stall that
		[self performSelector:@selector(delayedSizeAndShow:) withObject:self afterDelay:0];
	}];
}

- (void)delayedSizeAndShow:(id)sender
{
	[self sizeToContentWidth:contentSize.width height:contentSize.height];
	[self orderFront:self];
	[self runUntilUserActivity:self];
}

// ==================
// = Event handling =
// ==================
- (BOOL)shouldCloseForMousePosition:(NSPoint)aPoint
{
	CGFloat ignorePeriod = [NSUserDefaults.standardUserDefaults floatForKey:@"OakToolTipMouseMoveIgnorePeriod"];
	if(-[didOpenAtDate timeIntervalSinceNow] < ignorePeriod)
		return NO;

	if(NSEqualPoints(mousePositionWhenOpened, NSZeroPoint))
	{
		mousePositionWhenOpened = aPoint;
		return NO;
	}

	NSPoint const& p = mousePositionWhenOpened;
	CGFloat deltaX = p.x - aPoint.x;
	CGFloat deltaY = p.y - aPoint.y;
	CGFloat dist = sqrt(deltaX * deltaX + deltaY * deltaY);

	CGFloat moveThreshold = [NSUserDefaults.standardUserDefaults floatForKey:@"OakToolTipMouseDistanceThreshold"];
	return dist > moveThreshold;
}

- (void)runUntilUserActivity:(id)sender
{
	[self setValue:[NSDate date] forKey:@"didOpenAtDate"];
	mousePositionWhenOpened = NSZeroPoint;

	NSWindow* keyWindow = [NSApp keyWindow];
	BOOL didAcceptMouseMovedEvents = [keyWindow acceptsMouseMovedEvents];
	[keyWindow setAcceptsMouseMovedEvents:YES];

	BOOL slowFadeOut = NO;
	while(NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantFuture] inMode:NSDefaultRunLoopMode dequeue:YES])
	{
		[NSApp sendEvent:event];

		if([event type] == NSEventTypeLeftMouseDown || [event type] == NSEventTypeRightMouseDown || [event type] == NSEventTypeOtherMouseDown || [event type] == NSEventTypeKeyDown || [event type] == NSEventTypeScrollWheel)
			break;

		if([event type] == NSEventTypeMouseMoved && [self shouldCloseForMousePosition:[NSEvent mouseLocation]])
		{
			slowFadeOut = YES;
			break;
		}

		if(keyWindow != [NSApp keyWindow] || ![NSApp isActive])
			break;
	}

	[keyWindow setAcceptsMouseMovedEvents:didAcceptMouseMovedEvents];


	[self fadeOutSlowly:slowFadeOut];
}

// =============
// = Animation =
// =============
- (void)fadeOutSlowly:(BOOL)slowly
{
	[NSAnimationContext beginGrouping];

	[NSAnimationContext currentContext].duration = slowly ? 0.5 : 0.25;
	[NSAnimationContext currentContext].completionHandler = ^{
		[self orderOut:self];
	};

	[self.animator setAlphaValue:0];

	[NSAnimationContext endGrouping];
}
@end
