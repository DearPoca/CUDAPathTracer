

#include <iostream>
#include <utility>

#include "bvh.h"
#include "object.h"
#include "path_tracer.h"
#include "textures.h"

struct PathTracerParams {
    int width, height;
    cudaTextureObject_t sky_tex_obj;

    // Object** scene;
    // uint scene_size;
    BVHNode* bvh_root;

    uint spp;
    uint max_recursion_depth;

    MotionalCamera* camera;
    uint8_t* output_buffer_gpu_handle;
    float* depth_info_buffer;
    Float4* normal_info_buffer;
    Float4* render_target;

    curandState* d_rng_states;
};

struct DenoisingParams {
    int width, height;
    float* depth_info_buffer;
    Float4* normal_info_buffer;
    Float4* render_target;
    uint8_t* output_buffer;
};

__device__ void MissShader(Ray& ray, RayPayload& payload) {
    Float4 d = poca_mus::GetNormalizeVec(ray.dir);
    float v = asin(d.z) / M_PI + 0.5, u = atan(d.y / d.x) / 2 / M_PI;
    payload.radiance = poca_mus::GetTex2D(payload.sky_tex_obj, u, v);
    payload.recursion_depth = MMAX_RECURSION_DEPTH;
}

void PathTracer::AddObject(Object* obj) { objs_.push_back(obj); }

// __device__ void TraceRay(PathTracerParams& params, Ray& ray, RayPayload& payload) {
//     poca_mus::Normalize(ray.dir);
//     IntersectionAttributes attr;
//     Object* closet_hit_obj = poca_mus::TraceRay(params.bvh_root, ray, attr);
//     if (closet_hit_obj != nullptr) {
//         closet_hit_obj->ClosetHit(*closet_hit_obj, ray, payload, attr);
//     } else {
//         MissShader(ray, payload);
//     }
// }

void PathTracer::AddMeterial(Material* material) { materials_.push_back(material); }

void PathTracer::SetCamera(MotionalCamera* camera) { this->camera_ = camera; }

void PathTracer::ReSize(int width, int height) {
    this->width_ = width;
    this->height_ = height;
}
void PathTracer::SetSamplePerPixel(uint spp) { spp_ = spp; }

__global__ void SamplePixel(PathTracerParams params) {
    uint x = blockIdx.x * blockDim.x + threadIdx.x;
    uint y = blockIdx.y * blockDim.y + threadIdx.y;
    uint offset = y * params.width + x;
    Float4 radiance = 0.0f;
    Float4 normals = 0.0f;
    float depth = 0.0f;
    // curand_init(offset, 0, 0, &(params.d_rng_states[offset]));
    for (uint i = 0; i < params.spp; ++i) {
        Ray ray = params.camera->RayGen(x, y, &(params.d_rng_states[offset]));
        RayPayload payload;
        Float4 attenuation = 1.0f;
        payload.recursion_depth = 0;
        payload.d_rng_states = &params.d_rng_states[offset];
        payload.sky_tex_obj = params.sky_tex_obj;

        // ??????????????????????????????????????????
        {
            poca_mus::Normalize(ray.dir);

            IntersectionAttributes attr;
            Object* closet_hit_obj = poca_mus::TraceRay(params.bvh_root, ray, attr);

            if (closet_hit_obj != nullptr) {
                closet_hit_obj->ClosetHit(*closet_hit_obj, ray, payload, attr);
            } else {
                attr.normal = -ray.dir;
                MissShader(ray, payload);
            }

            radiance += attenuation * payload.radiance;
            attenuation *= payload.attenuation;

            normals += attr.normal;
            depth += ray.tmax;

            ray.origin = payload.hit_pos;
            ray.dir = payload.bounce_dir;
            poca_mus::Normalize(ray.dir);
            ray.tmin = BOUNCE_RAY_TMIN;
            ray.tmax = DEFAULT_RAY_TMAX;
            payload.recursion_depth++;
        }

        while (payload.recursion_depth < params.max_recursion_depth) {
            poca_mus::Normalize(ray.dir);

            IntersectionAttributes attr;
            Object* closet_hit_obj = poca_mus::TraceRay(params.bvh_root, ray, attr);

            if (closet_hit_obj != nullptr) {
                closet_hit_obj->ClosetHit(*closet_hit_obj, ray, payload, attr);
            } else {
                MissShader(ray, payload);
            }

            radiance += attenuation * payload.radiance;
            attenuation *= payload.attenuation;

            ray.origin = payload.hit_pos;
            ray.dir = payload.bounce_dir;
            poca_mus::Normalize(ray.dir);
            ray.tmin = BOUNCE_RAY_TMIN;
            ray.tmax = DEFAULT_RAY_TMAX;
            payload.recursion_depth++;
        }
    }
    params.render_target[offset] = radiance / float(params.spp);
    params.depth_info_buffer[offset] = depth / float(params.spp);
    params.normal_info_buffer[offset] = normals / float(params.spp);
    // params.output_buffer_gpu_handle[offset * 3 + 0] = int(radiance.x / float(params.spp) * 255.99);
    // params.output_buffer_gpu_handle[offset * 3 + 1] = int(radiance.y / float(params.spp) * 255.99);
    // params.output_buffer_gpu_handle[offset * 3 + 2] = int(radiance.z / float(params.spp) * 255.99);
}

