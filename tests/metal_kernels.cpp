// Runs the Metal patch's kernels for ggml_mhc_route and ggml_mhc_merge on the CPU, one std::thread per Metal thread, with
// real barriers and an emulated simd_sum, and compares them with the fork's CPU implementation (copied below), which is
// the reference. tests/metal-kernels.sh takes the kernels and their arguments out of the patch and builds this.
#include <barrier>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <random>
#include <thread>
#include <vector>
#include <algorithm>

#include "mhc_kargs.h"

// --- Metal shim
struct uint3 { unsigned x, y, z; };
typedef unsigned uint;
#define kernel
#define device
#define constant const
#define threadgroup
#define N_SIMDWIDTH 32
#define FOR_UNROLL(x) for (x)
namespace mem_flags { constexpr int mem_threadgroup = 0; }
namespace precise {
    inline float exp (float x) { return std::exp(x); }
    inline float log (float x) { return std::log(x); }
    inline float sqrt(float x) { return std::sqrt(x); }
}
inline float max(float a, float b) { return a > b ? a : b; }

static std::barrier<> * g_bar = nullptr;
static float g_simd[1024];
thread_local int t_tid, t_sg;

inline void threadgroup_barrier(int) { g_bar->arrive_and_wait(); }
inline float simd_sum(float v) {
    g_simd[t_tid] = v;
    g_bar->arrive_and_wait();
    float s = 0.0f;
    for (int l = 0; l < 32; ++l) s += g_simd[t_sg*32 + l];
    g_bar->arrive_and_wait();
    return s;
}

#include "mhc_kernels.metal.inc"

// --- The fork's CPU reference, from ggml/src/ggml-cpu/ops.cpp (single thread)
struct view3 { const float * data; int64_t ne0, ne1, ne2; size_t nb1, nb2; };

static void ref_route(view3 a, view3 b, const float * pw, const float * pbias, float * out) {
    const int64_t d = a.ne0, n_tok = a.ne1, n_str = a.ne2;
    for (int64_t s = 0; s < n_str; ++s) {
        for (int64_t t = 0; t < n_tok; ++t) {
            const float * va = (const float *) ((const char *) a.data + t*a.nb1 + s*a.nb2);
            const float * vb = (const float *) ((const char *) b.data + t*b.nb1 + s*b.nb2);
            float * po = out + t*(d + 6) + s*n_tok*(d + 6);
            float ss = 0.0f;
            for (int64_t i = 0; i < d; ++i) ss += va[i]*va[i] + vb[i]*vb[i];
            const float rms = 1.0f/sqrtf(ss/(2.0f*d) + 1e-6f);
            float lg[8];
            for (int k = 0; k < 8; ++k) {
                const float * wk = pw + k*2*d;
                float acc = 0.0f;
                for (int64_t i = 0; i < d; ++i) acc += wk[i]*va[i] + wk[d + i]*vb[i];
                lg[k] = acc*rms + pbias[k];
            }
            const float pre0  = 1.0f/(1.0f + expf(-lg[0]));
            const float pre1  = 1.0f/(1.0f + expf(-lg[1]));
            const float post0 = 2.0f/(1.0f + expf(-lg[2]));
            const float post1 = 2.0f/(1.0f + expf(-lg[3]));
            float m[2][2] = { { lg[4], lg[5] }, { lg[6], lg[7] } };
            for (int it = 0; it < 20; ++it) {
                for (int r = 0; r < 2; ++r) {
                    const float mx = m[r][0] > m[r][1] ? m[r][0] : m[r][1];
                    const float lse = mx + logf(expf(m[r][0] - mx) + expf(m[r][1] - mx));
                    m[r][0] -= lse; m[r][1] -= lse;
                }
                for (int c = 0; c < 2; ++c) {
                    const float mx = m[0][c] > m[1][c] ? m[0][c] : m[1][c];
                    const float lse = mx + logf(expf(m[0][c] - mx) + expf(m[1][c] - mx));
                    m[0][c] -= lse; m[1][c] -= lse;
                }
            }
            for (int64_t i = 0; i < d; ++i) po[i] = pre0*va[i] + pre1*vb[i];
            po[d + 0] = post0; po[d + 1] = post1;
            po[d + 2] = expf(m[0][0]); po[d + 3] = expf(m[0][1]);
            po[d + 4] = expf(m[1][0]); po[d + 5] = expf(m[1][1]);
        }
    }
}

