#import "LiteRTLMBridge.h"

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

#include <atomic>
#include <memory>
#include <string>
#include <vector>

#if !TARGET_OS_SIMULATOR
#include "runtime/engine/engine.h"
#include "runtime/engine/engine_settings.h"
#include "runtime/engine/io_types.h"
#include "runtime/conversation/conversation.h"
#include "runtime/conversation/io_types.h"
#include "nlohmann/json.hpp"
#endif

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

#if !TARGET_OS_SIMULATOR
    std::unique_ptr<litert::lm::Engine> _engine;
    std::unique_ptr<litert::lm::Conversation> _conversation;
#endif
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

#if !TARGET_OS_SIMULATOR
    std::string pathStr(modelPath.UTF8String);

    // Create model assets from file path.
    auto model_assets_or = litert::lm::ModelAssets::Create(pathStr);
    if (!model_assets_or.ok()) {
        [_lock unlock];
        if (error) {
            *error = LiteRTMakeError(
                LiteRTLMBridgeErrorCodeEngineCreationFailed,
                [NSString stringWithFormat:@"Failed to load model assets: %s",
                    model_assets_or.status().message().data()]);
        }
        return NO;
    }

    // Create engine settings with GPU (Metal) backend.
    auto settings_or = litert::lm::EngineSettings::CreateDefault(
        std::move(*model_assets_or),
        litert::lm::Backend::GPU);
    if (!settings_or.ok()) {
        // Fallback to CPU if GPU fails.
        model_assets_or = litert::lm::ModelAssets::Create(pathStr);
        if (!model_assets_or.ok()) {
            [_lock unlock];
            if (error) {
                *error = LiteRTMakeError(
                    LiteRTLMBridgeErrorCodeEngineCreationFailed,
                    @"Failed to reload model assets for CPU fallback.");
            }
            return NO;
        }
        settings_or = litert::lm::EngineSettings::CreateDefault(
            std::move(*model_assets_or),
            litert::lm::Backend::CPU);
        if (!settings_or.ok()) {
            [_lock unlock];
            if (error) {
                *error = LiteRTMakeError(
                    LiteRTLMBridgeErrorCodeEngineCreationFailed,
                    [NSString stringWithFormat:@"Failed to create engine settings: %s",
                        settings_or.status().message().data()]);
            }
            return NO;
        }
    }

    // Create the engine.
    auto engine_or = litert::lm::Engine::CreateEngine(std::move(*settings_or));
    if (!engine_or.ok()) {
        [_lock unlock];
        if (error) {
            *error = LiteRTMakeError(
                LiteRTLMBridgeErrorCodeEngineCreationFailed,
                [NSString stringWithFormat:@"Failed to create engine: %s",
                    engine_or.status().message().data()]);
        }
        return NO;
    }

    _engine = std::move(*engine_or);
    _modelPath = [modelPath copy];
    _engineReady = YES;

    [_lock unlock];
    return YES;

#else
    // Simulator: stub engine creation
    _modelPath = [modelPath copy];
    _engineReady = YES;
    [_lock unlock];
    return YES;
#endif
}

- (void)destroyEngine {
    [_lock lock];
    [self _destroyEngineLocked];
    [_lock unlock];
}

- (void)_destroyEngineLocked {
    _cancelFlag.store(true);

#if !TARGET_OS_SIMULATOR
    _conversation.reset();
    _engine.reset();
#endif

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

#if !TARGET_OS_SIMULATOR
    // Create default conversation config from the engine.
    auto config_or = litert::lm::ConversationConfig::CreateDefault(*_engine);
    if (!config_or.ok()) {
        [_lock unlock];
        if (error) {
            *error = LiteRTMakeError(
                LiteRTLMBridgeErrorCodeConversationFailed,
                [NSString stringWithFormat:@"Failed to create conversation config: %s",
                    config_or.status().message().data()]);
        }
        return NO;
    }

    // Create the conversation.
    auto conv_or = litert::lm::Conversation::Create(*_engine, *config_or);
    if (!conv_or.ok()) {
        [_lock unlock];
        if (error) {
            *error = LiteRTMakeError(
                LiteRTLMBridgeErrorCodeConversationFailed,
                [NSString stringWithFormat:@"Failed to create conversation: %s",
                    conv_or.status().message().data()]);
        }
        return NO;
    }

    _conversation = std::move(*conv_or);
#endif

    _conversationActive = YES;
    _cancelFlag.store(false);

    [_lock unlock];
    return YES;
}

