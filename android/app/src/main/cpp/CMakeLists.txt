cmake_minimum_required(VERSION 3.22.1)
project(dj_engine VERSION 1.0.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# F-Droid reproducible builds: GNU build-ids differ across machines.
add_link_options("-Wl,--build-id=none")

# android/app/src/main/cpp -> project root
get_filename_component(SIDEDECK_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)

set(OBOE_DIR "${SIDEDECK_ROOT}/third_party/oboe")
set(ENGINE_DIR "${SIDEDECK_ROOT}/native/engine")
set(DR_LIBS "${SIDEDECK_ROOT}/third_party/dr_libs")
set(STRETCH_DIR "${SIDEDECK_ROOT}/third_party/signalsmith-stretch")
set(LINEAR_DIR "${SIDEDECK_ROOT}/third_party/signalsmith-linear")
set(QM_DSP_DIR "${SIDEDECK_ROOT}/third_party/qm-dsp")
set(LINK_DIR "${SIDEDECK_ROOT}/third_party/ableton-link")
set(ASIO_DIR "${SIDEDECK_ROOT}/third_party/asio-standalone")

add_subdirectory("${OBOE_DIR}" oboe-build)
add_subdirectory("${QM_DSP_DIR}" qm-dsp-build)
include("${SIDEDECK_ROOT}/third_party/opus_stack.cmake")

add_library(dj_engine SHARED
  "${ENGINE_DIR}/dj_engine.cpp"
  "${ENGINE_DIR}/last_error.cpp"
  "${ENGINE_DIR}/link_bridge.cpp"
)
target_compile_definitions(dj_engine PRIVATE _USE_MATH_DEFINES)
target_compile_options(dj_engine PRIVATE -fexceptions)
# Ableton Link (GPL v2+) with its bundled asio. Same definitions Link's own
# CMake sets for Android. ASIO_VERSION_NAMESPACE follows asio 1.38.2.
target_compile_definitions(dj_engine PRIVATE
  LINK_PLATFORM_UNIX=1
  LINK_PLATFORM_LINUX=1
  ASIO_NO_TYPEID=1
  ASIO_STANDALONE=1
  ASIO_VERSION_NAMESPACE=link_asio_1_38_2
)

target_include_directories(dj_engine PRIVATE
  "${ENGINE_DIR}"
  "${DR_LIBS}"
  "${STRETCH_DIR}"
  "${LINEAR_DIR}/include"
  "${QM_DSP_DIR}"
  "${LINK_DIR}/include"
)
target_include_directories(dj_engine SYSTEM PRIVATE "${ASIO_DIR}/include")

find_library(log-lib log)

target_link_libraries(dj_engine
  qm_dsp
  oboe
  opusfile
  android
  mediandk
  atomic
  ${log-lib}
)
