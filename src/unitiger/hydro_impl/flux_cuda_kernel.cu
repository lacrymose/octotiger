#ifdef OCTOTIGER_HAVE_CUDA

#include <buffer_manager.hpp>
#include <cuda_buffer_util.hpp>
#include "octotiger/options.hpp"
#include "octotiger/cuda_util/cuda_helper.hpp"
#include <cuda_runtime.h>
#include <stream_manager.hpp>

#include "octotiger/unitiger/hydro_impl/flux_kernel_interface.hpp"

#include <mutex>

__device__ inline int flip_dim(const int d, const int flip_dim) {
		int dims[3];
		int k = d;
		for (int dim = 0; dim < 3; dim++) {
			dims[dim] = k % 3;
			k /= 3;
		}
		k = 0;
		dims[flip_dim] = 2 - dims[flip_dim];
		for (int dim = 0; dim < 3; dim++) {
			k *= 3;
			k += dims[2 - dim];
		}
		return k;
}

__device__ const int faces[3][9] = { { 12, 0, 3, 6, 9, 15, 18, 21, 24 }, { 10, 0, 1, 2, 9, 11,
			18, 19, 20 }, { 4, 0, 1, 2, 3, 5, 6, 7, 8 } };

__device__ const int xloc[27][3] = {
	/**/{ -1, -1, -1 }, { +0, -1, -1 }, { +1, -1, -1 },
	/**/{ -1, +0, -1 }, { +0, +0, -1 }, { 1, +0, -1 },
	/**/{ -1, +1, -1 }, { +0, +1, -1 }, { +1, +1, -1 },
	/**/{ -1, -1, +0 }, { +0, -1, +0 }, { +1, -1, +0 },
	/**/{ -1, +0, +0 }, { +0, +0, +0 }, { +1, +0, +0 },
	/**/{ -1, +1, +0 }, { +0, +1, +0 }, { +1, +1, +0 },
	/**/{ -1, -1, +1 }, { +0, -1, +1 }, { +1, -1, +1 },
	/**/{ -1, +0, +1 }, { +0, +0, +1 }, { +1, +0, +1 },
	/**/{ -1, +1, +1 }, { +0, +1, +1 }, { +1, +1, +1 } };

__device__ const double quad_weights[9] = { 16. / 36., 1. / 36., 4. / 36., 1. / 36., 4. / 36., 4.
			/ 36., 1. / 36., 4. / 36., 1. / 36. };

std::once_flag flag1;

__host__ void init_gpu_masks(bool *masks) {
  auto masks_boost = create_masks();
  cudaMemcpy(masks, masks_boost.data(), NDIM * 1000 * sizeof(bool), cudaMemcpyHostToDevice);
}

__host__ const bool* get_gpu_masks(void) {
    static recycler::cuda_device_buffer<bool> masks(NDIM * 1000, 0);
    std::call_once(flag1, init_gpu_masks, masks.device_side_buffer);
    return masks.device_side_buffer;
}

__device__ const int offset = 0;
__device__ const int compressedH_DN[3] = {100, 10, 1};
__device__ const int face_offset = 27 * 1000;
__device__ const int dim_offset = 1000;