- (void)resetConversation {
    [_lock lock];

    _cancelFlag.store(true);

#if !TARGET_OS_SIMULATOR
    _conversation.reset();
#endif

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

#if !TARGET_OS_SIMULATOR
    // Build the JSON message with ordered content parts.
    // Format: {"role": "user", "content": [{"type": "image", "path": "..."}, {"type": "text", "text": "..."}]}
    nlohmann::ordered_json message;
    message["role"] = "user";

    nlohmann::ordered_json content = nlohmann::ordered_json::array();

    // Add image part first if provided.
    if (!imagePath.empty()) {
        nlohmann::ordered_json imagePart;
        imagePart["type"] = "image";
        imagePart["path"] = imagePath;
        content.push_back(imagePart);
    }

    // Add text part.
    nlohmann::ordered_json textPart;
    textPart["type"] = "text";
    textPart["text"] = prompt;
    content.push_back(textPart);

    message["content"] = content;

    // Use SendMessageAsync for streaming.
    litert::lm::Message lmMessage = message;

    // Capture cancel flag reference for the callback.
    auto *cancelFlag = &_cancelFlag;

    auto status = _conversation->SendMessageAsync(
        lmMessage,
        [callback, cancelFlag](absl::StatusOr<litert::lm::Message> chunk_or) {
            if (cancelFlag->load()) {
                NSError *err = LiteRTMakeError(
                    LiteRTLMBridgeErrorCodeCancelled,
                    @"Generation cancelled.");
                callback(@"", YES, err);
                return;
            }

            if (!chunk_or.ok()) {
                // Error during generation.
                NSError *err = LiteRTMakeError(
                    LiteRTLMBridgeErrorCodeGenerationFailed,
                    [NSString stringWithFormat:@"Generation error: %s",
                        chunk_or.status().message().data()]);
                callback(@"", YES, err);
                return;
            }

            // Extract text from the response message.
            // An empty message signals completion.
            auto &responseMessage = *chunk_or;
            auto *jsonMsg = std::get_if<nlohmann::ordered_json>(&responseMessage);
            if (!jsonMsg) {
                // Completion signal.
                callback(@"", YES, nil);
                return;
            }

            // Extract text content from the JSON response.
            std::string text;
            if (jsonMsg->contains("content")) {
                auto &msgContent = (*jsonMsg)["content"];
                if (msgContent.is_string()) {
                    text = msgContent.get<std::string>();
                } else if (msgContent.is_array()) {
                    for (auto &part : msgContent) {
                        if (part.contains("text")) {
                            text += part["text"].get<std::string>();
                        }
                    }
                }
            } else if (jsonMsg->contains("text")) {
                text = (*jsonMsg)["text"].get<std::string>();
            }

            if (text.empty()) {
                // Empty chunk = generation complete.
                callback(@"", YES, nil);
                return;
            }

            NSString *nsText = @(text.c_str());
            callback(nsText, NO, nil);
        });

    if (!status.ok()) {
        NSError *err = LiteRTMakeError(
            LiteRTLMBridgeErrorCodeGenerationFailed,
            [NSString stringWithFormat:@"Failed to start generation: %s",
                status.message().data()]);
        callback(@"", YES, err);
    }

#else
    // Simulator stub: generate fake word-level chunks.
    std::string response = "This is a stub response from the simulator. "
        "Real inference requires a physical device with the LiteRT-LM engine.";

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
#endif
}

- (void)cancelGeneration {
    _cancelFlag.store(true);
}

@end
