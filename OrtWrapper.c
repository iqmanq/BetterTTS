// File: OrtWrapper.c

#include "onnxruntime_c_api.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

const OrtApi* GetOrtApi(void) {
    return OrtGetApiBase()->GetApi(ORT_API_VERSION);
}

void FreeOrtMemory(void* ptr) {
    free(ptr);
}

// The C function now accepts the style_embedding as a parameter.
OrtStatus* RunInference(const OrtApi* api, OrtSession* session, const int64_t* tokenIDs, int64_t numTokens, const float* style_embedding, float** audioOutput, int64_t* audioSize) {
    
    OrtStatus* status = NULL;
    OrtMemoryInfo* memoryInfo = NULL;
    OrtValue* inputTensor = NULL;
    OrtValue* styleTensor = NULL;
    OrtValue* speedTensor = NULL;
    OrtValue* outputTensor = NULL;
    OrtAllocator* allocator = NULL;
    char* outputName = NULL;

    status = api->GetAllocatorWithDefaultOptions(&allocator);
    if (status != NULL) { return status; }
    
    status = api->SessionGetOutputName(session, 0, allocator, &outputName);
    if (status != NULL) { return status; }

    status = api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memoryInfo);
    if (status != NULL) { allocator->Free(allocator, outputName); return status; }

    // --- Create Input Tensors ---
    int64_t inputShape[] = {1, numTokens};
    status = api->CreateTensorWithDataAsOrtValue(memoryInfo, (void*)tokenIDs, numTokens * sizeof(int64_t), inputShape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputTensor);
    if (status != NULL) { api->ReleaseMemoryInfo(memoryInfo); allocator->Free(allocator, outputName); return status; }
    
    // Use the style_embedding that was passed in from Swift.
    int64_t styleShape[] = {1, 256};
    status = api->CreateTensorWithDataAsOrtValue(memoryInfo, (void*)style_embedding, 256 * sizeof(float), styleShape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &styleTensor);
    if (status != NULL) { api->ReleaseValue(inputTensor); api->ReleaseMemoryInfo(memoryInfo); allocator->Free(allocator, outputName); return status; }
    
    float speedValue[] = {1.0f};
    int64_t speedShape[] = {1};
    status = api->CreateTensorWithDataAsOrtValue(memoryInfo, speedValue, sizeof(speedValue), speedShape, 1, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &speedTensor);
    if (status != NULL) { api->ReleaseValue(inputTensor); api->ReleaseValue(styleTensor); api->ReleaseMemoryInfo(memoryInfo); allocator->Free(allocator, outputName); return status; }
    
    api->ReleaseMemoryInfo(memoryInfo);

    // --- Run Inference ---
    const OrtValue* inputs[] = {inputTensor, styleTensor, speedTensor};
    const char* inputNames[] = {"input_ids", "style", "speed"};
    const char* outputNames[] = {outputName};
    
    status = api->Run(session, NULL, inputNames, inputs, 3, outputNames, 1, &outputTensor);
    
    allocator->Free(allocator, outputName);
    api->ReleaseValue(inputTensor);
    api->ReleaseValue(styleTensor);
    api->ReleaseValue(speedTensor);

    if (status != NULL) { return status; }
    if (outputTensor == NULL) { return api->CreateStatus(ORT_FAIL, "Inference returned a null output tensor"); }

    // --- Process Output ---
    OrtTensorTypeAndShapeInfo* shapeInfo = NULL;
    status = api->GetTensorTypeAndShape(outputTensor, &shapeInfo);
    if (status != NULL) { api->ReleaseValue(outputTensor); return status; }

    int64_t dims[2];
    status = api->GetDimensions(shapeInfo, dims, 2);
    if (status != NULL) { api->ReleaseTensorTypeAndShapeInfo(shapeInfo); api->ReleaseValue(outputTensor); return status; }
    
    api->ReleaseTensorTypeAndShapeInfo(shapeInfo);
    *audioSize = dims[1];
    
    float* rawFloatData = NULL;
    status = api->GetTensorMutableData(outputTensor, (void**)&rawFloatData);
    if (status != NULL) { api->ReleaseValue(outputTensor); return status; }
    
    *audioOutput = (float*)malloc(*audioSize * sizeof(float));
    if (*audioOutput == NULL) { api->ReleaseValue(outputTensor); return api->CreateStatus(ORT_FAIL, "Failed to allocate memory"); }
    
    // Normalize and copy the data.
    float max_abs_val = 0.0f;
    for (int64_t i = 0; i < *audioSize; i++) { float val = fabsf(rawFloatData[i]); if (val > max_abs_val) { max_abs_val = val; } }
    if (max_abs_val > 1.0f) { for (int64_t i = 0; i < *audioSize; i++) { (*audioOutput)[i] = rawFloatData[i] / max_abs_val; } }
    else { memcpy(*audioOutput, rawFloatData, *audioSize * sizeof(float)); }

    api->ReleaseValue(outputTensor);
    return NULL; // Success
}