__global__ void
__launch_bounds__(900, 1)
 flux_cuda_kernel(const double * __restrict__ q_combined, const double * __restrict__ x_combined, double * __restrict__ f_combined,
    double * amax, int * amax_indices, int * amax_d, const bool * __restrict__ masks, const double omega, const double dx, const double A_, const double B_, const double fgamma, const double de_switch_1) {
  __shared__ double sm_amax[900];
  __shared__ int sm_d[900];
  __shared__ int sm_i[900];

  // 3 dim 1000 i workitems
  const int dim = blockIdx.z;
  const int index = threadIdx.x * 100 + threadIdx.y * 10 + threadIdx.z + 100;
  int tid = index - 100;   
  //if(tid == 0)
  // printf("starting...");
  const int nf = 15;

  double local_f[15] = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0};
  double local_x[3] = {0.0, 0.0, 0.0};
  double local_vg[3] = {0.0, 0.0, 0.0};
  for (int f = 0; f < nf; f++) {
      f_combined[dim * 15 * 1000 + f * 1000 + index] = 0.0;
  }

  double mask = masks[index + dim * dim_offset];
  double current_amax = 0.0;
  int current_d = 0;
  for (int fi = 0; fi < 9; fi++) {    // 9
    double this_ap = 0.0, this_am = 0.0;    // tmps
    const int d = faces[dim][fi];
    const int flipped_dim = flip_dim(d, dim);
    for (int dim = 0; dim < 3; dim++) {
        local_x[dim] = x_combined[dim * 1000 + index] + (0.5 * xloc[d][dim] * dx);
    }
    local_vg[0] = -omega * (x_combined[1000 + index] + 0.5 * xloc[d][1] * dx);
    local_vg[1] = +omega * (x_combined[index] + 0.5 * xloc[d][0] * dx);
    local_vg[2] = 0.0;
    /*if (index == 111 && dim == 0) {
      printf("CUDAInput: Q1i %i Q2i %i :: X2 %f X1 %f X0 %f :: vg2 %f vg1 %f vg0 %f dx: %f\n",dim_offset * d + index,  dim_offset * flipped_dim - compressedH_DN[dim] + index, local_x[2], local_x[1], local_x[0], local_vg[2], local_vg[1], local_vg[0] ,dx);
    }*/
    inner_flux_loop2<double>(omega, nf, A_, B_, q_combined, local_f, local_x, local_vg,
      this_ap, this_am, dim, d, dx, fgamma, de_switch_1, dim_offset * d + index, dim_offset * flipped_dim - compressedH_DN[dim] + index, face_offset);
    this_ap *= mask;
    this_am *= mask;
    const double amax_tmp = max_wrapper(this_ap, (-this_am));
    if (amax_tmp > current_amax) {
      current_amax = amax_tmp;
      current_d = d;
    }
    for (int f = 0; f < nf; f++) {
      f_combined[dim * 15 * 1000 + f * 1000 + index] += quad_weights[fi] * local_f[f] * mask;
    }
 }

 // Find maximum:
 sm_amax[tid] = current_amax;
 sm_d[tid] = current_d;
 sm_i[tid] = tid;
 __syncthreads();
 // First step as we do not have multiples of 2
 if(tid < 450) {
   if (sm_amax[tid + 450 ] > sm_amax[tid]) {
     sm_amax[tid] = sm_amax[tid + 450];
     sm_d[tid] = sm_d[tid + 450];
     sm_i[tid] = sm_i[tid + 450];
   }
 }
 __syncthreads();
 // Max reduction with multiple warps
 for (int tid_border = 256; tid_border >= 32; tid_border /= 2) {
   if(tid < tid_border) {
     if (sm_amax[tid + tid_border] > sm_amax[tid]) {
       sm_amax[tid] = sm_amax[tid + tid_border];
       sm_d[tid] = sm_d[tid + tid_border];
       sm_i[tid] = sm_i[tid + tid_border];
     }
   }
   __syncthreads();
 }
 // Max reduction within one warps
 for (int tid_border = 16; tid_border >= 1; tid_border /= 2) {
   if(tid < tid_border) {
     if (sm_amax[tid + tid_border] > sm_amax[tid]) {
       sm_amax[tid] = sm_amax[tid + tid_border];
       sm_d[tid] = sm_d[tid + tid_border];
       sm_i[tid] = sm_i[tid + tid_border];
     }
   }
 }

 if (tid == 0) {
   amax[dim] = sm_amax[0];
   amax_indices[dim] = sm_i[0];
   amax_d[dim] = sm_d[0];
 //printf("%i dim: %f %i %i \n", dim, amax[dim], amax_indices[dim], amax_d[dim]);
 }


 return;
}

