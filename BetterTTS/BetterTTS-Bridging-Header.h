#ifndef BetterTTS_Bridging_Header_h
#define BetterTTS_Bridging_Header_h

#import "onnxruntime_c_api.h"

// Original function to get the API
const OrtApi* GetOrtApi(void);

// Our new helper functions
OrtStatus* GetTensorShapeAndDimensions(const OrtValue* tensor, const OrtApi* ort_api, int* out_num_dims, int64_t** out_dims);
void FreeOrtMemory(void* ptr);

#endif /* BetterTTS_Bridging_Header_h */
