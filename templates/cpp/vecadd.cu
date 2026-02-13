// Vector add example for the `templates/cpp` CUDA dev shell.
//
// Build + run:
//   nix develop path:. -c bash -lc 'nvcc -O2 vecadd.cu -o vecadd && ./vecadd'
//
// Notes:
// - Uses Unified Memory (cudaMallocManaged) to keep the example simple.
// - Requires a working NVIDIA driver (`libcuda.so.1`) on the host.

#include <cuda_runtime.h>

#include <cmath>
#include <cstddef>
#include <cstdio>

static void cudaCheck(cudaError_t err, const char* expr, const char* file, int line) {
  if (err == cudaSuccess) {
    return;
  }
  std::fprintf(
      stderr, "CUDA error: %s (%d)\n  expr: %s\n  at: %s:%d\n", cudaGetErrorString(err), (int)err, expr, file, line);
  std::fflush(stderr);
  std::abort();
}

#define CUDA_CHECK(expr) cudaCheck((expr), #expr, __FILE__, __LINE__)

__global__ void vecAddKernel(const float* a, const float* b, float* out, std::size_t n) {
  std::size_t idx = (std::size_t)blockIdx.x * (std::size_t)blockDim.x + (std::size_t)threadIdx.x;
  if (idx < n) {
    out[idx] = a[idx] + b[idx];
  }
}

int main() {
  int deviceCount = 0;
  CUDA_CHECK(cudaGetDeviceCount(&deviceCount));
  if (deviceCount <= 0) {
    std::fprintf(stderr, "No CUDA devices detected.\n");
    return 1;
  }

  const int device = 0;
  CUDA_CHECK(cudaSetDevice(device));

  cudaDeviceProp prop{};
  CUDA_CHECK(cudaGetDeviceProperties(&prop, device));
  std::printf("Using GPU %d: %s (cc %d.%d)\n", device, prop.name, prop.major, prop.minor);

  const std::size_t n = 1u << 20;  // ~1M elements
  const std::size_t bytes = n * sizeof(float);

  float* a = nullptr;
  float* b = nullptr;
  float* out = nullptr;
  CUDA_CHECK(cudaMallocManaged(&a, bytes));
  CUDA_CHECK(cudaMallocManaged(&b, bytes));
  CUDA_CHECK(cudaMallocManaged(&out, bytes));

  for (std::size_t i = 0; i < n; i++) {
    a[i] = std::sin((double)i) * 0.5f;
    b[i] = std::cos((double)i) * 0.5f;
    out[i] = 0.0f;
  }

  const int threads = 256;
  const int blocks = (int)((n + (std::size_t)threads - 1) / (std::size_t)threads);
  vecAddKernel<<<blocks, threads>>>(a, b, out, n);
  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaDeviceSynchronize());

  std::size_t mismatches = 0;
  for (std::size_t i = 0; i < n; i++) {
    const float expected = a[i] + b[i];
    const float got = out[i];
    const float diff = std::fabs(got - expected);
    if (diff > 1e-5f) {
      mismatches++;
      if (mismatches <= 5) {
        std::fprintf(stderr, "Mismatch at %zu: expected=%f got=%f diff=%f\n", i, expected, got, diff);
      }
    }
  }

  if (mismatches == 0) {
    std::printf("OK: %zu elements\n", n);
  } else {
    std::fprintf(stderr, "FAIL: %zu mismatches\n", mismatches);
  }

  CUDA_CHECK(cudaFree(out));
  CUDA_CHECK(cudaFree(b));
  CUDA_CHECK(cudaFree(a));
  return mismatches == 0 ? 0 : 2;
}