timestep_t launch_flux_cuda(const hydro::recon_type<NDIM>& Q, hydro::flux_type& F, hydro::x_type& X,
    safe_real omega, const size_t nf_) {
    timestep_t ts;

    // Check availability
    bool avail = stream_pool::interface_available<hpx::cuda::experimental::cuda_executor,
                 pool_strategy>(opts().cuda_buffer_capacity);
  
    // Call CPU kernel as no stream is free
    if (!avail) {
       return flux_cpu_kernel(Q, F, X, omega, nf_);
    } else {

    size_t device_id =
      stream_pool::get_next_device_id<hpx::cuda::experimental::cuda_executor,
      pool_strategy>();

    stream_interface<hpx::cuda::experimental::cuda_executor, pool_strategy> executor;

    std::vector<double, recycler::recycle_allocator_cuda_host<double>> combined_q(
        15 * 27 * 10 * 10 * 10 + 32);
    auto it = combined_q.begin();
    for (auto face = 0; face < 15; face++) {
        for (auto d = 0; d < 27; d++) {
            auto start_offset = 2 * 14 * 14 + 2 * 14 + 2;
            for (auto ix = 2; ix < 2 + INX + 2; ix++) {
                for (auto iy = 2; iy < 2 + INX + 2; iy++) {
                    it = std::copy(Q[face][d].begin() + start_offset,
                        Q[face][d].begin() + start_offset + 10, it);
                    start_offset += 14;
                }
                start_offset += (2 + 2) * 14;
            }
        }
    }
    recycler::cuda_device_buffer<double> device_q(15 * 27 * 10 * 10 * 10 + 32, device_id);
    hpx::apply(static_cast<hpx::cuda::experimental::cuda_executor>(executor),
    cudaMemcpyAsync, device_q.device_side_buffer,
    combined_q.data(), (15 * 27 * 10 * 10 * 10 + 32) * sizeof(double), cudaMemcpyHostToDevice);

    std::vector<double, recycler::recycle_allocator_cuda_host<double>> combined_x(NDIM * 1000 + 32);
    auto it_x = combined_x.begin();
    for (size_t dim = 0; dim < NDIM; dim++) {
      auto start_offset = 2 * 14 * 14 + 2 * 14 + 2;
      for (auto ix = 2; ix < 2 + INX + 2; ix++) {
          for (auto iy = 2; iy < 2 + INX + 2; iy++) {
              it_x = std::copy(X[dim].begin() + start_offset,
                  X[dim].begin() + start_offset + 10, it_x);
              start_offset += 14;
          }
          start_offset += (2 + 2) * 14;
      }
    }
    const cell_geometry<3, 8> geo;
    double dx = X[0][geo.H_DNX] - X[0][0];
    recycler::cuda_device_buffer<double> device_x(NDIM * 1000 + 32, device_id);
    hpx::apply(static_cast<hpx::cuda::experimental::cuda_executor>(executor),
    cudaMemcpyAsync, device_x.device_side_buffer,
    combined_x.data(), (NDIM * 1000 + 32) * sizeof(double), cudaMemcpyHostToDevice);

    std::vector<double, recycler::recycle_allocator_cuda_host<double>> combined_f(NDIM * 15 * 1000 + 32);
    recycler::cuda_device_buffer<double> device_f(NDIM * 15 * 1000 + 32, device_id);
    const bool *masks = get_gpu_masks();

    recycler::cuda_device_buffer<double> device_amax(NDIM);
    recycler::cuda_device_buffer<int> device_amax_indices(NDIM);
    recycler::cuda_device_buffer<int> device_amax_d(NDIM);
    double A_ = physics<NDIM>::A_;
    double B_ = physics<NDIM>::B_;
    double fgamma = physics<NDIM>::fgamma_;
    double de_switch_1 = physics<NDIM>::de_switch_1;

    dim3 const grid_spec(1, 1, 3);
    dim3 const threads_per_block(9, 10, 10);
    void* args[] = {&(device_q.device_side_buffer),
      &(device_x.device_side_buffer), &(device_f.device_side_buffer), &(device_amax.device_side_buffer),
      &(device_amax_indices.device_side_buffer), &(device_amax_d.device_side_buffer), &masks, &omega, &dx, &A_, &B_, &fgamma, &de_switch_1};
    executor.post(
    cudaLaunchKernel<decltype(flux_cuda_kernel)>,
    flux_cuda_kernel, grid_spec, threads_per_block, args, 0);

    // Move data to host
    std::vector<double, recycler::recycle_allocator_cuda_host<double>> amax(NDIM);
    std::vector<int, recycler::recycle_allocator_cuda_host<int>> amax_indices(NDIM);
    std::vector<int, recycler::recycle_allocator_cuda_host<int>> amax_d(NDIM);
    hpx::apply(static_cast<hpx::cuda::experimental::cuda_executor>(executor),
               cudaMemcpyAsync, amax.data(),
               device_amax.device_side_buffer, NDIM * sizeof(double),
               cudaMemcpyDeviceToHost);
    hpx::apply(static_cast<hpx::cuda::experimental::cuda_executor>(executor),
               cudaMemcpyAsync, amax_indices.data(),
               device_amax_indices.device_side_buffer, NDIM * sizeof(int),
               cudaMemcpyDeviceToHost);
    hpx::apply(static_cast<hpx::cuda::experimental::cuda_executor>(executor),
               cudaMemcpyAsync, amax_d.data(),
               device_amax_d.device_side_buffer, NDIM * sizeof(int),
               cudaMemcpyDeviceToHost);
    auto fut = hpx::async(static_cast<hpx::cuda::experimental::cuda_executor>(executor),
               cudaMemcpyAsync, combined_f.data(), device_f.device_side_buffer,
               (NDIM * 15 * 1000 + 32) * sizeof(double), cudaMemcpyDeviceToHost);
    fut.get();
    /*std::cout << "cuda kernel:" << std::endl;
    for (size_t dim = 0; dim < 1; dim++) {
        for (auto face = 0; face < 1; face++) {
          for (auto i = 111; i < 120; i++) {
            std::cout << combined_f[i] << " ";
          }
        }
        std::cout << std::endl << std::endl;
    } 
    hpx::apply(static_cast<hpx::cuda::experimental::cuda_executor>(executor),
               cudaStreamSynchronize);
    std::cout << "ended cuda kernel:" << std::endl;
    std::cin.get();*/
    // Convert data back to Octo-Tiger format
    for (size_t dim = 0; dim < NDIM; dim++) {
        for (auto face = 0; face < 15; face++) {
            auto face_offset = dim * 15 * 1000 + face * 1000;
            auto start_offset = 2 * 14 * 14 + 2 * 14 + 2;
            auto compressed_offset = 0;
            for (auto ix = 2; ix < 2 + INX + 2; ix++) {
                for (auto iy = 2; iy < 2 + INX + 2; iy++) {
                    std::copy(combined_f.begin() + face_offset + compressed_offset,
                        combined_f.begin() + face_offset + compressed_offset + 10,
                        F[dim][face].data() + start_offset);
                    compressed_offset += 10;
                    start_offset += 14;
                }
                start_offset += (2 + 2) * 14;
            }
        }
    }
    // Find Maximum
    size_t current_dim = 0;
    for (size_t dim_i = 1; dim_i < NDIM; dim_i++) {
      if (amax[dim_i] > amax[current_dim]) { 
        current_dim = dim_i;
      }
    }
    //std::cin.get();
    static thread_local std::vector<double> URs(nf_), ULs(nf_);
    const size_t current_max_index = amax_indices[current_dim];
    const size_t current_d = amax_d[current_dim];
    ts.a = amax[current_dim];
    ts.x = combined_x[current_max_index];
    ts.y = combined_x[current_max_index + 1000];
    ts.z = combined_x[current_max_index + 2000];
    const auto flipped_dim = geo.flip_dim(current_d, current_dim);
    constexpr int compressedH_DN[3] = {100, 10, 1};
    for (int f = 0; f < nf_; f++) {
        URs[f] = combined_q[current_max_index + f * face_offset + dim_offset * current_d];
        ULs[f] = combined_q[current_max_index - compressedH_DN[current_dim] + f * face_offset +
            dim_offset * flipped_dim];
    }
    ts.ul = ULs;
    ts.ur = URs;
    ts.dim = current_dim;
    return ts;
    }
}


#endif