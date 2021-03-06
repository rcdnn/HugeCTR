/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "HugeCTR/include/optimizers/momentum_sgd_optimizer.hpp"
#include "HugeCTR/include/utils.cuh"

namespace HugeCTR {

namespace {

template <typename T>
__global__ void momentum_sgd_update_kernel(int len, float* weight, T* momentum, const T* wgrad,
                                           float lr, float momentum_factor, float scaler) {
  int idx = blockDim.x * blockIdx.x + threadIdx.x;
  if (idx < len) {
    float mv = momentum_factor * TypeConvertFunc<float, T>::convert(momentum[idx]) -
               lr * TypeConvertFunc<float, T>::convert(wgrad[idx]) / scaler;
    momentum[idx] = TypeConvertFunc<T, float>::convert(mv);
    weight[idx] += mv;
  }
  return;
}

}  // namespace

MomentumSGDOptimizer::MomentumSGDOptimizer(const GeneralBufferPtr<float>& weight,
                                           const GeneralBufferPtr<float>& fp32_wgrad,
                                           const GeneralBufferPtr<__half>& fp16_wgrad,
                                           bool mixed_precision, int device_id, float learning_rate,
                                           float momentum_factor, float scaler)
    : Optimizer(weight, fp32_wgrad, fp16_wgrad, mixed_precision, device_id, learning_rate, scaler),
      momentum_factor_(momentum_factor) {
  if (mixed_precision) {
    fp16_momentum_.reserve(weight->get_num_elements());
    fp16_momentum_.init(device_id);
    fp16_momentum_.reset_sync();
  } else {
    fp32_momentum_.reserve(weight->get_num_elements());
    fp32_momentum_.init(device_id);
    fp32_momentum_.reset_sync();
  }
}

void MomentumSGDOptimizer::update(cudaStream_t stream) {
  CudaDeviceContext context(device_id_);

  const size_t len = weight_main_->get_num_elements();
  constexpr size_t block_dim = 256;
  const size_t grid_dim = (len - 1) / block_dim + 1;

  float* weight = weight_main_->get_ptr_with_offset(0);

  if (mixed_precision_) {
    __half* fp16_momentum = fp16_momentum_.get_ptr_with_offset(0);
    const __half* fp16_wgrad = fp16_wgrad_->get_ptr_with_offset(0);

    momentum_sgd_update_kernel<<<grid_dim, block_dim, 0, stream>>>(
        len, weight, fp16_momentum, fp16_wgrad, lr_, momentum_factor_, scaler_);
  } else {
    float* fp32_momentum = fp32_momentum_.get_ptr_with_offset(0);
    const float* fp32_wgrad = fp32_wgrad_->get_ptr_with_offset(0);

    momentum_sgd_update_kernel<<<grid_dim, block_dim, 0, stream>>>(
        len, weight, fp32_momentum, fp32_wgrad, lr_, momentum_factor_, scaler_);
  }

#ifndef NDEBUG
  cudaDeviceSynchronize();
  CK_CUDA_THROW_(cudaGetLastError());
#endif
}

}  // namespace HugeCTR
