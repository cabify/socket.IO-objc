//
//  SocketIO.m
//  v.01
//
//  based on 
//  socketio-cocoa https://github.com/fpotter/socketio-cocoa
//  by Fred Potter <fpotter@pieceable.com>
//
//  using
//  https://github.com/erichocean/cocoa-websocket
//  http://regexkit.sourceforge.net/RegexKitLite/
//  https://github.com/stig/json-framework/
//  http://allseeing-i.com/ASIHTTPRequest/
//
//  reusing some parts of
//  /socket.io/socket.io.js
//
//  Created by Philipp Kyeck http://beta_interactive.de
//

#import "SocketIO.h"

#import "ASIHTTPRequest.h"
#import "WebSocket.h"
#import "RegexKitLite.h"
#import "SBJson.h"

#define USE_SOCKET_ROCKET 1 
#define DEBUG_LOGS 1
#define HANDSHAKE_URL @"http://%@:%d/socket.io/1/?t=%d%@"
#define SOCKET_URL @"ws://%@:%d/socket.io/1/websocket/%@"


# pragma mark -
# pragma mark SocketIO's private interface
    
#ifdef USE_SOCKET_ROCKET
@interface SocketIO (private_socketRocket) <SRWebSocketDelegate>
@end
#endif
#ifndef USE_SOCKET_ROCKET
@interface SocketIO (private_websocket) <WebSocketDelegate>
@end
#endif


@interface SocketIO (FP_Private)

- (void) log:(NSString *)message;

- (void) setTimeout;
- (void) onTimeout;

- (void) onConnect:(SocketIOPacket *)packet;
- (void) onDisconnect;

- (void) sendDisconnect;
- (void) sendHearbeat;
- (void) send:(SocketIOPacket *)packet;

- (NSString *) addAcknowledge:(SocketIOCallback)function;
- (void) removeAcknowledgeForKey:(NSString *)key;

@end


# pragma mark -
# pragma mark SocketIO implementation

@implementation SocketIO

@synthesize isConnected = _isConnected, isConnecting = _isConnecting;

- (id) initWithDelegate:(id<SocketIODelegate>)delegate
{
    self = [super init];
    if (self)
    {
        _delegate = delegate;
        
        _queue = [[NSMutableArray alloc] init];
        
        _ackCount = 0;
        _acks = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void) connectToHost:(NSString *)host onPort:(NSInteger)port
{
    [self connectToHost:host onPort:port withParams:nil withNamespace:@""];
}

- (void) connectToHost:(NSString *)host onPort:(NSInteger)port withParams:(NSDictionary *)params
{
    [self connectToHost:host onPort:port withParams:params withNamespace:@""];
}

- (void) connectToHost:(NSString *)host onPort:(NSInteger)port withParams:(NSDictionary *)params withNamespace:(NSString *)endpoint
{
    if (!_isConnected && !_isConnecting) 
    {
        _isConnecting = YES;
        
        _host = [host retain];
        _port = port;
        _endpoint = [endpoint copy];
        
        // create a query parameters string
        NSMutableString *query = [[NSMutableString alloc] initWithString:@""];
        [params enumerateKeysAndObjectsUsingBlock: ^(id key, id value, BOOL *stop) {
            [query appendFormat:@"&%@=%@",key,value];
        }];
        
        // do handshake via HTTP request
        NSString *s = [NSString stringWithFormat:HANDSHAKE_URL, _host, _port, rand(), query];
        debug([NSString stringWithFormat:@"Connecting to socket with URL: %@",s]);
        NSURL *url = [NSURL URLWithString:s];
        [query release];
        
        if (USE_SOCKET_ROCKET){
            ASIHTTPRequest *request = [ASIHTTPRequest requestWithURL:url];
            [request setDelegate:self];
            [request startAsynchronous]; 
        } else {
            debug(@"WEB SOCKET: request");
            ASIHTTPRequest *request = [ASIHTTPRequest requestWithURL:url];
            [request setDelegate:self];
            [request startAsynchronous];   
        }
    }
}

- (void) disconnect
{
    [self sendDisconnect];
}

- (void) sendMessage:(NSString *)data
{
    [self sendMessage:data withAcknowledge:nil];
}

- (void) sendMessage:(NSString *)data withAcknowledge:(SocketIOCallback)function
{
    SocketIOPacket *packet = [[SocketIOPacket alloc] initWithType:@"message"];
    packet.data = data;
    packet.pId = [self addAcknowledge:function];
    [self send:packet];
    [packet release];
}

- (void) sendJSON:(NSDictionary *)data
{
    [self sendJSON:data withAcknowledge:nil];
}

- (void) sendJSON:(NSDictionary *)data withAcknowledge:(SocketIOCallback)function
{
    SocketIOPacket *packet = [[SocketIOPacket alloc] initWithType:@"json"];
    packet.data = [data JSONRepresentation];
    packet.pId = [self addAcknowledge:function];
    [self send:packet];
    [packet release];
}

- (void) sendEvent:(NSString *)eventName withData:(NSDictionary *)data
{
    [self sendEvent:eventName withData:data andAcknowledge:nil];
}

- (void) sendEvent:(NSString *)eventName withData:(NSDictionary *)data andAcknowledge:(SocketIOCallback)function
{
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithObject:eventName forKey:@"name"];
    if (data != nil) // do not require arguments
        [dict setObject:data forKey:@"args"];
    
    SocketIOPacket *packet = [[SocketIOPacket alloc] initWithType:@"event"];
    packet.data = [dict JSONRepresentation];
    packet.pId = [self addAcknowledge:function];
    if (function) 
    {
        packet.ack = @"data";
    }
    [self send:packet];
    [packet release];
}