__global__ void Denoising(DenoisingParams params) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    int offset = y * params.width + x;
    float weigh_sum = 0.0f;
    Float4 radiance_sum = 0.0f;
    int size = 2;
    for (int i = -size; i <= size; ++i) {
        for (int j = -size; j <= size; ++j) {
            if (x + i < 0 || x + i >= params.width || y + j < 0 || y + j >= params.height) continue;
            uint ref_offset = (y + j) * params.width + x + i;
            float weight = poca_mus::Dot(params.normal_info_buffer[ref_offset], params.normal_info_buffer[offset]);
            weight /= (1 + ABS(params.depth_info_buffer[ref_offset] - params.depth_info_buffer[offset]));
            weight /= (1 + i * i + j * j / 5.f);
            weight = MAX(0.0f, weight);
            radiance_sum += params.render_target[ref_offset] * weight;
            weigh_sum += weight;
        }
    }
    radiance_sum /= weigh_sum;
    params.output_buffer[offset * 3 + 0] = int(radiance_sum.x * 255.99);
    params.output_buffer[offset * 3 + 1] = int(radiance_sum.y * 255.99);
    params.output_buffer[offset * 3 + 2] = int(radiance_sum.z * 255.99);
}

__global__ void InitCuRand(curandState* d_rng_states, int width, int height) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    int offset = y * width + x;
    curand_init(offset * 13455, offset, 0, &(d_rng_states[offset]));
}

void PathTracer::AllocateGpuMemory() {
    bvh_root_ = poca_mus::BuildBVH(objs_);
    // cudaMalloc((void**)&render_target_gpu_handle_, width_ * height_ * sizeof(Float4));
    checkCudaErrors(cudaMalloc((void**)&camera_gpu_handle_, sizeof(MotionalCamera)));
    // cudaMalloc((void**)&materials_gpu_handle_, sizeof(Material*) * materials_.size());
    // cudaMalloc((void**)&scene_gpu_handle_, sizeof(Object*) * scene_.size());
    // for (int i = 0; i < materials_.size(); ++i) {
    //     Material* cur;
    //     cudaMalloc((void**)&cur, sizeof(Material));
    //     materials_cpu_handle_to_gpu_handle_[materials_[i]] = cur;
    //     MaterialMemCpyToGpu(materials_[i], cur);
    // }
    // for (int i = 0; i < scene_.size(); ++i) {
    //     Object* cur;
    //     cudaMalloc((void**)&cur, sizeof(Object));
    //     object_cpu_handle_to_gpu_handle_[scene_[i]] = cur;
    //     ObjectMemCpyToGpu(scene_[i], cur, materials_cpu_handle_to_gpu_handle_);
    //     cudaMemcpy(&(scene_gpu_handle_[i]), &cur, sizeof(Object*), cudaMemcpyHostToDevice);
    // }

    // ?????????????????????
    sky_tex_obj_ = poca_mus::AddTexByFile("textures/sky.png");

    checkCudaErrors(cudaMalloc((void**)&render_target_, height_ * width_ * sizeof(Float4)));
    checkCudaErrors(cudaMalloc((void**)&depth_info_buffer_, height_ * width_ * sizeof(float)));
    checkCudaErrors(cudaMalloc((void**)&normal_info_buffer_, height_ * width_ * sizeof(Float4)));
    checkCudaErrors(cudaMalloc((void**)&output_buffer_gpu_handle_, width_ * height_ * 3));
    checkCudaErrors(cudaMalloc((void**)(&d_rng_states_), height_ * width_ * sizeof(curandState)));
    dim3 threadsPerBlock(16, 16);
    dim3 numBlocks(width_ / threadsPerBlock.x, height_ / threadsPerBlock.y);
    InitCuRand<<<numBlocks, threadsPerBlock>>>(d_rng_states_, width_, height_);
}

void PathTracer::DispatchRay(uint8_t* buf, int size, int64_t t) {
    camera_->Updata();
    checkCudaErrors(cudaMemcpy(camera_gpu_handle_, camera_, sizeof(MotionalCamera), cudaMemcpyHostToDevice));

    // for (auto ptr_pair : materials_cpu_handle_to_gpu_handle_) {
    //     MaterialMemCpyToGpu((Material*)ptr_pair.first, (Material*)ptr_pair.second);
    // }
    // for (auto ptr_pair : object_cpu_handle_to_gpu_handle_) {
    //     ObjectMemCpyToGpu((Object*)ptr_pair.first, (Object*)ptr_pair.second, materials_cpu_handle_to_gpu_handle_);
    // }
    poca_mus::UpdateBVHInfos();

    PathTracerParams params;
    params.width = width_;
    params.height = height_;
    params.sky_tex_obj = sky_tex_obj_;

    params.bvh_root = bvh_root_;

    params.spp = spp_;
    params.max_recursion_depth = max_recursion_depth_;

    params.camera = camera_gpu_handle_;
    params.render_target = render_target_;
    params.depth_info_buffer = depth_info_buffer_;
    params.normal_info_buffer = normal_info_buffer_;
    params.output_buffer_gpu_handle = output_buffer_gpu_handle_;

    params.d_rng_states = d_rng_states_;

    dim3 threadsPerBlock(16, 16);
    dim3 numBlocks(width_ / threadsPerBlock.x, height_ / threadsPerBlock.y);
    SamplePixel<<<numBlocks, threadsPerBlock>>>(params);
    checkCudaErrors(cudaDeviceSynchronize());

    DenoisingParams params_denoising;
    params_denoising.width = width_;
    params_denoising.height = height_;
    params_denoising.render_target = render_target_;
    params_denoising.depth_info_buffer = depth_info_buffer_;
    params_denoising.normal_info_buffer = normal_info_buffer_;
    params_denoising.output_buffer = output_buffer_gpu_handle_;
    Denoising<<<numBlocks, threadsPerBlock>>>(params_denoising);

    const auto error = cudaGetLastError();
    if (error != 0) printf("[ERROR]Cuda Error %s\n", cudaGetErrorString(error));

    checkCudaErrors(cudaMemcpy(buf, output_buffer_gpu_handle_, width_ * height_ * 3, cudaMemcpyDeviceToHost));
}