static void ref_merge(view3 a, view3 b, view3 x, view3 p, float * out) {
    const int64_t d = a.ne0, n_tok = a.ne1, n_str = a.ne2;
    for (int64_t s = 0; s < n_str; ++s) {
        for (int64_t t = 0; t < n_tok; ++t) {
            const float * va = (const float *) ((const char *) a.data + t*a.nb1 + s*a.nb2);
            const float * vb = (const float *) ((const char *) b.data + t*b.nb1 + s*b.nb2);
            const float * vx = (const float *) ((const char *) x.data + t*x.nb1 + s*x.nb2);
            const float * vp = (const float *) ((const char *) p.data + t*p.nb1 + s*p.nb2);
            float * vo = out + t*2*d + s*n_tok*2*d;
            for (int64_t i = 0; i < d; ++i) {
                vo[i]     = vp[d + 2]*va[i] + vp[d + 3]*vb[i] + vp[d + 0]*vx[i];
                vo[d + i] = vp[d + 4]*va[i] + vp[d + 5]*vb[i] + vp[d + 1]*vx[i];
            }
        }
    }
}

// --- Dispatch as ggml_metal_op_mhc does
static void run_route(const ggml_metal_kargs_mhc_route & args, const float * a, const float * b, const float * w,
                      const float * bias, float * dst, int n_tok, int n_str, int nth) {
    const int nsg = nth/32;
    std::vector<float> shmem(9*nsg + 8);
    for (int s = 0; s < n_str; ++s) {
        for (int t = 0; t < n_tok; ++t) {
            std::barrier<> bar(nth);
            g_bar = &bar;
            std::vector<std::thread> th;
            for (int tid = 0; tid < nth; ++tid) {
                th.emplace_back([&, tid] {
                    t_tid = tid; t_sg = tid/32;
                    kernel_mhc_route_f32(args, (const char *) a, (const char *) b, (const char *) w,
                                         (const char *) bias, (char *) dst, shmem.data(),
                                         uint3{(unsigned) t, (unsigned) s, 0}, uint3{(unsigned) tid, 0, 0}, tid/32, tid%32, uint3{(unsigned) nth, 1, 1});
                });
            }
            for (auto & x : th) x.join();
        }
    }
}

static void run_merge(const ggml_metal_kargs_mhc_merge & args, const float * a, const float * b, const float * x,
                      const float * p, float * dst, int d, int n_tok, int n_str, int nth) {
    for (int s = 0; s < n_str; ++s)
        for (int t = 0; t < n_tok; ++t)
            for (int g = 0; g < (d + nth - 1)/nth; ++g)
                for (int tid = 0; tid < nth; ++tid)
                    kernel_mhc_merge_f32(args, (const char *) a, (const char *) b, (const char *) x, (const char *) p,
                                         (char *) dst, uint3{(unsigned) g, (unsigned) t, (unsigned) s},
                                         uint3{(unsigned) tid, 0, 0}, uint3{(unsigned) nth, 1, 1});
}

static double nmse(const std::vector<float> & ref, const std::vector<float> & got) {
    double num = 0, den = 0;
    for (size_t i = 0; i < ref.size(); ++i) { num += (ref[i] - got[i])*(double)(ref[i] - got[i]); den += ref[i]*(double) ref[i]; }
    return num/den;
}

