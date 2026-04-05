// Copyright 2025 The ODML Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#ifndef THIRD_PARTY_ODML_LITERT_LM_RUNTIME_UTIL_CONVERT_TENSOR_BUFFER_H_
#define THIRD_PARTY_ODML_LITERT_LM_RUNTIME_UTIL_CONVERT_TENSOR_BUFFER_H_

#include <cstdint>
#include <cstring>
#include <utility>
#include <vector>

#include "absl/log/absl_check.h"  // from @com_google_absl
#include "absl/types/span.h"  // from @com_google_absl
#include "litert/cc/litert_common.h"  // from @litert
#include "litert/cc/litert_element_type.h"  // from @litert
#include "litert/cc/litert_environment.h"  // from @litert
#include "litert/cc/litert_expected.h"  // from @litert
#include "litert/cc/litert_layout.h"  // from @litert
#include "litert/cc/litert_macros.h"  // from @litert
#include "litert/cc/litert_ranked_tensor_type.h"  // from @litert
#include "litert/cc/litert_tensor_buffer.h"  // from @litert
#include "litert/cc/litert_tensor_buffer_types.h"  // from @litert
#include "tflite/types/half.h"  // from @litert

namespace litert::lm {

template <typename T>
struct ElementTypeFor {
  // Don't define kType to generate a compile error for unsupported types.
};

template <>
struct ElementTypeFor<bool> {
  static constexpr ::litert::ElementType kType = ::litert::ElementType::Bool;
};

template <>
struct ElementTypeFor<int8_t> {
  static constexpr ::litert::ElementType kType = ::litert::ElementType::Int8;
};

template <>
struct ElementTypeFor<int16_t> {
  static constexpr ::litert::ElementType kType = ::litert::ElementType::Int16;
};

template <>
struct ElementTypeFor<int32_t> {
  static constexpr ::litert::ElementType kType = ::litert::ElementType::Int32;
};

template <>
struct ElementTypeFor<float> {
  static constexpr ::litert::ElementType kType = ::litert::ElementType::Float32;
};

template <>
struct ElementTypeFor<tflite::half> {
  static constexpr ::litert::ElementType kType = ::litert::ElementType::Float16;
};

template <typename T>
::litert::Expected<::litert::TensorBuffer> CreateTensorBuffer(
    ::litert::Dimensions&& dimensions,
    ::litert::TensorBufferType buffer_type =
        ::litert::TensorBufferType::kHostMemory) {
  if (buffer_type != ::litert::TensorBufferType::kHostMemory) {
    return ::litert::Unexpected(
        ::litert::Status::kErrorInvalidArgument,
        "Only host memory buffer is supported. Use CreateTensorBuffer() with "
        "Environment argument.");
  }
  int size = 1;
  for (int dim : dimensions) {
    size *= dim;
  }

  return ::litert::TensorBuffer::CreateManagedHostMemory(
      ::litert::RankedTensorType(ElementTypeFor<T>::kType,
                                 ::litert::Layout(std::move(dimensions))),
      size * sizeof(T));
}

template <typename T>
::litert::Expected<::litert::TensorBuffer> CreateTensorBuffer(
    ::litert::Dimensions&& dimensions, ::litert::TensorBufferType buffer_type,
    ::litert::Environment& env) {
  int size = 1;
  for (int dim : dimensions) {
    size *= dim;
  }

  return ::litert::TensorBuffer::CreateManaged(
      env, buffer_type,
      ::litert::RankedTensorType(ElementTypeFor<T>::kType,
                                 ::litert::Layout(std::move(dimensions))),
      size * sizeof(T));
}

template <typename T>
::litert::Expected<std::vector<T>> CopyFromTensorBuffer(
    const ::litert::TensorBuffer& tensor_buffer) {
  if (auto type = tensor_buffer.TensorType();
      !type.HasValue() || type->ElementType() != ElementTypeFor<T>::kType) {
    return ::litert::Unexpected(
        ::litert::Status::kErrorInvalidArgument,
        "Element type is not compatible to the target type.");
  }

  LITERT_ASSIGN_OR_RETURN(auto tensor_type, tensor_buffer.TensorType());
  LITERT_ASSIGN_OR_RETURN(auto num_elements,
                          tensor_type.Layout().NumElements());
  std::vector<T> copied_data(num_elements);
  LITERT_ASSIGN_OR_RETURN(
      auto lock_and_addr,
      ::litert::TensorBufferScopedLock::Create(
          *const_cast<::litert::TensorBuffer*>(&tensor_buffer),
          TensorBuffer::LockMode::kRead));
  if constexpr (std::is_same_v<T, bool>) {
    auto* src = static_cast<const bool*>(lock_and_addr.second);
    std::copy(src, src + num_elements, copied_data.begin());
  } else {
    std::memcpy(copied_data.data(), lock_and_addr.second,
                num_elements * sizeof(T));
  }
  return copied_data;
}

template <typename T>
::litert::Expected<std::vector<std::vector<T>>> CopyFromTensorBuffer2D(
    const ::litert::TensorBuffer& tensor_buffer) {
  auto type = tensor_buffer.TensorType();
  if (!type.HasValue() || type->ElementType() != ElementTypeFor<T>::kType) {
    return ::litert::Unexpected(
        ::litert::Status::kErrorInvalidArgument,
        "Element type is not compatible to the target type.");
  }

  auto dimensions = type->Layout().Dimensions();
  if (dimensions.size() != 2) {
    return ::litert::Unexpected(::litert::Status::kErrorInvalidArgument,
                                "Tensor buffer must have 2 dimensions.");
  }

  auto lock_and_addr = ::litert::TensorBufferScopedLock::Create(
      *const_cast<::litert::TensorBuffer*>(&tensor_buffer),
      TensorBuffer::LockMode::kRead);
  ABSL_DCHECK(lock_and_addr.HasValue());
  auto data_from = absl::MakeConstSpan(static_cast<T*>(lock_and_addr->second),
                                       dimensions[0] * dimensions[1]);
  std::vector<std::vector<T>> data_to(dimensions[0]);
  for (int i = 0; i < dimensions[0]; ++i) {
    data_to[i].resize(dimensions[1]);
    std::copy(data_from.begin() + i * dimensions[1],
              data_from.begin() + (i + 1) * dimensions[1], data_to[i].begin());
  }
  return std::move(data_to);
}

template <typename T>
::litert::Expected<::litert::TensorBuffer> CopyToTensorBuffer(
    absl::Span<const T> data, ::litert::Dimensions&& dimensions,
    ::litert::TensorBufferType buffer_type =
        ::litert::TensorBufferType::kHostMemory,
    ::litert::Environment* env = nullptr) {
  if (buffer_type != ::litert::TensorBufferType::kHostMemory &&
      env == nullptr) {
    return ::litert::Unexpected(
        ::litert::Status::kErrorInvalidArgument,
        "Environment is required for non-host memory buffer.");
  }
  ::litert::Expected<::litert::TensorBuffer> output_tensor_buffer;
  if (buffer_type == ::litert::TensorBufferType::kHostMemory) {
    output_tensor_buffer = ::litert::TensorBuffer::CreateManagedHostMemory(
        ::litert::RankedTensorType(ElementTypeFor<T>::kType,
                                   ::litert::Layout(std::move(dimensions))),
        data.size() * sizeof(T));
  } else {
    output_tensor_buffer = ::litert::TensorBuffer::CreateManaged(
        *env, buffer_type,
        ::litert::RankedTensorType(ElementTypeFor<T>::kType,
                                   ::litert::Layout(std::move(dimensions))),
        data.size() * sizeof(T));
  }
  if (!output_tensor_buffer.HasValue()) {
    return output_tensor_buffer.Error();
  }
  LITERT_RETURN_IF_ERROR(output_tensor_buffer->Write(data));
  return std::move(*output_tensor_buffer);
}

template <typename TargetType, typename SourceType>
::litert::Expected<::litert::TensorBuffer> ConvertAndCopyToTensorBuffer(
    absl::Span<const SourceType> source, ::litert::Dimensions&& dimensions,
    ::litert::TensorBufferType buffer_type =
        ::litert::TensorBufferType::kHostMemory,
    ::litert::Environment* env = nullptr) {
  if (buffer_type != ::litert::TensorBufferType::kHostMemory &&
      env == nullptr) {
    return ::litert::Unexpected(
        ::litert::Status::kErrorInvalidArgument,
        "Environment is required for non-host memory buffer.");
  }
  std::vector<TargetType> converted(source.begin(), source.end());
  return CopyToTensorBuffer<TargetType>(
      converted, std::move(dimensions), buffer_type, env);
}

}  // namespace litert::lm

#endif  // THIRD_PARTY_ODML_LITERT_LM_RUNTIME_UTIL_CONVERT_TENSOR_BUFFER_H_
