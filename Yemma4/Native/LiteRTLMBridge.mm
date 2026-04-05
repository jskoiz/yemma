#import "LiteRTLMBridge.h"

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

#include <atomic>
#include <string>
#include <vector>

NSString * const LiteRTLMBridgeErrorDomain = @"com.avmillabs.yemma4.litert";

static NSError * LiteRTMakeError(LiteRTLMBridgeErrorCode code, NSString *description) {
    return [NSError errorWithDomain:LiteRTLMBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

#pragma mark - LiteRTLMBridge implementation

@implementation LiteRTLMBridge {
    NSLock *_lock;
    BOOL _engineReady;
    BOOL _conversationActive;
    NSString *_modelPath;
    std::atomic<bool> _cancelFlag;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _engineReady = NO;
        _conversationActive = NO;
        _cancelFlag.store(false);
    }
    return self;
}

- (void)dealloc {
    [self destroyEngine];
}

#pragma mark - Properties

- (BOOL)isEngineReady {
    [_lock lock];
    BOOL ready = _engineReady;
    [_lock unlock];
    return ready;
}

- (BOOL)hasActiveConversation {
    [_lock lock];
    BOOL active = _conversationActive;
    [_lock unlock];
    return active;
}

#pragma mark - Engine lifecycle

- (BOOL)createEngineWithModelPath:(NSString *)modelPath
                            error:(NSError * _Nullable __autoreleasing *)error {
    [_lock lock];

    if (_engineReady) {
        [self _destroyEngineLocked];
    }

    // Validate model file exists.
    if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
        [_lock unlock];
        if (error) {
            *error = LiteRTMakeError(
                LiteRTLMBridgeErrorCodeEngineCreationFailed,
                [NSString stringWithFormat:@"Model file not found at %@.", modelPath]);
        }
        return NO;
    }

    // Stub engine creation. The bundled LiteRT C++ SDK in this project is not
    // yet consistent across headers, generated protobufs, and runtime libs for
    // Xcode device builds, so the bridge currently exposes the API shape
    // without binding the real engine implementation here.
    _modelPath = [modelPath copy];
    _engineReady = YES;
    [_lock unlock];
    return YES;
}

- (void)destroyEngine {
    [_lock lock];
    [self _destroyEngineLocked];
    [_lock unlock];
}

- (void)_destroyEngineLocked {
    _cancelFlag.store(true);

    _conversationActive = NO;
    _engineReady = NO;
    _modelPath = nil;
}

#pragma mark - Conversation management

- (BOOL)createConversation:(NSError * _Nullable __autoreleasing *)error {
    [_lock lock];

    if (!_engineReady) {
        [_lock unlock];
        if (error) {
            *error = LiteRTMakeError(
                LiteRTLMBridgeErrorCodeEngineNotReady,
                @"Cannot create conversation: engine is not loaded.");
        }
        return NO;
    }

    _conversationActive = YES;
    _cancelFlag.store(false);

    [_lock unlock];
    return YES;
}

- (void)resetConversation {
    [_lock lock];

    _cancelFlag.store(true);

    _conversationActive = NO;
    _cancelFlag.store(false);

    [_lock unlock];
}

#pragma mark - Multimodal generation

- (void)sendMessage:(NSString *)prompt
          imagePath:(nullable NSString *)imagePath
           callback:(LiteRTLMStreamCallback)callback {

    [_lock lock];

    if (!_engineReady || !_conversationActive) {
        [_lock unlock];
        NSError *err = LiteRTMakeError(
            LiteRTLMBridgeErrorCodeEngineNotReady,
            @"Engine or conversation is not ready.");
        callback(@"", YES, err);
        return;
    }

    // Validate image path if provided.
    if (imagePath != nil && ![[NSFileManager defaultManager] fileExistsAtPath:imagePath]) {
        [_lock unlock];
        NSError *err = LiteRTMakeError(
            LiteRTLMBridgeErrorCodeImageLoadFailed,
            [NSString stringWithFormat:@"Image file not found at %@.", imagePath]);
        callback(@"", YES, err);
        return;
    }

    _cancelFlag.store(false);

    std::string promptStr(prompt.UTF8String);
    std::string imageStr = imagePath ? std::string(imagePath.UTF8String) : "";

    [_lock unlock];

    // Dispatch generation to a background queue.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self _executeGeneration:promptStr
                       imagePath:imageStr
                        callback:callback];
    });
}

- (void)_executeGeneration:(const std::string &)prompt
                 imagePath:(const std::string &)imagePath
                  callback:(LiteRTLMStreamCallback)callback {

    std::string response = "LiteRT-LM bridge is currently running in stub mode. ";
    if (!imagePath.empty()) {
        response += "Image input was received and queued for a future native runtime integration. ";
    }
    response += "This build keeps the Ask Image flow available while the bundled LiteRT device SDK is being aligned.";

    std::vector<std::string> chunks;
    std::string word;
    bool first = true;
    for (char c : response) {
        if (c == ' ') {
            if (!word.empty()) {
                chunks.push_back(first ? word : " " + word);
                first = false;
                word.clear();
            }
        } else {
            word += c;
        }
    }
    if (!word.empty()) {
        chunks.push_back(first ? word : " " + word);
    }

    for (size_t i = 0; i < chunks.size(); ++i) {
        if (_cancelFlag.load()) {
            NSError *err = LiteRTMakeError(
                LiteRTLMBridgeErrorCodeCancelled,
                @"Generation cancelled.");
            callback(@"", YES, err);
            return;
        }
        NSString *text = @(chunks[i].c_str());
        callback(text, NO, nil);
        useconds_t delay = (i == 0) ? 200000 : (20000 + arc4random_uniform(40000));
        usleep(delay);
    }
    callback(@"", YES, nil);
}

- (void)cancelGeneration {
    _cancelFlag.store(true);
}

@end
