#include "onnxruntime_c_api.h"
#include <stdlib.h> // Required for malloc
#include <stdio.h>

// Expose the ONNX API base globally for Swift use
const OrtApi* GetOrtApi(void) {
    return OrtGetApiBase()->GetApi(ORT_API_VERSION);
}

// Helper function to get tensor shape information and dimensions
OrtStatus* GetTensorShapeAndDimensions(const OrtValue* tensor, const OrtApi* ort_api, int* out_num_dims, int64_t** out_dims) {
    OrtTensorTypeAndShapeInfo* info = NULL;
    OrtStatus* status = ort_api->GetTensorTypeAndShape(tensor, &info);
    if (status != NULL) {
        return status;
    }

    size_t num_dims = 0;
    status = ort_api->GetDimensionsCount(info, &num_dims);
    if (status != NULL) {
        ort_api->ReleaseTensorTypeAndShapeInfo(info);
        return status;
    }

    // Allocate memory for the dimensions. This memory must be freed by the caller (Swift).
    int64_t* dims = (int64_t*)malloc(num_dims * sizeof(int64_t));
    if (dims == NULL) {
        ort_api->ReleaseTensorTypeAndShapeInfo(info);
        // A bit of a hack: no good status code for out of memory, so we return a failure.
        return ort_api->CreateStatus(ORT_FAIL, "Failed to allocate memory for dimensions");
    }

    status = ort_api->GetDimensions(info, dims, num_dims);
    if (status != NULL) {
        free(dims);
        ort_api->ReleaseTensorTypeAndShapeInfo(info);
        return status;
    }
    
    *out_num_dims = (int)num_dims;
    *out_dims = dims;

    // Release the info object, as we are done with it.
    ort_api->ReleaseTensorTypeAndShapeInfo(info);
    
    return NULL; // Success
}

// A generic free function for Swift to call
void FreeOrtMemory(void* ptr) {
    free(ptr);
}