- (void)sendAcknowledgement:(NSString *)pId withArgs:(NSArray *)data {
    SocketIOPacket *packet = [[SocketIOPacket alloc] initWithType:@"ack"];
    packet.data = [data JSONRepresentation];
    packet.pId = pId;
    packet.ack = @"data";

    [self send:packet];
    [packet release];
}

# pragma mark -
# pragma mark private methods

- (void) openSocket
{
    NSString *url = [NSString stringWithFormat:SOCKET_URL, _host, _port, _sid];
    if (USE_SOCKET_ROCKET){
        debug(@"SOCKET ROCKET from openSocket: open");
        _socketRocket = [[SRWebSocket alloc] initWithURLRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
        _socketRocket.delegate = self;
        debug(@"SOCKET ROCKET: init and open...");
        [_socketRocket open];
    } else {
        debug(@"WEB SOCKET: open");
        [_webSocket release];
        _webSocket = nil;
        _webSocket = [[WebSocket alloc] initWithURLString:url delegate:self];
        debug([NSString stringWithFormat:@"Opening %@", url]);
        [_webSocket open];
    }
}

- (void) sendDisconnect
{
    SocketIOPacket *packet = [[SocketIOPacket alloc] initWithType:@"disconnect"];
    [self send:packet];
    [packet release];
}

- (void) sendConnect
{
    SocketIOPacket *packet = [[SocketIOPacket alloc] initWithType:@"connect"];
    [self send:packet];
    [packet release];
}

- (void) sendHeartbeat
{
    SocketIOPacket *packet = [[SocketIOPacket alloc] initWithType:@"heartbeat"];
    [self send:packet];
    [packet release];
}

- (void) send:(SocketIOPacket *)packet
{   
    debug(@"send()");
    NSNumber *type = [packet typeAsNumber];
    NSMutableArray *encoded = [NSMutableArray arrayWithObject:type];
    
    NSString *pId = packet.pId != nil ? packet.pId : @"";
    if ([packet.ack isEqualToString:@"data"])
    {
        pId = [pId stringByAppendingString:@"+"];
    }
    
    // Do not write pid for acknowledgements
    if ([type intValue] != 6) {
        [encoded addObject:pId];
    }
    
    // Add the end point for the namespace to be used, as long as it is not
    // an ACK, heartbeat, or disconnect packet
    if ([type intValue] != 6 && [type intValue] != 2 && [type intValue] != 0) {
        [encoded addObject:_endpoint];
    } else {
        [encoded addObject:@""];
    }
    
    if (packet.data != nil)
    {
        NSString *ackpId = @"";
        // This is an acknowledgement packet, so, prepend the ack pid to the data
        if ([type intValue] == 6) {
            ackpId = [NSString stringWithFormat:@":%@%@", packet.pId, @"+"];
        }
        
        [encoded addObject:[NSString stringWithFormat:@"%@%@", ackpId, packet.data]];
    }
    
    NSString *req = [encoded componentsJoinedByString:@":"];
    if (!_isConnected) 
    {
        debug([NSString stringWithFormat:@"queue >>> %@", req]);
        [_queue addObject:packet];
    } 
    else 
    {
        debug([NSString stringWithFormat:@"send() >>> %@", req]);
        
        if (USE_SOCKET_ROCKET){
            debug(@"SOCKET ROCKET: send");
            [_socketRocket send:req];            
        } else {
            debug(@"WEB SOCKET: send");
            [_webSocket send:req];            
        }
        
        if ([_delegate respondsToSelector:@selector(socketIO:didSendMessage:)])
        {
            [_delegate socketIO:self didSendMessage:packet];
        }
    }
}



- (void) onData:(NSString *)data 
{
    debug([NSString stringWithFormat:@"onData %@", data]);
    
    // data arrived -> reset timeout
    [self setTimeout];
    
    // check if data is valid (from socket.io.js)
    NSString *regex = @"^([^:]+):([0-9]+)?(\\+)?:([^:]+)?:?(.*)?$";
    NSString *regexPieces = @"^([0-9]+)(\\+)?(.*)";
    NSArray *test = [data arrayOfCaptureComponentsMatchedByRegex:regex];
    
    // valid data-string arrived
    if ([test count] > 0) 
    {
        NSArray *result = [test objectAtIndex:0];
        
        int idx = [[result objectAtIndex:1] intValue];
        SocketIOPacket *packet = [[SocketIOPacket alloc] initWithTypeIndex:idx];
        
        packet.pId = [result objectAtIndex:2];
        
        packet.ack = [result objectAtIndex:3];
        packet.endpoint = [result objectAtIndex:4];        
        packet.data = [result objectAtIndex:5];
        
        //
        switch (idx) 
        {
            case 0:
                debug(@"disconnect");
                [self onDisconnect];
                break;
                
            case 1:
                debug(@"connect");
                // from socket.io.js ... not sure when data will contain sth?! 
                // packet.qs = data || '';
                [self onConnect:packet];
                break;
                
            case 2:
                debug(@"heartbeat");
                [self sendHeartbeat];
                break;
                
            case 3:
                debug(@"message");
                if (packet.data && ![packet.data isEqualToString:@""])
                {
                    if ([_delegate respondsToSelector:@selector(socketIO:didReceiveMessage:)]) 
                    {
                        [_delegate socketIO:self didReceiveMessage:packet];
                    }
                }
                break;
                
            case 4:
                debug(@"json");
                if (packet.data && ![packet.data isEqualToString:@""])
                {
                    if ([_delegate respondsToSelector:@selector(socketIO:didReceiveJSON:)]) 
                    {
                        [_delegate socketIO:self didReceiveJSON:packet];
                    }
                }
                break;
                
            case 5:
                debug(@"event");
                if (packet.data && ![packet.data isEqualToString:@""])
                { 
                    NSDictionary *json = [packet dataAsJSON];
                    packet.name = [json objectForKey:@"name"];
                    packet.args = [json objectForKey:@"args"];
                    if ([_delegate respondsToSelector:@selector(socketIO:didReceiveEvent:)]) 
                    {
                        [_delegate socketIO:self didReceiveEvent:packet];
                    }
                }
                break;
                
            case 6:
                debug(@"ack");
                NSArray *pieces = [packet.data arrayOfCaptureComponentsMatchedByRegex:regexPieces];
                
                if ([pieces count] > 0) 
                {
                    NSArray *piece = [pieces objectAtIndex:0];
                    int ackId = [[piece objectAtIndex:1] intValue];
                    debug([NSString stringWithFormat:@"ack id found: %d", ackId]);
                    
                    NSString *argsStr = [piece objectAtIndex:3];
                    id argsData = nil;
                    if (argsStr && ![argsStr isEqualToString:@""])
                    {
                        argsData = [argsStr JSONValue];
                        if ([argsData count] > 0)
                        {
                            argsData = [argsData objectAtIndex:0];
                        }
                    }
                    
                    // get selector for ackId
                    NSString *key = [NSString stringWithFormat:@"%d", ackId];
                    SocketIOCallback callbackFunction = [_acks objectForKey:key];
                    if (callbackFunction != nil)
                    {
                        callbackFunction(argsData);
                        [self removeAcknowledgeForKey:key];
                    }
                }
                
                break;
               
            case 7:
                debug(@"error");
                break;
                
            case 8:
                debug(@"noop");
                break;
                
            default:
                debug(@"command not found or not yet supported");
                break;
        }

        [packet release];
    }
    else
    {
        debug(@"ERROR: data that has arrived wasn't valid");
    }
}


- (void) doQueue 
{
    debug([NSString stringWithFormat:@"doQueue() >> %d", [_queue count]]);
    
    // TODO send all packets at once ... not as seperate packets
    while ([_queue count] > 0) 
    {
        SocketIOPacket *packet = [_queue objectAtIndex:0];
        [self send:packet];
        [_queue removeObject:packet];
    }
}

- (void) onConnect:(SocketIOPacket *)packet
{
    debug(@"onConnect()");
    
    _isConnected = YES;

    // Send the connected packet so the server knows what it's dealing with.
    // Only required when endpoint/namespace is present
    if ([_endpoint length] > 0) {
        // Make sure the packet we received has an endpoint, otherwise send it again
        if (![packet.endpoint isEqualToString:_endpoint]) {
            debug(@"onConnect() >> End points do not match, resending connect packet");
            [self sendConnect];
            return;
        }
    }
    
    _isConnecting = NO;
    
    if ([_delegate respondsToSelector:@selector(socketIODidConnect:)]) 
    {
        [_delegate socketIODidConnect:self];
    }
    
    // send any queued packets
    [self doQueue];
    
    [self setTimeout];
}

- (void) onDisconnect 
{
    debug(@"onDisconnect()");
    BOOL wasConnected = _isConnected;
    
    _isConnected = NO;
    _isConnecting = NO;
    _sid = nil;
    
    [_queue removeAllObjects];
    
    // Kill the heartbeat timer
    if (_timeout != nil) {
        [_timeout invalidate];
        _timeout = nil;
    }
    
    // Disconnect the websocket, just in case
    if (USE_SOCKET_ROCKET){
        if (_socketRocket != nil && (_socketRocket.readyState==1)/*1=SRReadyState.SR_OPEN*/ ) {
            debug(@"SOCKET ROCKET: close");
            [_socketRocket close];
        }        
    } else {
        debug(@"WEB SOCKET: close");
        if (_webSocket != nil && [_webSocket connected]) {
            [_webSocket close];
        }
    }
    
    if (wasConnected && [_delegate respondsToSelector:@selector(socketIODidDisconnect:)]) 
    {
        [_delegate socketIODidDisconnect:self];
    }
}

# pragma mark -
# pragma mark Acknowledge methods

- (NSString *) addAcknowledge:(SocketIOCallback)function
{
    if (function)
    {
        ++_ackCount;
        NSString *ac = [NSString stringWithFormat:@"%d", _ackCount];
        [_acks setObject:[function copy] forKey:ac];
        return ac;
    }
    return nil;
}

- (void) removeAcknowledgeForKey:(NSString *)key
{
    [_acks removeObjectForKey:key];
}

# pragma mark -
# pragma mark Heartbeat methods

- (void) onTimeout 
{
    debug(@"Timed out waiting for heartbeat.");
    [self onDisconnect];
}

- (void) setTimeout 
{
    debug(@"setTimeout()");
    if (_timeout != nil) 
    {   
        [_timeout invalidate];
        [_timeout release];
        _timeout = nil;
    }
    
    _timeout = [[NSTimer scheduledTimerWithTimeInterval:_heartbeatTimeout
                                                target:self 
                                              selector:@selector(onTimeout) 
                                              userInfo:nil 
                                               repeats:NO] retain];
}


# pragma mark -
# pragma mark Handshake callbacks (ASIHTTPRequestDelegate)

- (void) requestFinished:(ASIHTTPRequest *)request
{
    NSString *responseString = [request responseString];
    debug([NSString stringWithFormat:@"requestFinished() %@", responseString]);
    NSArray *data = [responseString componentsSeparatedByString:@":"];
    
    _sid = [[data objectAtIndex:0] retain];
    debug([NSString stringWithFormat:@"sid: %@", _sid]);
    
    // add small buffer of 7sec (magic xD)
    _heartbeatTimeout = [[data objectAtIndex:1] floatValue] + 7.0;
    debug([NSString stringWithFormat:@"heartbeatTimeout: %f", _heartbeatTimeout]);
    
    // index 2 => connection timeout
    
    NSString *t = [data objectAtIndex:3];
    NSArray *transports = [t componentsSeparatedByString:@","];
    debug([NSString stringWithFormat:@"transports: %@", transports]);
    
    [self openSocket];
}

- (void) requestFailed:(ASIHTTPRequest *)request
{
    NSError *error = [request error];
    NSLog(@"ERROR: handshake failed ... %@", [error localizedDescription]);
    
    _isConnected = NO;
    _isConnecting = NO;
    
    if ([_delegate respondsToSelector:@selector(socketIOHandshakeFailed:)])
    {
        [_delegate socketIOHandshakeFailed:self];
    }
}


#ifdef USE_SOCKET_ROCKET
#pragma mark - SRWebSocketDelegate
- (void)webSocket:(SRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean {
    debug(@"SOCKET ROCKET: Connection closed. Reason: %@. Was it clean? %@", reason, wasClean?@"YES":@"NO");
    [self onDisconnect];
}
- (void)webSocketDidOpen:(SRWebSocket *)webSocket {
    debug(@"SOCKET ROCKET: Connection opened.");
}
- (void)webSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error {
    debug([NSString stringWithFormat:@"SOCKET ROCKET: Connection failed with error %@", [error localizedDescription]]);
    [self onDisconnect];
}
- (void)webSocket:(SRWebSocket *)webSocket didReceiveMessage:(NSString *)message {
    [self onData:message];
}
#endif


#ifndef USE_SOCKET_ROCKET
#pragma mark - WebSocketDelegate

- (void) webSocketDidClose:(WebSocket*)webSocket 
{
    debug([NSString stringWithFormat:@"Connection closed."]]);
    [self onDisconnect];
}

- (void) webSocketDidOpen:(WebSocket *)ws 
{
    debug([NSString stringWithFormat:@"Connection opened."]]);
}

