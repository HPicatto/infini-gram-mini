#ifndef _PARALLEL_H
#define _PARALLEL_H

// cilkarts cilk++
#if defined(CILK)
#include <cilk.h>
#include <cassert>
#define parallel_main cilk_main
#define parallel_for cilk_for
#define parallel_for_1 _Pragma("cilk_grainsize = 1") cilk_for
#define parallel_for_256 _Pragma("cilk_grainsize = 256") cilk_for

static int getWorkers() { return -1; }
static void setWorkers(int n) { }

// intel cilk+
#elif defined(CILKP)
#include <cilk/cilk.h>
#include <cilk/cilk_api.h>
#include <sstream>
#include <iostream>
#include <cstdlib>
#define parallel_for cilk_for
#define parallel_main main
#define parallel_for_1 _Pragma("cilk grainsize = 1") parallel_for
#define parallel_for_256 _Pragma("cilk grainsize = 256") parallel_for


static int getWorkers() {
  return __cilkrts_get_nworkers();
}
static void setWorkers(int n) {
  __cilkrts_end_cilk();
  //__cilkrts_init();
  std::stringstream ss; ss << n;
  if (0 != __cilkrts_set_param("nworkers", ss.str().c_str())) {
    std::cerr << "failed to set worker count!" << std::endl;
    std::abort();
  }
}

// opencilk (https://opencilk.org) -- the maintained successor to Intel Cilk
// Plus. Same cilk_spawn/cilk_sync/cilk_for keywords, so the call sites are
// unchanged; only the worker API differs, as OpenCilk dropped
// __cilkrts_set_param()/__cilkrts_end_cilk() in favour of the CILK_NWORKERS
// environment variable. Build with -fopencilk -DOPENCILK.
#elif defined(OPENCILK)
#include <cilk/cilk.h>
#include <cilk/cilk_api.h>
#include <cstdlib>
#include <string>
#define parallel_main main
#define parallel_for cilk_for
#define parallel_for_1 _Pragma("cilk grainsize 1") cilk_for
#define parallel_for_256 _Pragma("cilk grainsize 256") cilk_for

static int getWorkers() { return __cilkrts_get_nworkers(); }
// Must be called before the runtime starts; OpenCilk reads CILK_NWORKERS at
// initialisation and offers no post-start resize.
static void setWorkers(int n) { setenv("CILK_NWORKERS", std::to_string(n).c_str(), 1); }

// openmp
//
// cilk_spawn/cilk_sync map onto OpenMP tasks. Two differences from Cilk matter:
//
//  1. Cilk syncs implicitly when a function returns; OpenMP does not. Functions
//     that spawn without an explicit cilk_sync therefore need one added -- see
//     wt_pc.hpp, wt_int.hpp and sac_divsufsort.hpp, where an explicit sync was
//     added. It is a no-op under Cilk/OpenCilk, which already sync there.
//  2. Tasks only run in parallel inside a parallel region, and a nested
//     `omp parallel for` would collapse to one thread. So loops become
//     `taskloop` and recursive entry points are wrapped in spawn_region(),
//     which puts spawns and loops in one task pool -- the same shape Cilk has.
#elif defined(OPENMP)
#include <omp.h>
#define cilk_spawn _Pragma("omp task default(shared)")
#define cilk_sync _Pragma("omp taskwait")
#define parallel_main main
#define parallel_for _Pragma("omp taskloop default(shared)") for
#define parallel_for_1 _Pragma("omp taskloop default(shared) grainsize(1)") for
#define parallel_for_256 _Pragma("omp taskloop default(shared) grainsize(256)") for

static int getWorkers() { return omp_get_max_threads(); }
static void setWorkers(int n) { omp_set_num_threads(n); }

// c++
#else
#define cilk_spawn
#define cilk_sync
#define parallel_main main
#define parallel_for for
#define parallel_for_1 for
#define parallel_for_256 for
#define cilk_for for

static int getWorkers() { return 1; }
static void setWorkers(int n) { }

#endif

#include <limits.h>

// Runs f() somewhere that cilk_spawn/parallel_for actually go parallel.
// Under OpenMP that means an enclosing parallel region entered by a single
// thread, which then hands work to the team as tasks. Cilk and OpenCilk need
// no such scaffolding, and the serial build just calls f().
#if defined(OPENMP)
template <class F>
inline void spawn_region(F&& f) {
    if (omp_in_parallel()) { f(); return; }  // already inside a team
    _Pragma("omp parallel")
    {
        _Pragma("omp single")
        f();
    }
}
#else
template <class F>
inline void spawn_region(F&& f) { f(); }
#endif


//#if defined(LONG)
typedef long intT;
typedef unsigned long uintT;
#define INT_T_MAX LONG_MAX
#define UINT_T_MAX ULONG_MAX
//#else
//typedef int intT;
//typedef unsigned int uintT;
//#define INT_T_MAX INT_MAX
//#define UINT_T_MAX UINT_MAX
//#endif

#endif // _PARALLEL_H
