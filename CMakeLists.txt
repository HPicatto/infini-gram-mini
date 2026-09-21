# infini-gram mini -- builds the indexer and the query engine from source.
#
# Upstream shipped src/cpp_indexing as a 2019 amd64 binary built with gcc-5 and
# Intel Cilk Plus. Everything here is compiled instead, with any C++17 compiler.
# See README.md.
#
#   cmake -B build -DIGM_BACKEND=openmp && cmake --build build -j
#
# IGM_BACKEND selects how index construction is parallelised, via
# parallel_sdsl/include/sdsl/parallel.hpp:
#   openmp    OpenMP tasks + taskloop, any C++17 compiler   (default)
#   opencilk  cilk_spawn/cilk_for, needs -fopencilk
#   serial    no parallelism, plain sdsl                    (reference)

cmake_minimum_required(VERSION 3.20)
project(infini_gram_mini LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(IGM_BACKEND "openmp" CACHE STRING "Parallel backend: openmp, opencilk or serial")
set_property(CACHE IGM_BACKEND PROPERTY STRINGS openmp opencilk serial)

# The bundled sdsl is a 2014-era codebase; its own warnings are not actionable.
add_compile_options(-w)

# ---------------------------------------------------------- libdivsufsort ---
# Vendored under external/. The same sources build the 32- and 64-bit APIs,
# switched by BUILD_DIVSUFSORT64; sdsl's construct_sa references divsufsort64,
# so both are required.
file(GLOB DIVSUFSORT_SRC ${CMAKE_CURRENT_SOURCE_DIR}/external/libdivsufsort/lib/*.c)

add_library(divsufsort STATIC ${DIVSUFSORT_SRC})
target_include_directories(divsufsort PUBLIC external/libdivsufsort/include)
target_compile_definitions(divsufsort PRIVATE HAVE_CONFIG_H)

add_library(divsufsort64 STATIC ${DIVSUFSORT_SRC})
target_include_directories(divsufsort64 PUBLIC external/libdivsufsort/include)
target_compile_definitions(divsufsort64 PRIVATE HAVE_CONFIG_H BUILD_DIVSUFSORT64)

# ------------------------------------------------------------------- sdsl ---
# Two variants: the plain sdsl the engine is written against, and the
# parallel_sdsl the indexer uses. They must not be mixed in one binary -- the
# headers differ, so linking one against the other's archive is an ODR
# violation.
file(GLOB SDSL_SRC       ${CMAKE_CURRENT_SOURCE_DIR}/sdsl/lib/*.cpp)
file(GLOB SDSL_PAR_SRC   ${CMAKE_CURRENT_SOURCE_DIR}/parallel_sdsl/lib/*.cpp)

add_library(sdsl_serial STATIC ${SDSL_SRC})
target_include_directories(sdsl_serial PUBLIC sdsl/include)
target_link_libraries(sdsl_serial PUBLIC divsufsort divsufsort64)

if(IGM_BACKEND STREQUAL "serial")
  add_library(sdsl_indexer ALIAS sdsl_serial)
else()
  add_library(sdsl_parallel STATIC ${SDSL_PAR_SRC})
  target_include_directories(sdsl_parallel PUBLIC parallel_sdsl/include)
  target_link_libraries(sdsl_parallel PUBLIC divsufsort divsufsort64)
  if(IGM_BACKEND STREQUAL "openmp")
    find_package(OpenMP REQUIRED)
    target_compile_definitions(sdsl_parallel PUBLIC OPENMP)
    target_link_libraries(sdsl_parallel PUBLIC OpenMP::OpenMP_CXX)
  elseif(IGM_BACKEND STREQUAL "opencilk")
    target_compile_definitions(sdsl_parallel PUBLIC OPENCILK)
    target_compile_options(sdsl_parallel PUBLIC -fopencilk)
    target_link_options(sdsl_parallel PUBLIC -fopencilk)
  else()
    message(FATAL_ERROR "IGM_BACKEND must be openmp, opencilk or serial (got '${IGM_BACKEND}')")
  endif()
  add_library(sdsl_indexer ALIAS sdsl_parallel)
endif()

# --------------------------------------------------------- cpp_indexing -----
add_executable(cpp_indexing src/indexing.cpp)
target_link_libraries(cpp_indexing PRIVATE sdsl_indexer)

# indexing.py chdirs to its own directory and invokes ./cpp_indexing, so keep a
# copy beside it for in-tree use as well as the installed copy below.
add_custom_command(TARGET cpp_indexing POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:cpp_indexing>
          ${CMAKE_CURRENT_SOURCE_DIR}/src/cpp_indexing)

# ------------------------------------------------------------ query engine ---
find_package(Python COMPONENTS Interpreter Development.Module REQUIRED)
find_package(pybind11 CONFIG REQUIRED)

pybind11_add_module(cpp_engine engine/src/cpp_engine.cpp)
target_link_libraries(cpp_engine PRIVATE sdsl_serial)
target_include_directories(cpp_engine PRIVATE sdsl/include)

add_custom_command(TARGET cpp_engine POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:cpp_engine>
          ${CMAKE_CURRENT_SOURCE_DIR}/engine/src/$<TARGET_FILE_NAME:cpp_engine>)

# ---------------------------------------------------------------- install ---
# Everything lands in one importable package so that indexing.py's chdir-and-run
# of ./cpp_indexing and ./rust_indexing keeps working after installation.
set(IGM_PKG "${Python_SITEARCH}/infini_gram_mini")

install(TARGETS cpp_engine LIBRARY DESTINATION ${IGM_PKG})
install(TARGETS cpp_indexing RUNTIME DESTINATION ${IGM_PKG})
install(PROGRAMS src/rust_indexing DESTINATION ${IGM_PKG})
install(FILES
    python/infini_gram_mini/__init__.py
    engine/src/engine.py
    engine/src/models.py
    src/indexing.py
  DESTINATION ${IGM_PKG})
