// File: BetterTTS-Bridging-Header.h

#ifndef BetterTTS_Bridging_Header_h
#define BetterTTS_Bridging_Header_h

#import "onnxruntime_c_api.h"

const OrtApi* GetOrtApi(void);

// Update the function to accept the speaker embedding from Swift
OrtStatus* RunInference(
    const OrtApi* api,
    OrtSession* session,
    const int64_t* tokenIDs,
    int64_t numTokens,
    const float* style_embedding, // <-- New parameter
    float** audioOutput,
    int64_t* audioSize
);

void FreeOrtMemory(void* ptr);

#endif /* BetterTTS_Bridging_Header_h */
