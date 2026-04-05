#import "LiteRTLMBridge.h"

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

#include <atomic>
#include <string>
#include <vector>

// TODO: Replace with real LiteRT-LM SDK headers once available for iOS.
// #include "litert_lm/engine.h"
// #include "litert_lm/conversation.h"

NSString * const LiteRTLMBridgeErrorDomain = @"com.avmillabs.yemma4.litert";

static NSError * LiteRTMakeError(LiteRTLMBridgeErrorCode code, NSString *description) {
    return [NSError errorWithDomain:LiteRTLMBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

#pragma mark - Stub response generator

/// Generates simulated streamed chunks for a prompt, simulating what the
/// real LiteRT-LM Engine + Conversation pipeline would produce.
static std::vector<std::string> LiteRTStubResponseChunks(const std::string &prompt) {
    // Produce word-level chunks similar to real token streaming.
    std::string response;

    // Simple keyword matching for varied stub output.
    if (prompt.find("describe") != std::string::npos ||
        prompt.find("Describe") != std::string::npos) {
        response = "This image shows a well-composed scene with clear subject matter. "
                   "The lighting is natural and the colors are vibrant. "
                   "I can see several distinct elements that create an interesting visual composition.";
    } else if (prompt.find("text") != std::string::npos ||
               prompt.find("read") != std::string::npos ||
               prompt.find("Read") != std::string::npos) {
        response = "I can see text in this image. The text appears to be printed in a clear, "
                   "readable font. The real LiteRT-LM model will accurately extract and "
                   "transcribe the visible text content.";
    } else {
        response = "Based on the image you shared, I can provide some observations. "
                   "The image contains notable visual elements worth describing. "
                   "For a detailed and accurate analysis, the full LiteRT-LM model "
                   "will provide richer descriptions once the SDK is integrated. "
                   "This is a stub response going through the native bridge path.";
    }

    // Split into word-level chunks.
    std::vector<std::string> chunks;
    std::string word;
    bool first = true;
    for (char c : response) {
        if (c == ' ') {
            if (!word.empty()) {
                if (first) {
                    chunks.push_back(word);
                    first = false;
                } else {
                    chunks.push_back(" " + word);
                }
                word.clear();
            }
        } else {
            word += c;
        }
    }
    if (!word.empty()) {
        if (first) {
            chunks.push_back(word);
        } else {
            chunks.push_back(" " + word);
        }
    }
    return chunks;
}

#pragma mark - LiteRTLMBridge implementation

@implementation LiteRTLMBridge {
    NSLock *_lock;
    BOOL _engineReady;
    BOOL _conversationActive;
    NSString *_modelPath;
    std::atomic<bool> _cancelFlag;

    // TODO: Replace with real LiteRT-LM SDK pointers once available.
    // std::unique_ptr<litert::lm::Engine>       _engine;
    // std::unique_ptr<litert::lm::Conversation> _conversation;
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
        // Tear down previous engine first.
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

    // TODO: Replace with real LiteRT-LM SDK calls.
    // litert::lm::EngineOptions options;
    // options.set_model_path(modelPath.UTF8String);
    // #if !TARGET_OS_SIMULATOR
    //     options.set_backend(litert::lm::Backend::kGPU);
    // #endif
    // auto engine_or = litert::lm::Engine::Create(options);
    // if (!engine_or.ok()) {
    //     [_lock unlock];
    //     if (error) {
    //         *error = LiteRTMakeError(
    //             LiteRTLMBridgeErrorCodeEngineCreationFailed,
    //             @(engine_or.status().message().c_str()));
    //     }
    //     return NO;
    // }
    // _engine = std::move(engine_or.value());

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

/// Must be called with _lock held.
- (void)_destroyEngineLocked {
    _cancelFlag.store(true);

    // TODO: Replace with real LiteRT-LM SDK calls.
    // _conversation.reset();
    // _engine.reset();

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

    // TODO: Replace with real LiteRT-LM SDK calls.
    // auto conv_or = _engine->CreateConversation();
    // if (!conv_or.ok()) {
    //     [_lock unlock];
    //     if (error) {
    //         *error = LiteRTMakeError(
    //             LiteRTLMBridgeErrorCodeConversationFailed,
    //             @(conv_or.status().message().c_str()));
    //     }
    //     return NO;
    // }
    // _conversation = std::move(conv_or.value());

    _conversationActive = YES;
    _cancelFlag.store(false);

    [_lock unlock];
    return YES;
}

- (void)resetConversation {
    [_lock lock];

    _cancelFlag.store(true);

    // TODO: Replace with real LiteRT-LM SDK calls.
    // _conversation.reset();

    _conversationActive = NO;
    _cancelFlag.store(false);

    [_lock unlock];
}

#pragma mark - Multimodal generation

- (void)sendMessage:(NSString *)prompt
          imagePath:(nullable NSString *)imagePath
           callback:(LiteRTLMStreamCallback)callback {

    // Capture state under the lock.
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

    // Copy values for the async block.
    std::string promptStr = std::string(prompt.UTF8String);
    // std::string imageStr = imagePath ? std::string(imagePath.UTF8String) : "";

    [_lock unlock];

    // Dispatch generation to a background queue.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self _executeGeneration:promptStr callback:callback];
    });
}

/// Internal generation loop running on a background queue.
/// In the real implementation, this would call the LiteRT-LM Conversation
/// SendMessageAsync API and forward streamed chunks via the callback.
- (void)_executeGeneration:(const std::string &)prompt
                  callback:(LiteRTLMStreamCallback)callback {

    // TODO: Replace with real LiteRT-LM SDK calls.
    //
    // Real implementation outline:
    //
    // litert::lm::Content content;
    // if (!imageStr.empty()) {
    //     content.AddImagePart(imageStr);  // ordered part 1: image
    // }
    // content.AddTextPart(prompt);          // ordered part 2: text
    //
    // auto stream = _conversation->SendMessageAsync(content);
    // for (auto chunk : stream) {
    //     if (_cancelFlag.load()) {
    //         callback(@"", YES, LiteRTMakeError(LiteRTLMBridgeErrorCodeCancelled,
    //                                            @"Generation cancelled."));
    //         return;
    //     }
    //     if (!chunk.ok()) {
    //         callback(@"", YES, LiteRTMakeError(LiteRTLMBridgeErrorCodeGenerationFailed,
    //                                            @(chunk.status().message().c_str())));
    //         return;
    //     }
    //     NSString *text = @(chunk.value().c_str());
    //     callback(text, NO, nil);
    // }
    // callback(@"", YES, nil);

    // --- Stub streaming implementation ---

    auto chunks = LiteRTStubResponseChunks(prompt);

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

        // Simulate variable token latency.
        // First token is slower (simulating TTFT), subsequent tokens are faster.
        useconds_t delay = (i == 0) ? 200000 : (20000 + arc4random_uniform(40000));
        usleep(delay);
    }

    // Final completion callback.
    callback(@"", YES, nil);
}

- (void)cancelGeneration {
    _cancelFlag.store(true);
}

@end
