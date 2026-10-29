# Builds lai-engine as one static binary from a llama.cpp source tree:
#   cmake -S engine -B build -DLLAMA_DIR=/path/to/llama.cpp -DCMAKE_BUILD_TYPE=Release
#   cmake --build build -j
# Only libllama, ggml and llama.cpp's common helpers are compiled; the server,
# web UI, multimodal library, tools, examples and tests are left out.
cmake_minimum_required(VERSION 3.16)
project(lai-engine C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(LLAMA_DIR "" CACHE PATH "llama.cpp source directory")
if (NOT EXISTS "${LLAMA_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "set -DLLAMA_DIR to a llama.cpp checkout")
endif()

macro(force name value)
    set(${name} ${value} CACHE BOOL "" FORCE)
endmacro()

force(BUILD_SHARED_LIBS     OFF)  # one self-contained binary
force(LLAMA_BUILD_COMMON    ON)   # chat templates and tool-call parsing
force(LLAMA_BUILD_TESTS     OFF)
force(LLAMA_BUILD_TOOLS     OFF)
force(LLAMA_BUILD_EXAMPLES  OFF)
force(LLAMA_BUILD_SERVER    OFF)
force(LLAMA_BUILD_APP       OFF)
force(LLAMA_BUILD_UI        OFF)
force(LLAMA_BUILD_HTML      OFF)
force(LLAMA_BUILD_MTMD      OFF)
force(LLAMA_OPENSSL         OFF)  # no downloads, so no HTTPS
force(LLAMA_SUBPROCESS      OFF)
force(GGML_BUILD_TESTS      OFF)
force(GGML_BUILD_EXAMPLES   OFF)
# GGML_NATIVE (default ON) compiles CPU kernels for this machine only.
# Pass -DGGML_VULKAN=ON or -DGGML_CUDA=ON for a GPU build.

add_subdirectory(${LLAMA_DIR} llama.cpp EXCLUDE_FROM_ALL)

add_executable(lai-engine lai-engine.cpp)
target_link_libraries(lai-engine PRIVATE llama-common llama)
if (CMAKE_SYSTEM_NAME STREQUAL "Linux")
    # static libstdc++/libgcc so the binary runs on older and newer distros alike
    target_link_options(lai-engine PRIVATE -static-libstdc++ -static-libgcc)
endif()
