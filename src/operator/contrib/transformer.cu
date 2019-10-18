/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

/*!
 *  Copyright (c) 2018 by Contributors
 * \file transformer.cu
 * \brief GPU implementation of the operators used in Transformer
 */
#include <mxnet/base.h>
#include "./transformer-inl.h"
#include "../../common/cuda_utils.h"

namespace mxnet {
namespace op {

// Approach in gemm_switch_fp32accum is coming from MLPerf v0.6 submission repository from NVIDIA
// by https://github.com/kevinstephano
template<typename DType>
void CublasStridedBatchedGemm(mshadow::Stream<gpu>* s, bool transA, bool transB,
                              int32_t m, int32_t n, int32_t k,
                              float alpha, const DType* a, int32_t lda, int32_t strideA,
                              const DType *b, int32_t ldb, int32_t strideB, float beta,
                              DType *c, int32_t ldc, int32_t strideC, int32_t batchCount,
                              cublasGemmAlgo_t algo = CUBLAS_GEMM_DEFAULT_TENSOR_OP) {
#if CUDA_VERSION >= 9010
  using namespace mxnet::common::cuda;
  CHECK_EQ(s->blas_handle_ownership_, mshadow::Stream<gpu>::OwnHandle)
      << "Must init CuBLAS handle in stream";

  cublasHandle_t blas_handle = mshadow::Stream<gpu>::GetBlasHandle(s);
  auto err = CUBLAS_STATUS_SUCCESS;
  // TODO(cfujitsang): handle computation_precision
  err = cublasGemmStridedBatchedEx(
      blas_handle, CublasTransposeOp(transA), CublasTransposeOp(transB),
      static_cast<int>(m), static_cast<int>(n), static_cast<int>(k),
      reinterpret_cast<void*>(&alpha),
      a, CublasType<DType>::kCudaFlag, static_cast<int>(lda), strideA,
      b, CublasType<DType>::kCudaFlag, static_cast<int>(ldb), strideB,
      reinterpret_cast<void*>(&beta),
      c, CublasType<DType>::kCudaFlag, static_cast<int>(ldc), strideC,
      static_cast<int>(batchCount), CUDA_R_32F, algo);
  CHECK_EQ(err, CUBLAS_STATUS_SUCCESS) << "Cublas gemmEx fail.";
#else
  LOG(FATAL) << "Not implemented with CUDA < 9.1";
#endif
}

template<typename DType>
void gemm_switch_fp32accum(mshadow::Stream<gpu>* s, bool transA, bool transB,
                           int32_t m, int32_t n, int32_t k,
                           float alpha, const DType *a, int32_t lda,
                           int32_t strideA, const DType *b, int32_t ldb,
                           int32_t strideB, float beta, DType *c, int32_t ldc,
                           int32_t strideC, int32_t batchCount) {
  cudaStream_t stream = mshadow::Stream<gpu>::GetStream(s);
  if (!(lda & 0x7) && !(ldb & 0x7) && !(ldc & 0x7)) {
    CublasStridedBatchedGemm(s, transA, transB, m, n, k, alpha, a, lda, strideA, b, ldb,
      strideB, beta, c, ldc, strideC, batchCount, CUBLAS_GEMM_ALGO0_TENSOR_OP);
  } else {
    CublasStridedBatchedGemm(s, transA, transB, m, n, k, alpha, a, lda, strideA, b, ldb,
      strideB, beta, c, ldc, strideC, batchCount);
  }
  CHECK_CUDA_ERROR("Error at InterleavedMatMul");
}

// TODO(cfujitsang): use scale as optional ?
void InterleavedMatMulSelfAttQKGPU(const nnvm::NodeAttrs& attrs,
                                   const OpContext &ctx,
                                   const std::vector<TBlob> &inputs,
                                   const std::vector<OpReqType> &req,
                                   const std::vector<TBlob> &outputs) {
  const auto& params = nnvm::get<InterleavedMatMulParam>(attrs.parsed);
  mshadow::Stream<gpu>* s = ctx.get_stream<gpu>();
  MSHADOW_REAL_TYPE_SWITCH(inputs[0].type_flag_, DType, {
    const DType* queries_keys_values = inputs[0].FlatTo2D<gpu, DType>(s).dptr_;
    DType* output = outputs[0].FlatTo2D<gpu, DType>(s).dptr_;
    const int32_t qkv_seq_len    = inputs[0].shape_[0];
    const int32_t sequences      = inputs[0].shape_[1];
    const int32_t output_lin_dim = inputs[0].shape_[2];
    const int32_t embed_dim      = output_lin_dim / 3;
    const int32_t head_dim       = embed_dim / params.heads;
    const int32_t attn_batches   = params.heads * sequences;
    const int32_t lead_dim       = attn_batches * 3 * head_dim;
    const int32_t batch_stride   = 3 * head_dim;
    const float beta             = req[0] == kAddTo ? 1.f : 0.f;
    const float scale            = 1.0 / sqrt(static_cast<float>(head_dim));

    if (req[0] == kNullOp)
      return;

    gemm_switch_fp32accum(s,
                          true,
                          false,
                          qkv_seq_len,
                          qkv_seq_len,
                          head_dim,
                          scale,
                          queries_keys_values + head_dim,
                          lead_dim,
                          batch_stride,
                          queries_keys_values,
                          lead_dim,
                          batch_stride,
                          beta,
                          output,
                          qkv_seq_len,
                          qkv_seq_len * qkv_seq_len,
                          attn_batches);
  })
}

void BackwardInterleavedMatMulSelfAttQKGPU(const nnvm::NodeAttrs& attrs,
                                           const OpContext &ctx,
                                           const std::vector<TBlob> &inputs,
                                           const std::vector<OpReqType> &req,
                                           const std::vector<TBlob> &outputs) {
  const auto& params = nnvm::get<InterleavedMatMulParam>(attrs.parsed);
  mshadow::Stream<gpu>* s = ctx.get_stream<gpu>();
  MSHADOW_REAL_TYPE_SWITCH(inputs[0].type_flag_, DType, {
    const DType* output_grads        = inputs[0].FlatTo2D<gpu, DType>(s).dptr_;
    const DType* queries_keys_values = inputs[1].FlatTo2D<gpu, DType>(s).dptr_;
    DType* queries_keys_values_grads = outputs[0].FlatTo2D<gpu, DType>(s).dptr_;
    const int32_t qkv_seq_len    = inputs[1].shape_[0];
    const int32_t sequences      = inputs[1].shape_[1];
    const int32_t output_lin_dim = inputs[1].shape_[2];
    const int32_t embed_dim      = output_lin_dim / 3;
    const int32_t head_dim       = embed_dim / params.heads;
    const int32_t attn_batches   = params.heads * sequences;
    const int32_t lead_dim       = attn_batches * 3 * head_dim;
    const int32_t batch_stride   = 3 * head_dim;
    const float scale            = 1.0 / sqrt(static_cast<float>(head_dim));
    const float beta = ((req[0] == kAddTo) && !params.bwd_ignore_zero_init) ? 1.f : 0.f;

    if (req[0] == kNullOp)
      return;

    if (req[0] == kWriteTo && !params.bwd_ignore_zero_init) {
      cudaMemsetAsync(queries_keys_values_grads, 0, outputs[0].shape_.Size() * sizeof(DType),
                      mshadow::Stream<gpu>::GetStream(s));
    }

    gemm_switch_fp32accum(s,
                          false,
                          false,
                          head_dim,
                          qkv_seq_len,
                          qkv_seq_len,
                          scale,
                          queries_keys_values + head_dim,
                          lead_dim,
                          batch_stride,
                          output_grads,
                          qkv_seq_len,
                          qkv_seq_len * qkv_seq_len,
                          beta,
                          queries_keys_values_grads,
                          lead_dim,
                          batch_stride,
                          attn_batches);
    gemm_switch_fp32accum(s,
                          false,
                          true,
                          head_dim,
                          qkv_seq_len,
                          qkv_seq_len,
                          scale,
                          queries_keys_values,
                          lead_dim,
                          batch_stride,
                          output_grads,
                          qkv_seq_len,
                          qkv_seq_len * qkv_seq_len,
                          beta,
                          queries_keys_values_grads + head_dim,
                          lead_dim,
                          batch_stride,
                          attn_batches);
  })
}

void InterleavedMatMulSelfAttValAttGPU(const nnvm::NodeAttrs& attrs,
                                       const OpContext &ctx,
                                       const std::vector<TBlob> &inputs,
                                       const std::vector<OpReqType> &req,
                                       const std::vector<TBlob> &outputs) {
  const auto& params = nnvm::get<InterleavedMatMulParam>(attrs.parsed);
  mshadow::Stream<gpu>* s = ctx.get_stream<gpu>();
  MSHADOW_REAL_TYPE_SWITCH(inputs[0].type_flag_, DType, {
    const DType* queries_keys_values = inputs[0].FlatTo2D<gpu, DType>(s).dptr_;
    const DType* attention_maps      = inputs[1].FlatTo2D<gpu, DType>(s).dptr_;
    DType* output                    = outputs[0].FlatTo2D<gpu, DType>(s).dptr_;
    const int32_t qkv_seq_len    = inputs[0].shape_[0];
    const int32_t sequences      = inputs[0].shape_[1];
    const int32_t output_lin_dim = inputs[0].shape_[2];
    const int32_t embed_dim      = output_lin_dim / 3;
    const int32_t head_dim       = embed_dim / params.heads;
    const int32_t attn_batches   = params.heads * sequences;
    const int32_t lead_dim       = attn_batches * 3 * head_dim;
    const int32_t batch_stride   = 3 * head_dim;
    const float alpha            = 1.f;
    const float beta             = req[0] == kAddTo ? 1.f : 0.f;

    if (req[0] == kNullOp)
      return;

    gemm_switch_fp32accum(s,
                          false,
                          false,
                          head_dim,
                          qkv_seq_len,
                          qkv_seq_len,
                          alpha,
                          queries_keys_values + 2 * head_dim,
                          lead_dim,
                          batch_stride,
                          attention_maps,
                          qkv_seq_len,
                          qkv_seq_len * qkv_seq_len,
                          beta,
                          output,
                          head_dim * attn_batches,
                          head_dim,
                          attn_batches);
  })
}

void BackwardInterleavedMatMulSelfAttValAttGPU(const nnvm::NodeAttrs& attrs,
                                               const OpContext &ctx,
                                               const std::vector<TBlob> &inputs,
                                               const std::vector<OpReqType> &req,
                                               const std::vector<TBlob> &outputs) {
  const auto& params = nnvm::get<InterleavedMatMulParam>(attrs.parsed);
  mshadow::Stream<gpu>* s = ctx.get_stream<gpu>();
  MSHADOW_REAL_TYPE_SWITCH(inputs[0].type_flag_, DType, {
    const DType* output_grads              = inputs[0].FlatTo2D<gpu, DType>(s).dptr_;
    const DType* queries_keys_values       = inputs[1].FlatTo2D<gpu, DType>(s).dptr_;
    const DType* attention_maps            = inputs[2].FlatTo2D<gpu, DType>(s).dptr_;
    DType* queries_keys_values_grads       = outputs[0].FlatTo2D<gpu, DType>(s).dptr_;
    DType* attention_maps_grads            = outputs[1].FlatTo2D<gpu, DType>(s).dptr_;
    const int32_t qkv_seq_len    = inputs[1].shape_[0];
    const int32_t sequences      = inputs[1].shape_[1];
    const int32_t output_lin_dim = inputs[1].shape_[2];
    const int32_t embed_dim      = output_lin_dim / 3;
    const int32_t head_dim       = embed_dim / params.heads;
    const int32_t attn_batches   = params.heads * sequences;
    const int32_t lead_dim       = attn_batches * 3 * head_dim;
    const int32_t batch_stride   = 3 * head_dim;
    const float alpha            = 1.f;
    if (req[0] != kNullOp) {
      if (req[0] == kWriteTo && !params.bwd_ignore_zero_init) {
        cudaMemsetAsync(queries_keys_values_grads, 0, outputs[0].shape_.Size() * sizeof(DType),
                        mshadow::Stream<gpu>::GetStream(s));
      }
      const float beta = ((req[0] == kAddTo) && !params.bwd_ignore_zero_init) ? 1.f : 0.f;
      gemm_switch_fp32accum(s,
                            false,
                            true,
                            head_dim,
                            qkv_seq_len,
                            qkv_seq_len,
                            alpha,
                            output_grads,
                            head_dim * attn_batches,
                            head_dim,
                            attention_maps,
                            qkv_seq_len,
                            qkv_seq_len * qkv_seq_len,
                            beta,
                            queries_keys_values_grads + 2 * head_dim,
                            lead_dim,
                            batch_stride,
                            attn_batches);
    }
    if (req[1] != kNullOp) {
      const float beta = req[1] == kAddTo ? 1.f : 0.f;
      gemm_switch_fp32accum(s,
                            true,
                            false,
                            qkv_seq_len,
                            qkv_seq_len,
                            head_dim,
                            alpha,
                            queries_keys_values + 2 * head_dim,
                            lead_dim,
                            batch_stride,
                            output_grads,
                            head_dim * attn_batches,
                            head_dim,
                            beta,
                            attention_maps_grads,
                            qkv_seq_len,
                            qkv_seq_len * qkv_seq_len,
                            attn_batches);
    }
  })
}


void InterleavedMatMulEncDecQKGPU(const nnvm::NodeAttrs& attrs,
                                  const OpContext &ctx,
                                  const std::vector<TBlob> &inputs,
                                  const std::vector<OpReqType> &req,
                                  const std::vector<TBlob> &outputs) {
  const auto& params = nnvm::get<InterleavedMatMulParam>(attrs.parsed);
  mshadow::Stream<gpu>* s = ctx.get_stream<gpu>();
  MSHADOW_REAL_TYPE_SWITCH(inputs[0].type_flag_, DType, {
    const DType* queries     = inputs[0].FlatTo2D<gpu, DType>(s).dptr_;
    const DType* keys_values = inputs[1].FlatTo2D<gpu, DType>(s).dptr_;
    DType* output            = outputs[0].FlatTo2D<gpu, DType>(s).dptr_;
    const int32_t q_seq_len         = inputs[0].shape_[0];
    const int32_t sequences         = inputs[0].shape_[1];
    const int32_t output_lin_q_dim  = inputs[0].shape_[2];
    const int32_t kv_seq_len        = inputs[1].shape_[0];
    const int32_t output_lin_kv_dim = inputs[1].shape_[2];
    const int32_t embed_dim         = output_lin_q_dim;
    const int32_t head_dim          = embed_dim / params.heads;
    const int32_t attn_batches      = params.heads * sequences;
    const int32_t lead_dim_q        = attn_batches * head_dim;
    const int32_t lead_dim_kv       = attn_batches * 2 * head_dim;
    const int32_t batch_stride_q    = head_dim;
    const int32_t batch_stride_kv   = head_dim * 2;
    const float beta                = req[0] == kAddTo ? 1.f : 0.f;
    const float scale               = 1.f / sqrt(static_cast<float>(head_dim));

    if (req[0] == kNullOp)
      return;

    gemm_switch_fp32accum(s,
                          true,
                          false,
                          kv_seq_len,
                          q_seq_len,
                          head_dim,
                          scale,
                          keys_values,
                          lead_dim_kv,
                          batch_stride_kv,
                          queries,
                          lead_dim_q,
                          batch_stride_q,
                          beta,
                          output,
                          kv_seq_len,
                          kv_seq_len * q_seq_len,
                          attn_batches);
  })
}

void BackwardInterleavedMatMulEncDecQKGPU(const nnvm::NodeAttrs& attrs,
                                          const OpContext &ctx,
                                          const std::vector<TBlob> &inputs,
                                          const std::vector<OpReqType> &req,
                                          const std::vector<TBlob> &outputs) {
  const auto& params = nnvm::get<InterleavedMatMulParam>(attrs.parsed);
  mshadow::Stream<gpu>* s = ctx.get_stream<gpu>();
  MSHADOW_REAL_TYPE_SWITCH(inputs[0].type_flag_, DType, {
    const DType* output_grads = inputs[0].FlatTo2D<gpu, DType>(s).dptr_;
    const DType* queries       = inputs[1].FlatTo2D<gpu, DType>(s).dptr_;
    const DType* keys_values   = inputs[2].FlatTo2D<gpu, DType>(s).dptr_;
    DType* queries_grads       = outputs[0].FlatTo2D<gpu, DType>(s).dptr_;
    DType* keys_values_grads   = outputs[1].FlatTo2D<gpu, DType>(s).dptr_;
    const int32_t q_seq_len         = inputs[1].shape_[0];
    const int32_t sequences         = inputs[1].shape_[1];
    const int32_t output_lin_q_dim  = inputs[1].shape_[2];
    const int32_t kv_seq_len        = inputs[2].shape_[0];
    const int32_t output_lin_kv_dim = inputs[2].shape_[2];
    const int32_t embed_dim         = output_lin_q_dim;
    const int32_t head_dim          = embed_dim / params.heads;
    const int32_t attn_batches      = params.heads * sequences;
    const int32_t lead_dim_q        = attn_batches * head_dim;
    const int32_t lead_dim_kv       = attn_batches * 2 * head_dim;
    const int32_t batch_stride_q    = head_dim;
    const int32_t batch_stride_kv   = head_dim * 2;
    const float scale               = 1.f / sqrt(static_cast<float>(head_dim));

    if (req[0] != kNullOp) {
      const float beta = req[0] == kAddTo ? 1.f : 0.f;
      gemm_switch_fp32accum(s,
                            false,
                            false,
                            head_dim,
                            q_seq_len,
                            kv_seq_len,
                            scale,
                            keys_values,
                            lead_dim_kv,
                            batch_stride_kv,
                            output_grads,
                            kv_seq_len,
                            kv_seq_len * q_seq_len,
                            beta,
                            queries_grads,
                            lead_dim_q,
                            batch_stride_q,
                            attn_batches);
    }
    if (req[1] != kNullOp) {
      if (req[1] == kWriteTo && !params.bwd_ignore_zero_init) {
        cudaMemsetAsync(keys_values_grads, 0, outputs[1].shape_.Size() * sizeof(DType),
                        mshadow::Stream<gpu>::GetStream(s));
      }
      const float beta = ((req[1] == kAddTo) && !params.bwd_ignore_zero_init) ? 1.f : 0.f;
      gemm_switch_fp32accum(s,
                            false,
                            true,
                            head_dim,
                            kv_seq_len,
                            q_seq_len,
                            scale,
                            queries,
                            lead_dim_q,
                            batch_stride_q,
                            output_grads,
                            kv_seq_len,
                            kv_seq_len * q_seq_len,
                            beta,
                            keys_values_grads,
                            lead_dim_kv,
                            batch_stride_kv,
                            attn_batches);
    }
  })
}

void InterleavedMatMulEncDecValAttGPU(const nnvm::NodeAttrs& attrs,
                                      const OpContext &ctx,
                                      const std::vector<TBlob> &inputs,
                                      const std::vector<OpReqType> &req,
                                      const std::vector<TBlob> &outputs) {
  const auto& params = nnvm::get<InterleavedMatMulParam>(attrs.parsed);
  mshadow::Stream<gpu>* s = ctx.get_stream<gpu>();
  MSHADOW_REAL_TYPE_SWITCH(inputs[0].type_flag_, DType, {
    const DType* keys_values    = inputs[0].FlatTo2D<gpu, DType>(s).dptr_;
    const DType* attention_maps = inputs[1].FlatTo2D<gpu, DType>(s).dptr_;
    DType* output               = outputs[0].FlatTo2D<gpu, DType>(s).dptr_;
    const int32_t kv_seq_len        = inputs[0].shape_[0];
    const int32_t sequences         = inputs[0].shape_[1];
    const int32_t output_lin_kv_dim = inputs[0].shape_[2];
    const int32_t attn_batches      = inputs[1].shape_[0];
    const int32_t q_seq_len         = inputs[1].shape_[1];
    const int32_t embed_dim         = output_lin_kv_dim / 2;
    int32_t head_dim                = embed_dim / params.heads;
    const int32_t lead_dim_kv       = attn_batches * head_dim * 2;
    const int32_t batch_stride_kv   = 2 * head_dim;
    const float alpha               = 1.f;
    const float beta                = req[0] == kAddTo ? 1.f : 0.f;

    if (req[0] == kNullOp)
      return;

    gemm_switch_fp32accum(s,
                          false,
                          false,
                          head_dim,
                          q_seq_len,
                          kv_seq_len,
                          alpha,
                          keys_values + head_dim,
                          lead_dim_kv,
                          batch_stride_kv,
                          attention_maps,
                          kv_seq_len,
                          kv_seq_len * q_seq_len,
                          beta,
                          output,
                          head_dim * attn_batches,
                          head_dim,
                          attn_batches);
  })
}

void BackwardInterleavedMatMulEncDecValAttGPU(const nnvm::NodeAttrs& attrs,
                                              const OpContext &ctx,
                                              const std::vector<TBlob> &inputs,
                                              const std::vector<OpReqType> &req,
                                              const std::vector<TBlob> &outputs) {
  const auto& params = nnvm::get<InterleavedMatMulParam>(attrs.parsed);
  mshadow::Stream<gpu>* s = ctx.get_stream<gpu>();
  MSHADOW_REAL_TYPE_SWITCH(inputs[0].type_flag_, DType, {
    const DType* output_grads   = inputs[0].FlatTo2D<gpu, DType>(s).dptr_;
    const DType* keys_values    = inputs[1].FlatTo2D<gpu, DType>(s).dptr_;
    const DType* attention_maps = inputs[2].FlatTo2D<gpu, DType>(s).dptr_;
    DType* keys_values_grads    = outputs[0].FlatTo2D<gpu, DType>(s).dptr_;
    DType* attention_maps_grads = outputs[1].FlatTo2D<gpu, DType>(s).dptr_;
    const int32_t kv_seq_len        = inputs[1].shape_[0];
    const int32_t sequences         = inputs[1].shape_[1];
    const int32_t output_lin_kv_dim = inputs[1].shape_[2];
    const int32_t attn_batches      = inputs[2].shape_[0];
    const int32_t q_seq_len         = inputs[2].shape_[1];
    const int32_t embed_dim         = output_lin_kv_dim / 2;
    int32_t head_dim                = embed_dim / params.heads;
    const int32_t lead_dim_kv       = attn_batches * head_dim * 2;
    const int32_t batch_stride_kv   = 2 * head_dim;
    const float alpha               = 1.f;

    if (req[0] != kNullOp) {
      if (req[0] == kWriteTo && !params.bwd_ignore_zero_init) {
        cudaMemsetAsync(keys_values_grads, 0, outputs[0].shape_.Size() * sizeof(DType),
                        mshadow::Stream<gpu>::GetStream(s));
      }
      const float beta = ((req[0] == kAddTo) && !params.bwd_ignore_zero_init) ? 1.f : 0.f;
      gemm_switch_fp32accum(s,
                            false,
                            true,
                            head_dim,
                            kv_seq_len,
                            q_seq_len,
                            alpha,
                            output_grads,
                            head_dim * attn_batches,
                            head_dim,
                            attention_maps,
                            kv_seq_len,
                            kv_seq_len * q_seq_len,
                            beta,
                            keys_values_grads + head_dim,
                            lead_dim_kv,
                            batch_stride_kv,
                            attn_batches);
    }
    if (req[1] != kNullOp) {
      const float beta = req[1] == kAddTo ? 1.f : 0.f;
      gemm_switch_fp32accum(s,
                            true,
                            false,
                            kv_seq_len,
                            q_seq_len,
                            head_dim,
                            alpha,
                            keys_values + head_dim,
                            lead_dim_kv,
                            batch_stride_kv,
                            output_grads,
                            head_dim * attn_batches,
                            head_dim,
                            beta,
                            attention_maps_grads,
                            kv_seq_len,
                            kv_seq_len * q_seq_len,
                            attn_batches);
    }
  })
}

NNVM_REGISTER_OP(interleaved_matmul_selfatt_qk)
.set_attr<FCompute>("FCompute<gpu>", InterleavedMatMulSelfAttQKGPU);

NNVM_REGISTER_OP(interleaved_matmul_selfatt_valatt)
.set_attr<FCompute>("FCompute<gpu>", InterleavedMatMulSelfAttValAttGPU);

NNVM_REGISTER_OP(interleaved_matmul_encdec_qk)
.set_attr<FCompute>("FCompute<gpu>", InterleavedMatMulEncDecQKGPU);

NNVM_REGISTER_OP(interleaved_matmul_encdec_valatt)
.set_attr<FCompute>("FCompute<gpu>", InterleavedMatMulEncDecValAttGPU);

NNVM_REGISTER_OP(_backward_interleaved_matmul_selfatt_qk)
.set_attr<FCompute>("FCompute<gpu>", BackwardInterleavedMatMulSelfAttQKGPU);

NNVM_REGISTER_OP(_backward_interleaved_matmul_selfatt_valatt)
.set_attr<FCompute>("FCompute<gpu>", BackwardInterleavedMatMulSelfAttValAttGPU);

NNVM_REGISTER_OP(_backward_interleaved_matmul_encdec_qk)
.set_attr<FCompute>("FCompute<gpu>", BackwardInterleavedMatMulEncDecQKGPU);

NNVM_REGISTER_OP(_backward_interleaved_matmul_encdec_valatt)
.set_attr<FCompute>("FCompute<gpu>", BackwardInterleavedMatMulEncDecValAttGPU);

// relu
NNVM_REGISTER_OP(_contrib_div_sqrt_dim)
.set_attr<FCompute>("FCompute<gpu>", DivSqrtDimForward_<gpu>);

}  // namespace op
}  // namespace mxnet