- (void) webSocket:(WebSocket *)ws didFailWithError:(NSError *)error 
{
    debug(@"ERROR: Connection failed with error ... %@", [error localizedDescription]);
    // Assuming this resulted in a disconnect
    [self onDisconnect];
}

- (void) webSocket:(WebSocket *)ws didReceiveMessage:(NSString*)message 
{
    [self onData:message];
}

#endif


# pragma mark -

- (void) log:(NSString *)message 
{
#if DEBUG_LOGS
    debug(@"%@", message);
#endif
}


- (void) dealloc
{
    [_host release];
    [_sid release];
    [_endpoint release];
    
    [_webSocket release];
    [_socketRocket release];
    
    [_timeout invalidate];
    [_timeout release];
    
    [_queue release];
    [_acks release];
    
    [super dealloc];
}


@end


# pragma mark -
# pragma mark SocketIOPacket implementation

@implementation SocketIOPacket

@synthesize type, pId, name, ack, data, args, endpoint;

- (id) init
{
    self = [super init];
    if (self)
    {
        _types = [[NSArray arrayWithObjects: @"disconnect", 
                  @"connect", 
                  @"heartbeat", 
                  @"message", 
                  @"json", 
                  @"event", 
                  @"ack", 
                  @"error", 
                  @"noop", 
                  nil] retain];
    }
    return self;
}

- (id) initWithType:(NSString *)packetType
{
    self = [self init];
    if (self)
    {
        self.type = packetType;
    }
    return self;
}

- (id) initWithTypeIndex:(int)index
{
    self = [self init];
    if (self)
    {
        self.type = [self typeForIndex:index];
    }
    return self;
}

- (id) dataAsJSON
{
    return [self.data JSONValue];
}

- (NSNumber *) typeAsNumber
{
    int index = [_types indexOfObject:self.type];
    NSNumber *num = [NSNumber numberWithInt:index];
    return num;
}

- (NSString *) typeForIndex:(int)index
{
    return [_types objectAtIndex:index];
}

- (void)dealloc
{
    [_types release];
    
    [type release];
    [pId release];
    [name release];
    [ack release];
    [data release];
    [args release];
    [endpoint release];
    
    [super dealloc];
}

@end