int main() {
    std::mt19937 rng(42);
    std::uniform_real_distribution<float> u(-1.0f, 1.0f), uw(-0.05f, 0.05f);
    int fails = 0;
    struct shape { int d, n_tok, n_str; bool view; int nth; };
    const shape shapes[] = {
        {64, 1, 1, false, 256}, {64, 3, 1, true, 256}, {100, 7, 2, false, 64}, {100, 7, 2, true, 96},
        {4096, 2, 1, true, 256}, {4096, 1, 1, false, 32}, {33, 2, 2, true, 256},
    };
    for (const shape & sh : shapes) {
        const int d = sh.d, nt = sh.n_tok, ns = sh.n_str;
        // the streams: halves of one [2d, nt, ns] buffer, or two separate [d, nt, ns] tensors
        std::vector<float> ab(2*d*nt*ns), a2(d*nt*ns), b2(d*nt*ns);
        for (auto & v : ab) v = u(rng);
        for (auto & v : a2) v = u(rng);
        for (auto & v : b2) v = u(rng);
        view3 va, vb;
        if (sh.view) {
            va = { ab.data(),     d, nt, ns, 2*d*sizeof(float), 2*(size_t) d*nt*sizeof(float) };
            vb = { ab.data() + d, d, nt, ns, 2*d*sizeof(float), 2*(size_t) d*nt*sizeof(float) };
        } else {
            va = { a2.data(), d, nt, ns, d*sizeof(float), (size_t) d*nt*sizeof(float) };
            vb = { b2.data(), d, nt, ns, d*sizeof(float), (size_t) d*nt*sizeof(float) };
        }
        std::vector<float> w(2*d*8), bias(8);
        for (auto & v : w) v = uw(rng);
        for (auto & v : bias) v = u(rng);

        // route
        std::vector<float> ref(( d + 6)*nt*ns), got(ref.size(), NAN);
        ref_route(va, vb, w.data(), bias.data(), ref.data());
        ggml_metal_kargs_mhc_route ra = { d, va.nb1, va.nb2, vb.nb1, vb.nb2, 2*d*sizeof(float),
                                          (d + 6)*sizeof(float), (size_t) (d + 6)*nt*sizeof(float) };
        run_route(ra, va.data, vb.data, w.data(), bias.data(), got.data(), nt, ns, sh.nth);
        const double e1 = nmse(ref, got);
        const bool ok1 = std::isfinite(e1) && e1 < 1e-10;
        printf("%s route d=%d tok=%d str=%d view=%d nth=%d  nmse=%.3g\n", ok1 ? "ok  " : "FAIL", d, nt, ns, sh.view, sh.nth, e1);
        fails += !ok1;

        // merge, with the route's output as its packed input
        std::vector<float> xx(d*nt*ns);
        for (auto & v : xx) v = u(rng);
        view3 vx = { xx.data(), d, nt, ns, d*sizeof(float), (size_t) d*nt*sizeof(float) };
        view3 vp = { ref.data(), d + 6, nt, ns, (d + 6)*sizeof(float), (size_t) (d + 6)*nt*sizeof(float) };
        std::vector<float> mref(2*d*nt*ns), mgot(mref.size(), NAN);
        ref_merge(va, vb, vx, vp, mref.data());
        ggml_metal_kargs_mhc_merge ma = { d, va.nb1, va.nb2, vb.nb1, vb.nb2, vx.nb1, vx.nb2, vp.nb1, vp.nb2,
                                          2*d*sizeof(float), (size_t) 2*d*nt*sizeof(float) };
        run_merge(ma, va.data, vb.data, vx.data, vp.data, mgot.data(), d, nt, ns, std::min(sh.nth, d));
        const double e2 = nmse(mref, mgot);
        const bool ok2 = std::isfinite(e2) && e2 < 1e-12;
        printf("%s merge d=%d tok=%d str=%d view=%d  nmse=%.3g\n", ok2 ? "ok  " : "FAIL", d, nt, ns, sh.view, e2);
        fails += !ok2;
    }
    printf(fails ? "%d failed\n" : "all passed\n", fails);
    return fails != 0;
}
